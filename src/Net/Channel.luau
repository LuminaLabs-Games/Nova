--!strict
--[[
	Channel: the two remotes and the batching.

	Two remotes in total, a RemoteEvent and an UnreliableRemoteEvent, made by the server under this
	package's Net module. No per-packet instances, so nothing to WaitForChild by name and no
	10-second timeout on one.

	Sends queue into a buffer (one per player per channel on the server) and flush on Heartbeat: one
	remote call per channel per frame, about 60 a second against Roblox's limit of roughly 500, and
	reliable packets keep their order.

	An unreliable call over 1,000 bytes is dropped by Roblox, so an unreliable batch is flushed early
	before it would pass the budget below, and a packet that could never fit is refused at
	Net.define. Instances ride beside the buffer and count against the budget too. A reliable batch
	is cut at 64 KB, the most the server accepts from a client in one call; the pieces go out in
	order.

	A client never yields on these: sends queue until the remotes have replicated.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Types = require(script.Parent.Types)

local IS_SERVER = RunService:IsServer()

local Channel = {}

--- Bytes an unreliable batch may hold, leaving room under Roblox's 1,000 for the call itself.
Channel.UNRELIABLE_BUDGET = 900
--- What one Instance reference is assumed to cost against that budget.
Channel.INSTANCE_COST = 8
--- Bytes a reliable batch may hold. The server refuses a bigger batch from a client, so a client
--- splits its own at this size.
Channel.RELIABLE_BUDGET = 65536

type Batch = { buf: buffer, instances: { Instance }? }
-- `sealed`: reliable batches already cut at the budget, waiting their turn so order holds.
type Outgoing = { reliable: Types.Writer, unreliable: Types.Writer, sealed: { Batch } }

local reliableRemote: RemoteEvent? = nil
local unreliableRemote: UnreliableRemoteEvent? = nil
local outgoing: { [any]: Outgoing } = {}
local CLIENT = "client"
local started = false

local function box(player: Player?): Outgoing
	local key: any = player or CLIENT
	local found = outgoing[key]
	if not found then
		found = { reliable = Types.newWriter(1024), unreliable = Types.newWriter(1024), sealed = {} }
		outgoing[key] = found
	end
	return found
end

-- The writer's contents as a batch of their own; the writer is left empty.
local function take(w: Types.Writer): Batch
	local out = buffer.create(w.cursor)
	buffer.copy(out, 0, w.buf, 0, w.cursor)
	local instances = nil
	if w.instanceCount > 0 then
		instances = table.move(w.instances, 1, w.instanceCount, 1, table.create(w.instanceCount))
	end
	Types.reset(w)
	return { buf = out, instances = instances }
end

local function fire(player: Player?, remote: any, batch: Batch)
	if IS_SERVER then
		if (player :: Player).Parent then
			remote:FireClient(player, batch.buf, batch.instances)
		end
	else
		remote:FireServer(batch.buf, batch.instances)
	end
end

local function flushReliable(player: Player?, outbox: Outgoing)
	local remote = reliableRemote
	if not remote then
		return -- a client before the remotes replicate: reliable sends wait, in order
	end
	if #outbox.sealed > 0 then
		for _, batch in outbox.sealed do
			fire(player, remote, batch)
		end
		table.clear(outbox.sealed)
	end
	if outbox.reliable.cursor > 0 then
		fire(player, remote, take(outbox.reliable))
	end
end

local function flushUnreliable(player: Player?, outbox: Outgoing)
	local w = outbox.unreliable
	if w.cursor == 0 then
		return
	end
	if not unreliableRemote then
		Types.reset(w) -- a client before the remotes replicate: unreliable sends are stale
		return
	end
	fire(player, unreliableRemote, take(w))
end

--- Bytes and instance slots one record takes against the unreliable budget.
function Channel.cost(bytes: number, instances: number): number
	return bytes + instances * Channel.INSTANCE_COST
end

--[[ Appends one encoded record (the scratch writer's contents) to `player`'s batch (nil = the
	client's own). Records are copied, so one encode serves every player of a sendAll. Returns the
	writer and the offset the record starts at (nil when the player has left). ]]
function Channel.append(player: Player?, reliable: boolean, record: Types.Writer): (Types.Writer?, number)
	if player and not player.Parent then
		-- Left the game: a box made now would never be cleared.
		return nil, 0
	end
	local outbox = box(player)
	local w = if reliable then outbox.reliable else outbox.unreliable
	if w.cursor > 0 then
		if reliable then
			if w.cursor + record.cursor > Channel.RELIABLE_BUDGET then
				table.insert(outbox.sealed, take(w))
				flushReliable(player, outbox)
			end
		elseif Channel.cost(w.cursor + record.cursor, w.instanceCount + record.instanceCount) > Channel.UNRELIABLE_BUDGET then
			flushUnreliable(player, outbox)
		end
	end
	local start = w.cursor
	Types.reserve(w, record.cursor)
	buffer.copy(w.buf, start, record.buf, 0, record.cursor)
	w.cursor += record.cursor
	for i = 1, record.instanceCount do
		w.instanceCount += 1
		w.instances[w.instanceCount] = record.instances[i]
	end
	return w, start
end

local function flushAll()
	for key, outbox in outgoing do
		local player = if key == CLIENT then nil else key
		if player and not player.Parent then
			outgoing[key] = nil -- left; anything still queued for them goes nowhere
			continue
		end
		flushReliable(player, outbox)
		flushUnreliable(player, outbox)
	end
end

--[[ Makes (server) or finds (client) the remotes and starts flushing. `onBatch(player, reliable,
	buf, instances)` gets every incoming batch; player is nil on the client. ]]
function Channel.start(parent: Instance, onBatch: (Player?, boolean, any, any) -> ())
	if started or not RunService:IsRunning() then
		return
	end
	started = true
	if IS_SERVER then
		local reliable = parent:FindFirstChild("Reliable") :: RemoteEvent?
		if not reliable then
			reliable = Instance.new("RemoteEvent")
			;(reliable :: RemoteEvent).Name = "Reliable"
			;(reliable :: RemoteEvent).Parent = parent
		end
		local unreliable = parent:FindFirstChild("Unreliable") :: UnreliableRemoteEvent?
		if not unreliable then
			unreliable = Instance.new("UnreliableRemoteEvent")
			;(unreliable :: UnreliableRemoteEvent).Name = "Unreliable"
			;(unreliable :: UnreliableRemoteEvent).Parent = parent
		end
		reliableRemote, unreliableRemote = reliable, unreliable
		;(reliable :: RemoteEvent).OnServerEvent:Connect(function(player, buf, instances)
			onBatch(player, true, buf, instances)
		end)
		;(unreliable :: UnreliableRemoteEvent).OnServerEvent:Connect(function(player, buf, instances)
			onBatch(player, false, buf, instances)
		end)
		Players.PlayerRemoving:Connect(function(player)
			outgoing[player] = nil
		end)
	else
		task.spawn(function()
			-- A timeout argument keeps Roblox's "infinite yield" warning quiet; the server makes
			-- these as soon as Nova loads, so this resolves with the first replication.
			local reliable = parent:WaitForChild("Reliable", math.huge) :: RemoteEvent
			local unreliable = parent:WaitForChild("Unreliable", math.huge) :: UnreliableRemoteEvent
			reliable.OnClientEvent:Connect(function(buf, instances)
				onBatch(nil, true, buf, instances)
			end)
			unreliable.OnClientEvent:Connect(function(buf, instances)
				onBatch(nil, false, buf, instances)
			end)
			reliableRemote, unreliableRemote = reliable, unreliable
		end)
	end
	RunService.Heartbeat:Connect(flushAll)
end

return Channel
