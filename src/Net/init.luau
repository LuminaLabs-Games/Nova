--!strict
--[[
	Nova.Net: every packet declared once in a shared schema, packed into a buffer, batched into one
	remote call per frame, and sent reliable or unreliable as the packet says. Plain Luau, no code
	generation step. Replaces SimpleNet.

		-- ReplicatedStorage/Shared/Packets.luau, required by both sides
		local Net = require(ReplicatedStorage.Packages.Nova).Net
		local t = Net.types
		return Net.define({
			Fire = Net.packet({
				from = "client",
				data = t.struct({ weapon = t.u8, origin = t.vector3, direction = t.unitVector, shotTime = t.f64 }),
				rate = 20,
			}),
			Aim = Net.packet({ from = "client", reliable = false, latestOnly = true,
				data = t.struct({ pitch = t.angle, yaw = t.angle }), rate = 60 }),
			HitConfirm = Net.packet({ from = "server",
				data = t.struct({ target = t.instance("Model"), damage = t.u16, headshot = t.bool }) }),
			CraftItem = Net.request({ data = t.struct({ recipe = t.u16 }),
				reply = t.struct({ ok = t.bool, reason = t.optional(t.string(64)) }), rate = 5, timeout = 10 }),
		})

		-- client                                        -- server
		Packets.Fire:send(shot)                          Packets.Fire:listen(function(player, shot) end)
		Packets.HitConfirm:listen(function(hit) end)     Packets.HitConfirm:sendTo(player, hit)
		local reply = Packets.CraftItem:invoke(req)      Packets.CraftItem:handle(function(player, req) return reply end)

	ON THE WIRE. Packet ids are the schema's names sorted, as 1 byte (2 past 255 packets); both sides
	require the same module, so they always agree, and there is exactly one Net.define per game.
	`latestOnly` adds a 2-byte sequence number and the receiver drops anything older than the newest
	it has seen (unreliable calls can arrive out of order).

	WHAT THE SERVER CHECKS. Every read is bounds-checked; a malformed batch is dropped whole and
	counts a strike. Limits are part of the type (lengths, ranges, NaN, an instance's class). `rate`
	is a per-player token bucket per packet. `Net.onAbuse` sees every strike.

	Packets that arrive before anything listens (a listener connected in a start that waited) are
	held, up to 64 per packet, and delivered to the first listener, as a RemoteEvent would.

	REQUESTS only go client to server. A handler that errors sends the client a plain failure (the
	full error stays in the server log), and `invoke` errors on a failure or a timeout.

	Out of scope: hit checks and position rewinding belong in the game's combat code. Nova gives it
	the parts: a schema that cannot be spammed, and `shotTime` from workspace:GetServerTimeNow().
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Channel = require(script.Channel)
local Limits = require(script.Limits)
local Log = require(script.Parent.Log)
local Signal = require(script.Parent.Signal)
local Types = require(script.Types)
local Util = require(script.Parent.Util)

local IS_SERVER = RunService:IsServer()
local IS_STUDIO = RunService:IsStudio()

export type Codec<T> = Types.Codec<T>
export type Connection = Signal.Connection

export type Packet<T> = {
	name: string,
	send: (self: Packet<T>, data: T) -> (),
	listen: (self: Packet<T>, fn: (...any) -> ()) -> Connection,
	sendTo: (self: Packet<T>, player: Player, data: T) -> (),
	sendAll: (self: Packet<T>, data: T) -> (),
	sendExcept: (self: Packet<T>, except: Player | { Player }, data: T) -> (),
	sendList: (self: Packet<T>, players: { Player }, data: T) -> (),
	sendFilter: (self: Packet<T>, filter: (player: Player) -> boolean, data: T) -> (),
	sendNear: (self: Packet<T>, position: Vector3, radius: number, data: T) -> (),
}

export type Request<T, R> = {
	name: string,
	invoke: (self: Request<T, R>, data: T) -> R,
	handle: (self: Request<T, R>, fn: (player: Player, data: T) -> R) -> (),
}

type Stats = { sent: number, sentBytes: number, received: number, receivedBytes: number, dropped: number }

local log = Log.new("Nova.Net")

local MAX_BATCH_BYTES = Channel.RELIABLE_BUDGET
local QUEUE_LIMIT = 64
local RAW_QUEUE_LIMIT = 4096
local STATUS_FAILED, STATUS_OK, STATUS_RATE = 0, 1, 2
local EMPTY = table.freeze({})

local Net = {}
Net.types = Types

local defined = false
local byId: { [number]: any } = {}
local idBytes = 1
local rawQueue: { any } = {}
local scratch = Types.newWriter(512)
local pending: { [number]: { thread: thread, packet: any, timer: thread? } } = {}
local nextRequestId = 0
local lastSeqServer: { [Player]: { [number]: number } } = {}
-- Server: the last sequence number sent to each player per latestOnly packet. Per player, so a
-- player who misses a run of sendTo/sendNear updates never sees the next one as old.
local sendSeq: { [Player]: { [number]: number } } = {}
local rawQueueWarned = false
local lastSeqClient: { [number]: number } = {}
local statsSince = os.clock()
local queueWarned: { [any]: boolean } = {}

local Packet = {}
Packet.__index = Packet

local function newPacket(fields: { [string]: any }): any
	fields._signal = Signal.new()
	fields._queue = {}
	fields._seq = 0
	fields._stats = { sent = 0, sentBytes = 0, received = 0, receivedBytes = 0, dropped = 0 } :: Stats
	return setmetatable(fields, Packet)
end

local function checkCodec(value: any, what: string)
	if value ~= nil and not Types.isCodec(value) then
		error(`{what} must be a type from Net.types (did you forget to call it, as in t.string(32)?)`, 3)
	end
end

function Net.packet<T>(def: {
	from: "client" | "server",
	data: Codec<T>?,
	reliable: boolean?,
	latestOnly: boolean?,
	rate: number?,
}): Packet<T>
	if type(def) ~= "table" then
		error("Net.packet takes a table: { from = \"client\", data = ... }", 2)
	end
	Util.checkKeys(def, { "from", "data", "reliable", "latestOnly", "rate" }, "Net.packet")
	if def.from ~= "client" and def.from ~= "server" then
		error('Net.packet: from must be "client" or "server"', 2)
	end
	checkCodec(def.data, "Net.packet: data")
	local reliable = def.reliable ~= false
	if def.latestOnly and reliable then
		error("Net.packet: latestOnly needs reliable = false (reliable packets already arrive in order)", 2)
	end
	if def.rate ~= nil then
		if def.from ~= "client" then
			error("Net.packet: rate limits what clients send; a server packet has none", 2)
		end
		if type(def.rate) ~= "number" or def.rate <= 0 then
			error("Net.packet: rate is packets per second, per player", 2)
		end
	end
	return newPacket({
		kind = "packet",
		from = def.from,
		codec = def.data,
		reliable = reliable,
		latestOnly = def.latestOnly == true,
		rate = def.rate,
	})
end

function Net.request<T, R>(def: { data: Codec<T>?, reply: Codec<R>?, rate: number?, timeout: number? }): Request<T, R>
	if type(def) ~= "table" then
		error("Net.request takes a table: { data = ..., reply = ... }", 2)
	end
	Util.checkKeys(def, { "data", "reply", "rate", "timeout" }, "Net.request")
	checkCodec(def.data, "Net.request: data")
	checkCodec(def.reply, "Net.request: reply")
	if def.rate ~= nil and (type(def.rate) ~= "number" or def.rate <= 0) then
		error("Net.request: rate is requests per second, per player", 2)
	end
	return newPacket({
		kind = "request",
		from = "client",
		codec = def.data,
		reply = def.reply,
		reliable = true,
		latestOnly = false,
		rate = def.rate,
		timeout = def.timeout or 10,
	})
end

local function writeId(w: Types.Writer, id: number)
	Types.reserve(w, idBytes)
	if idBytes == 1 then
		buffer.writeu8(w.buf, w.cursor, id)
	else
		buffer.writeu16(w.buf, w.cursor, id)
	end
	w.cursor += idBytes
end

local function writeU16(w: Types.Writer, value: number)
	Types.reserve(w, 2)
	buffer.writeu16(w.buf, w.cursor, value)
	w.cursor += 2
end

local function writeU8(w: Types.Writer, value: number)
	Types.reserve(w, 1)
	buffer.writeu8(w.buf, w.cursor, value)
	w.cursor += 1
end

local function readU16(r: Types.Reader): number
	if r.cursor + 2 > r.len then
		error("ran past the end of the batch", 0)
	end
	local value = buffer.readu16(r.buf, r.cursor)
	r.cursor += 2
	return value
end

local function readU8(r: Types.Reader): number
	if r.cursor + 1 > r.len then
		error("ran past the end of the batch", 0)
	end
	local value = buffer.readu8(r.buf, r.cursor)
	r.cursor += 1
	return value
end

local function readId(r: Types.Reader): number
	return if idBytes == 1 then readU8(r) else readU16(r)
end

-- True when sequence number `seq` is newer than `last`, across the 16-bit wrap.
local function newer(seq: number, last: number?): boolean
	if last == nil then
		return true
	end
	local ahead = (seq - last) % 65536
	return ahead ~= 0 and ahead < 32768
end

local function requireDefined(packet: any, level: number)
	if not packet.name then
		error("This packet is not in a Net.define call yet; send through the table Net.define returns", level + 1)
	end
end

-- Encodes one packet record into the scratch writer; errors name the packet and the field.
local function encode(packet: any, value: any, level: number, requestId: number?): Types.Writer
	local ok, err = pcall(function()
		Types.reset(scratch)
		writeId(scratch, packet.id)
		if packet.latestOnly then
			packet._seq = (packet._seq + 1) % 65536
			writeU16(scratch, packet._seq)
		end
		if requestId then
			writeU16(scratch, requestId)
		end
		if packet.codec then
			packet.codec.write(scratch, value, packet.name)
		elseif value ~= nil then
			error(`{packet.name} carries no data, but was given a {typeof(value)}`, 0)
		end
	end)
	if not ok then
		error(`Nova.Net: {err}`, level + 1)
	end
	return scratch
end

local function sideError(packet: any, method: string, level: number)
	local name = packet.name or "this packet"
	if packet.kind == "request" then
		error(`{name} is a request: the client calls :invoke and the server calls :handle (not :{method})`, level + 1)
	elseif packet.from == "client" then
		error(`{name} is sent by the client (:send) and listened to on the server; :{method} does not apply here`, level + 1)
	end
	error(`{name} is sent by the server (:sendTo, :sendAll, ...) and listened to on the client; :{method} does not apply here`, level + 1)
end

local function counted(packet: any, recipients: number, bytes: number)
	local stats = packet._stats
	stats.sent += recipients
	stats.sentBytes += recipients * bytes
end

-- Server: appends an encoded record to one player's batch, stamping that player's own sequence
-- number on a latestOnly packet.
local function appendTo(player: Player, packet: any, record: Types.Writer)
	local w, start = Channel.append(player, packet.reliable, record)
	if w and packet.latestOnly then
		local perPlayer = sendSeq[player]
		if not perPlayer then
			perPlayer = {}
			sendSeq[player] = perPlayer
		end
		local seq = ((perPlayer[packet.id] or 0) + 1) % 65536
		perPlayer[packet.id] = seq
		buffer.writeu16(w.buf, start + idBytes, seq)
	end
end

-- Client ------------------------------------------------------------------------------------------

function Packet.send(self: any, data: any)
	if IS_SERVER or self.from ~= "client" or self.kind ~= "packet" then
		sideError(self, "send", 2)
	end
	requireDefined(self, 2)
	local record = encode(self, data, 2)
	counted(self, 1, record.cursor)
	Channel.append(nil, self.reliable, record)
end

function Packet.invoke(self: any, data: any): any
	if IS_SERVER or self.kind ~= "request" then
		sideError(self, "invoke", 2)
	end
	requireDefined(self, 2)
	repeat
		nextRequestId = (nextRequestId + 1) % 65536
	until pending[nextRequestId] == nil
	local requestId = nextRequestId
	local record = encode(self, data, 2, requestId)
	counted(self, 1, record.cursor)
	Channel.append(nil, true, record)

	local thread = coroutine.running()
	local entry = { thread = thread, packet = self, timer = nil :: thread? }
	entry.timer = task.delay(self.timeout, function()
		if pending[requestId] == entry then
			pending[requestId] = nil
			if coroutine.status(thread) == "suspended" then
				task.spawn(thread, "timeout")
			end
		end
	end)
	pending[requestId] = entry
	local status, value = coroutine.yield()
	if status == STATUS_OK then
		return value
	elseif status == "timeout" then
		error(`{self.name} timed out after {self.timeout}s`, 2)
	elseif status == STATUS_RATE then
		error(`{self.name} was refused: too many requests`, 2)
	end
	error(`{self.name} failed on the server`, 2)
end

-- Server ------------------------------------------------------------------------------------------

local function serverSend(self: any, method: string)
	if not IS_SERVER or self.from ~= "server" then
		sideError(self, method, 3)
	end
	requireDefined(self, 3)
end

local function checkPlayer(player: any, method: string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		error(`:{method} expects a Player, got {typeof(player)}`, 3)
	end
end

function Packet.sendTo(self: any, player: Player, data: any)
	serverSend(self, "sendTo")
	checkPlayer(player, "sendTo")
	local record = encode(self, data, 2)
	counted(self, 1, record.cursor)
	appendTo(player, self, record)
end

function Packet.sendList(self: any, players: { Player }, data: any)
	serverSend(self, "sendList")
	for _, player in players do
		checkPlayer(player, "sendList")
	end
	local record = encode(self, data, 2)
	for _, player in players do
		appendTo(player, self, record)
	end
	counted(self, #players, record.cursor)
end

function Packet.sendAll(self: any, data: any)
	serverSend(self, "sendAll")
	local record = encode(self, data, 2)
	local players = Players:GetPlayers()
	for _, player in players do
		appendTo(player, self, record)
	end
	counted(self, #players, record.cursor)
end

function Packet.sendExcept(self: any, except: Player | { Player }, data: any)
	serverSend(self, "sendExcept")
	local record = encode(self, data, 2)
	local skip = if typeof(except) == "Instance" then { except } else except :: { Player }
	local count = 0
	for _, player in Players:GetPlayers() do
		if not table.find(skip, player) then
			appendTo(player, self, record)
			count += 1
		end
	end
	counted(self, count, record.cursor)
end

function Packet.sendFilter(self: any, filter: (Player) -> boolean, data: any)
	serverSend(self, "sendFilter")
	-- Filter first: it is game code and may send something itself, which reuses the scratch writer.
	local chosen = {}
	for _, player in Players:GetPlayers() do
		if filter(player) then
			table.insert(chosen, player)
		end
	end
	local record = encode(self, data, 2)
	for _, player in chosen do
		appendTo(player, self, record)
	end
	counted(self, #chosen, record.cursor)
end

--- Players whose character's root is within `radius` studs of `position`.
function Packet.sendNear(self: any, position: Vector3, radius: number, data: any)
	serverSend(self, "sendNear")
	local record = encode(self, data, 2)
	local count = 0
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and (character.PrimaryPart or character:FindFirstChild("HumanoidRootPart"))
		if root and root:IsA("BasePart") and (root.Position - position).Magnitude <= radius then
			appendTo(player, self, record)
			count += 1
		end
	end
	counted(self, count, record.cursor)
end

local function respond(player: Player, packet: any, requestId: number, status: number, reply: any?)
	if not player.Parent then
		return
	end
	Types.reset(scratch)
	writeId(scratch, packet.id)
	writeU16(scratch, requestId)
	writeU8(scratch, status)
	if status == STATUS_OK and packet.reply then
		local ok, err = pcall(packet.reply.write, scratch, reply, `{packet.name} reply`)
		if not ok then
			log:error(`{packet.name}'s handler returned a reply that does not fit its type: {err}`)
			respond(player, packet, requestId, STATUS_FAILED)
			return
		end
	end
	counted(packet, 1, scratch.cursor)
	Channel.append(player, true, scratch)
end

local function runHandler(player: Player, packet: any, requestId: number, value: any)
	local handler = packet._handler
	if not handler then
		if #packet._queue >= QUEUE_LIMIT then
			respond(player, packet, requestId, STATUS_FAILED)
		else
			table.insert(packet._queue, table.pack(player, requestId, value))
		end
		return
	end
	task.spawn(function()
		local ok, reply = xpcall(handler, debug.traceback, player, value)
		if ok then
			respond(player, packet, requestId, STATUS_OK, reply)
		else
			log:error(`{packet.name} failed for {player.Name}:\n{reply}`)
			respond(player, packet, requestId, STATUS_FAILED)
		end
	end)
end

function Packet.handle(self: any, fn: (Player, any) -> any)
	if not IS_SERVER or self.kind ~= "request" then
		sideError(self, "handle", 2)
	end
	if type(fn) ~= "function" then
		error(":handle expects a function(player, data) that returns the reply", 2)
	end
	if self._handler then
		error(`{self.name or "This request"} already has a handler; a request has exactly one`, 2)
	end
	self._handler = fn
	local queued = self._queue
	self._queue = {}
	for _, item in queued do
		runHandler(item[1], self, item[2], item[3])
	end
end

-- Both sides --------------------------------------------------------------------------------------

local function deliver(packet: any, ...: any)
	local signal = packet._signal
	if #signal._listeners == 0 then
		local queue = packet._queue
		if #queue >= QUEUE_LIMIT then
			table.remove(queue, 1)
			if IS_STUDIO and not queueWarned[packet] then
				queueWarned[packet] = true
				log:warn(`{packet.name} keeps arriving with nothing listening; the oldest are being dropped`)
			end
		end
		table.insert(queue, table.pack(...))
		return
	end
	signal:Fire(...)
end

--[[ Server: fn(player, data). Client: fn(data). Returns a connection; disconnecting it removes this
	listener and no other. ]]
function Packet.listen(self: any, fn: (...any) -> ()): Connection
	if self.kind ~= "packet" or (IS_SERVER and self.from ~= "client") or (not IS_SERVER and self.from ~= "server") then
		sideError(self, "listen", 2)
	end
	if type(fn) ~= "function" then
		error(":listen expects a function", 2)
	end
	local connection = self._signal:Connect(fn)
	if #self._queue > 0 then
		local queued = self._queue
		self._queue = {}
		for _, item in queued do
			self._signal:Fire(table.unpack(item, 1, item.n))
		end
	end
	return connection
end

-- Receiving ---------------------------------------------------------------------------------------

local function receiveFromClient(player: Player, record: any)
	local packet, value, seq, requestId, stale, bytes = record[1], record[2], record[3], record[4], record[5], record[6]
	local stats = packet._stats
	stats.received += 1
	stats.receivedBytes += bytes
	if packet.rate and not Limits.take(player, packet.id, packet.rate) then
		stats.dropped += 1
		Limits.strike(player, packet.name, "over its rate limit")
		if requestId then
			respond(player, packet, requestId, STATUS_RATE)
		end
		return
	end
	if stale then
		-- It named an Instance the server no longer has: destroyed in flight, most likely.
		stats.dropped += 1
		if requestId then
			respond(player, packet, requestId, STATUS_FAILED)
		end
		return
	end
	if seq then
		local seen = lastSeqServer[player]
		if not seen then
			seen = {}
			lastSeqServer[player] = seen
		end
		if not newer(seq, seen[packet.id]) then
			stats.dropped += 1
			return
		end
		seen[packet.id] = seq
	end
	if requestId then
		runHandler(player, packet, requestId, value)
	else
		deliver(packet, player, value)
	end
end

local function serverBatch(player: Player, reliable: boolean, buf: any, instances: any)
	if not player.Parent then
		return -- left (or a batch held from before Net.define): per-player state made now would leak
	end
	if typeof(buf) ~= "buffer" then
		Limits.strike(player, nil, "malformed: the batch is not a buffer")
		return
	end
	if instances ~= nil and type(instances) ~= "table" then
		Limits.strike(player, nil, "malformed: bad instance list")
		return
	end
	local len = buffer.len(buf)
	if len == 0 or len > MAX_BATCH_BYTES then
		Limits.strike(player, nil, `malformed: a {len}-byte batch`)
		return
	end
	local reader: Types.Reader = {
		buf = buf,
		cursor = 0,
		len = len,
		instances = instances or EMPTY,
		instanceCursor = 0,
		strict = true,
		stale = false,
	}
	local records = {}
	local current: string? = nil
	local ok, err = pcall(function()
		while reader.cursor < len do
			local began = reader.cursor
			local id = readId(reader)
			local packet = byId[id]
			if not packet then
				error(`unknown packet id {id}`, 0)
			end
			current = packet.name
			if packet.from ~= "client" then
				error("it is sent by the server", 0)
			end
			if packet.reliable ~= reliable then
				error("it came on the wrong channel", 0)
			end
			local seq = if packet.latestOnly then readU16(reader) else nil
			local requestId = if packet.kind == "request" then readU16(reader) else nil
			reader.stale = false
			local value = if packet.codec then packet.codec.read(reader) else nil
			table.insert(records, { packet, value, seq, requestId, reader.stale, reader.cursor - began })
		end
	end)
	if not ok then
		Limits.strike(player, current, `malformed: {err}`)
		return
	end
	for _, record in records do
		receiveFromClient(player, record)
	end
end

local function clientBatch(reliable: boolean, buf: any, instances: any)
	if typeof(buf) ~= "buffer" then
		return
	end
	local len = buffer.len(buf)
	local reader: Types.Reader = {
		buf = buf,
		cursor = 0,
		len = len,
		instances = if type(instances) == "table" then instances else EMPTY,
		instanceCursor = 0,
		strict = false,
		stale = false,
	}
	local records = {}
	local ok, err = pcall(function()
		while reader.cursor < len do
			local began = reader.cursor
			local packet = byId[readId(reader)]
			if not packet then
				error("unknown packet id", 0)
			end
			if packet.kind == "request" then
				local requestId = readU16(reader)
				local status = readU8(reader)
				local value = if status == STATUS_OK and packet.reply then packet.reply.read(reader) else nil
				table.insert(records, { packet, value, nil, requestId, status, reader.cursor - began })
			elseif packet.from == "server" then
				local seq = if packet.latestOnly then readU16(reader) else nil
				local value = if packet.codec then packet.codec.read(reader) else nil
				table.insert(records, { packet, value, seq, nil, nil, reader.cursor - began })
			else
				error(`{packet.name} is a client packet`, 0)
			end
		end
	end)
	if not ok then
		log:warn(`Dropped a batch from the server that did not decode ({err}). Do both sides require the same Packets module?`)
		return
	end
	for _, record in records do
		local packet, value, seq, requestId, status, bytes = record[1], record[2], record[3], record[4], record[5], record[6]
		local stats = packet._stats
		stats.received += 1
		stats.receivedBytes += bytes
		if requestId then
			local entry = pending[requestId]
			if entry and entry.packet == packet then
				pending[requestId] = nil
				if entry.timer then
					task.cancel(entry.timer)
				end
				-- The game may have cancelled the thread that was waiting; resuming it would throw
				-- and lose the rest of this batch.
				if coroutine.status(entry.thread) == "suspended" then
					task.spawn(entry.thread, status, value)
				end
			end
		else
			if seq then
				if not newer(seq, lastSeqClient[packet.id]) then
					stats.dropped += 1
					continue
				end
				lastSeqClient[packet.id] = seq
			end
			deliver(packet, value)
		end
	end
end

local function onBatch(player: Player?, reliable: boolean, buf: any, instances: any)
	if not defined then
		-- Reliable traffic before the Packets module loaded on this side is held until Net.define.
		-- Unreliable traffic is not: it is a stream whose old values nobody wants.
		if not reliable then
			return
		end
		if #rawQueue < RAW_QUEUE_LIMIT then
			table.insert(rawQueue, table.pack(player, reliable, buf, instances))
		elseif not rawQueueWarned then
			rawQueueWarned = true
			log:warn(`Over {RAW_QUEUE_LIMIT} reliable batches arrived before Net.define ran on this side; the rest are dropped. Require the Packets module earlier`)
		end
		return
	end
	if IS_SERVER then
		serverBatch(player :: Player, reliable, buf, instances)
	else
		clientBatch(reliable, buf, instances)
	end
end

-- Definition --------------------------------------------------------------------------------------

--[[ Seals the game's packets and gives them ids. Returns the same table, so its type is what you
	wrote and a misspelt packet is an editor error; at run time reading a missing one errors. ]]
function Net.define<T>(packets: T): T
	if defined then
		error("Net.define was already called. Declare every packet in one Packets module, so both sides agree on the ids", 2)
	end
	if type(packets) ~= "table" then
		error("Net.define takes a table of Net.packet(...) and Net.request(...)", 2)
	end
	local names = {}
	for name, packet in packets :: any do
		if type(name) ~= "string" then
			error("Net.define: packet names must be strings", 2)
		end
		if getmetatable(packet) ~= Packet then
			error(`Net.define: {name} must be Net.packet(...) or Net.request(...)`, 2)
		end
		table.insert(names, name)
	end
	table.sort(names)
	if #names > 65535 then
		error("Net.define: more than 65,535 packets", 2)
	end
	idBytes = if #names > 255 then 2 else 1
	local missingRate = {}
	for id, name in names do
		local packet = (packets :: any)[name]
		if not packet.reliable then
			local header = idBytes + (if packet.latestOnly then 2 else 0)
			local codec = packet.codec
			local cost = Channel.cost(header + (if codec then codec.max else 0), if codec then codec.maxInstances else 0)
			if cost > Channel.UNRELIABLE_BUDGET then
				error(`Net.define: {name} can take {cost} bytes, more than the {Channel.UNRELIABLE_BUDGET} an unreliable packet may (Roblox drops unreliable calls over 1,000). Make it reliable, or lower its maxima`, 2)
			end
		end
		if packet.from == "client" then
			if packet.rate == nil then
				table.insert(missingRate, name)
			end
			local largest = idBytes + 2 + (if packet.codec then packet.codec.max else 0)
			if largest > MAX_BATCH_BYTES then
				error(`Net.define: {name} can take {largest} bytes, more than the {MAX_BATCH_BYTES} the server accepts in one batch. Lower its maxima`, 2)
			end
		end
		packet.name = name
		packet.id = id
		byId[id] = packet
	end
	if IS_SERVER and IS_STUDIO and #missingRate > 0 then
		log:warn(`No rate on {table.concat(missingRate, ", ")}: any client can send {if #missingRate == 1 then "it" else "them"} as fast as it likes. Add rate = n (per second, per player), or rate = math.huge to mean it`)
	end
	defined = true
	setmetatable(packets :: any, {
		__index = function(_, key)
			error(`No packet named "{tostring(key)}".{Util.suggest(tostring(key), names)}`, 2)
		end,
		__newindex = function(_, key)
			error(`Packets are sealed by Net.define; declare "{tostring(key)}" there`, 2)
		end,
	})
	local queued = rawQueue
	rawQueue = {}
	for _, batch in queued do
		onBatch(table.unpack(batch, 1, batch.n))
	end
	return packets
end

--- Server: every strike, as fn(player, packetName?, reason). Logging or kicking is the game's call.
function Net.onAbuse(fn: (player: Player, packetName: string?, reason: string) -> ()): Connection
	if not IS_SERVER then
		error("Net.onAbuse is server only", 2)
	end
	return Limits.onAbuse(fn)
end

--- Server: how many strikes a player has this session.
function Net.strikes(player: Player): number
	return Limits.strikes(player)
end

--[[ Per packet, per second since the last call: sends, bytes, receives, drops. Prints a table
	(busiest first) and returns the numbers. ]]
function Net.stats(): { [string]: { [string]: number } }
	local now = os.clock()
	local seconds = math.max(now - statsSince, 1e-3)
	statsSince = now
	local rows = {}
	local lines = {}
	for _, packet in byId do
		local stats = packet._stats
		local row = {
			sent = stats.sent / seconds,
			sentBytes = stats.sentBytes / seconds,
			received = stats.received / seconds,
			receivedBytes = stats.receivedBytes / seconds,
			dropped = stats.dropped / seconds,
		}
		rows[packet.name] = row
		if stats.sent + stats.received + stats.dropped > 0 then
			table.insert(lines, { packet.name, row })
		end
		stats.sent, stats.sentBytes, stats.received, stats.receivedBytes, stats.dropped = 0, 0, 0, 0, 0
	end
	table.sort(lines, function(a, b)
		return a[2].sentBytes + a[2].receivedBytes > b[2].sentBytes + b[2].receivedBytes
	end)
	local out = { `[Nova.Net] per second over the last {string.format("%.1f", seconds)}s (sent / bytes, received / bytes, dropped)` }
	for _, line in lines do
		local row = line[2]
		table.insert(out, string.format("  %-24s %7.1f %9.0f B   %7.1f %9.0f B   %6.1f", line[1], row.sent, row.sentBytes, row.received, row.receivedBytes, row.dropped))
	end
	if #lines == 0 then
		table.insert(out, "  no traffic")
	end
	print(table.concat(out, "\n"))
	return rows
end

Channel.start(script, onBatch)
if IS_SERVER then
	Players.PlayerRemoving:Connect(function(player)
		-- Deferred: the game's own PlayerRemoving handlers may still send to this player.
		task.defer(function()
			lastSeqServer[player] = nil
			sendSeq[player] = nil
		end)
	end)
end

return Net
