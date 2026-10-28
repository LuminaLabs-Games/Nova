--!strict
--[[
	Server: one ProfileStore session per player, replicated with Replica.

		-- in Nova.boot's `before` (it does not yield; sessions load on their own threads)
		NovaData.start({
			template = require(ServerStorage.DataTemplate),
			productionPlaceId = 1234567890,
			migrations = { function(data) data.Coins = data.Gold; data.Gold = nil end },
		})

		local profile = NovaData.awaitProfile(player)       -- nil if they left first
		NovaData.observeProfiles(function(player, profile)  -- each loaded profile, now and later
			...
			return function() ... end                         -- runs as they leave, before the save closes
		end)

	WHAT HAPPENS WHEN A SAVE OPENS, in order:
	  1. a save marked with `markForWipe` is emptied (its purchase history kept);
	  2. with `reset = { version, keep }`, a save from before that version is rebuilt from the
	     template, keeping the listed keys and the purchase history (CarSteal's ProfileReset);
	  3. `Reconcile` fills in every template key the save lacks;
	  4. `migrations` run in order from the save's `DataVersion`, on a copy: if one throws, the
	     player is kicked and the save is left exactly as it was. A brand-new, wiped or reset save
	     skips them, as it is already current. Migrations must not yield.
	Only then does the replica exist, so no service and no client ever sees the old shape.

	REPLICATION IS TO THE OWNER ONLY by default (`replicateTo = "owner"`). The Shard-era template
	replicated every player's whole save to every client, which is why each NeedohEscape controller
	checked whose replica had arrived. Use "everyone" when other players' data is shown (a
	nametag level), and keep those reads to what is needed.

	KEYS. A live server whose PlaceId is `productionPlaceId` saves under `productionSuffix`; Studio
	and every other place save under `developmentSuffix`, so testing never touches real saves.
	Bump the development suffix to give every tester a fresh save. In Studio, `mock = true` (the
	default) uses ProfileStore's mock store, which starts empty every playtest.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Paths = require(script.Parent.Paths)
local Profile = require(script.Parent.Profile)
local Receipts = require(script.Parent.Receipts)

local IS_STUDIO = RunService:IsStudio()
local WIPE_KEY = "WipeOnNextLoad"
local RESET_KEY = "ResetVersion"

export type Options = {
	template: { [string]: any },
	storeName: string?,
	token: string?,
	mock: boolean?,
	productionPlaceId: number?,
	developmentSuffix: string?,
	productionSuffix: string?,
	replicateTo: ("owner" | "everyone")?,
	migrations: { (data: { [string]: any }, player: Player) -> () }?,
	versionKey: string?,
	reset: { version: string, keep: { string }? }?,
	receipts: boolean?,
	spentKey: string?,
	purchaseHistory: number?,
	profileStore: any?,
	loadFailedMessage: string?,
	sessionEndedMessage: string?,
}

local DEFAULTS = {
	storeName = "PlayerStore",
	token = "PlayerData",
	mock = true,
	productionPlaceId = 0,
	developmentSuffix = "_DEVELOPMENT",
	productionSuffix = "_PRODUCTION",
	replicateTo = "owner",
	migrations = {},
	versionKey = "DataVersion",
	receipts = true,
	purchaseHistory = 1000,
	loadFailedMessage = "We could not load your data. Please rejoin.",
	sessionEndedMessage = "Your data was opened on another server. Please rejoin.",
}

local Server = {}

local options: any = nil
local store: any = nil
local token: any = nil
local paths: Paths.Compiled = { names = {}, ambiguous = {} }
local ReplicaServer: any = nil
local ProfileStore: any = nil

local profiles: { [Player]: any } = {}
local byUserId: { [number]: any } = {}
local waiting: { [Player]: { thread } } = {}
local observers: { { fn: (Player, any) -> any, cleanups: { [Player]: () -> () } } } = {}
local messageHandlers: { [string]: (profile: any, message: { any }) -> boolean } = {}

local function deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in value :: any do
		copy[key] = deepCopy(child)
	end
	return copy :: any
end

local function requireStarted(what: string)
	if not options then
		error(`NovaData.{what} before NovaData.start`, 3)
	end
end

local function suffix(): string
	if not IS_STUDIO and game.PlaceId == options.productionPlaceId then
		return options.productionSuffix
	end
	return options.developmentSuffix
end

--- The DataStore key a user's save lives under on this server.
function Server.keyFor(userId: number): string
	requireStarted("keyFor")
	return `{userId}{suffix()}`
end

local function finishWaiting(player: Player, wrapped: any)
	local threads = waiting[player]
	if not threads then
		return
	end
	waiting[player] = nil
	for _, thread in threads do
		if coroutine.status(thread) == "suspended" then
			task.spawn(thread, wrapped)
		end
	end
end

-- Wipe, reset, reconcile and migrate, before anything can read the save. False and why on failure.
local function prepare(profile: any, player: Player): (boolean, string?)
	local data = profile.Data
	local historyKey = Receipts.historyKey
	local fresh = profile.SessionLoadCount <= 1
	local rebuilt = false

	if data[WIPE_KEY] == true then
		local history = data[historyKey]
		table.clear(data)
		data[historyKey] = history
		rebuilt = true
		print(`[NovaData] Wiped {player.Name}'s save back to the template, as marked`)
	end

	local reset = options.reset
	if reset and data[RESET_KEY] ~= reset.version then
		if not fresh and not rebuilt then
			local kept = {}
			for _, key in reset.keep or {} do
				kept[key] = deepCopy(data[key])
			end
			kept[historyKey] = data[historyKey]
			table.clear(data)
			for key, value in kept do
				data[key] = value
			end
			print(`[NovaData] Reset {player.Name}'s save to version {reset.version}`)
		end
		data[RESET_KEY] = reset.version
		rebuilt = true
	end

	profile:Reconcile()

	local migrations = options.migrations
	local latest = #migrations
	local versionKey = options.versionKey
	if fresh or rebuilt then
		data[versionKey] = latest
		return true
	end
	local version = tonumber(data[versionKey]) or 0
	if version > latest then
		warn(`[NovaData] {player.Name}'s save is at version {version}, newer than this server's {latest} (a rollback?); it is left as it is`)
		return true
	end
	if version == latest then
		return true
	end
	local copy = deepCopy(data)
	for step = version + 1, latest do
		local ok, err = pcall(migrations[step], copy, player)
		if not ok then
			return false, `migration {step} failed: {err}`
		end
		copy[versionKey] = step
	end
	table.clear(data)
	for key, value in copy do
		data[key] = value
	end
	return true
end

local function runObserver(observer: any, player: Player, wrapped: any)
	task.spawn(function()
		local ok, result = pcall(observer.fn, player, wrapped)
		if not ok then
			warn(`[NovaData] observeProfiles callback failed for {player.Name}: {result}`)
		elseif type(result) == "function" then
			if profiles[player] == wrapped then
				observer.cleanups[player] = result
			else
				pcall(result) -- they left while it ran
			end
		end
	end)
end

local function load(player: Player)
	-- The same user back on this server before their old session closed: close it first, or the
	-- new session would wait on this server's own lock.
	local previous = byUserId[player.UserId]
	if previous then
		byUserId[player.UserId] = nil
		local old = previous:GetProfile()
		if old:IsActive() then
			local ended = false
			local connection = old.OnSessionEnd:Connect(function()
				ended = true
			end)
			previous:GetReplica():Destroy()
			old:EndSession()
			while not ended do
				task.wait()
			end
			connection:Disconnect()
		end
	end

	local key = Server.keyFor(player.UserId)
	local profile = nil
	while player.Parent == Players and not ProfileStore.IsClosing do
		profile = store:StartSessionAsync(key, {
			Cancel = function()
				return player.Parent ~= Players
			end,
		})
		if profile then
			break
		end
	end
	if not profile then
		if player.Parent == Players then
			player:Kick(options.loadFailedMessage)
		end
		finishWaiting(player, nil)
		return
	end
	if player.Parent ~= Players then
		-- Left while it loaded. (The template carried on and built a replica for nobody.)
		profile:EndSession()
		finishWaiting(player, nil)
		return
	end

	profile:AddUserId(player.UserId)
	local ok, problem = prepare(profile, player)
	if not ok then
		warn(`[NovaData] {player.Name}'s save did not load: {problem}. Their save is unchanged`)
		profile:EndSession()
		player:Kick(options.loadFailedMessage)
		finishWaiting(player, nil)
		return
	end

	local replica = ReplicaServer.New({
		Token = token,
		Data = profile.Data,
		Tags = { Player = player, NovaPaths = paths },
	})
	if options.replicateTo == "everyone" then
		replica:Replicate()
	elseif ReplicaServer.ReadyPlayers[player] then
		replica:Subscribe(player)
	end

	local wrapped = Profile.new(player, profile, replica, paths)
	profiles[player] = wrapped
	byUserId[player.UserId] = wrapped

	profile.OnSessionEnd:Connect(function()
		if profiles[player] == wrapped then
			profiles[player] = nil
		end
		if byUserId[player.UserId] == wrapped then
			byUserId[player.UserId] = nil
		end
		if replica:IsActive() then
			replica:Destroy()
		end
		-- Their save was opened elsewhere (or the server is closing): playing on would not save.
		player:Kick(options.sessionEndedMessage)
	end)

	profile:MessageHandler(function(message, processed)
		local kind = if type(message) == "table" then message[1] else nil
		local handler = if type(kind) == "string" then messageHandlers[kind] else nil
		if not handler then
			return -- from a newer build, or its handler is not registered: kept for later
		end
		local handled, done = pcall(handler, wrapped, message)
		if not handled then
			warn(`[NovaData] message "{kind}" failed for {player.Name}: {done}`)
		elseif done == true then
			processed()
		end
	end)

	finishWaiting(player, wrapped)
	for _, observer in observers do
		runObserver(observer, player, wrapped)
	end
end

local function unload(player: Player)
	finishWaiting(player, nil)
	local wrapped = profiles[player]
	if not wrapped then
		return
	end
	for _, observer in observers do
		local cleanup = observer.cleanups[player]
		if cleanup then
			observer.cleanups[player] = nil
			local ok, err = pcall(cleanup)
			if not ok then
				warn(`[NovaData] an observeProfiles cleanup failed for {player.Name}: {err}`)
			end
		end
	end
	-- One frame, so on a shutdown BindToClose starts first and ProfileStore's OnLastSave reports
	-- "Shutdown" (Roblox kicks everyone before it runs the BindToClose callbacks).
	RunService.Heartbeat:Wait()
	local profile = wrapped:GetProfile()
	if profile:IsActive() then
		wrapped:GetReplica():Destroy()
		profile:EndSession()
	end
	if profiles[player] == wrapped then
		profiles[player] = nil
	end
	if byUserId[player.UserId] == wrapped then
		byUserId[player.UserId] = nil
	end
end

function Server.start(opts: Options)
	if options then
		error("NovaData.start was already called", 2)
	end
	if not RunService:IsRunning() then
		error("NovaData.start runs in a running game (a playtest or a live server), not in edit mode", 2)
	end
	if type(opts) ~= "table" or type(opts.template) ~= "table" then
		error("NovaData.start needs { template = the table every new save starts as }", 2)
	end
	local merged = table.clone(DEFAULTS) :: any
	for key, value in opts :: any do
		if DEFAULTS[key] == nil and key ~= "template" and key ~= "reset" and key ~= "spentKey" and key ~= "profileStore" then
			error(`NovaData.start got an unknown option "{tostring(key)}"`, 2)
		end
		merged[key] = value
	end
	if merged.replicateTo ~= "owner" and merged.replicateTo ~= "everyone" then
		error('NovaData.start: replicateTo is "owner" or "everyone"', 2)
	end
	for index, migration in merged.migrations do
		if type(migration) ~= "function" then
			error(`NovaData.start: migrations[{index}] is not a function`, 2)
		end
	end
	if merged.reset and type(merged.reset.version) ~= "string" then
		error("NovaData.start: reset = { version = \"2026-11-01\", keep = { ... } }", 2)
	end

	ProfileStore = merged.profileStore
	if not ProfileStore then
		local packages = ServerScriptService:FindFirstChild("ServerPackages")
		local module = packages and packages:FindFirstChild("ProfileStore")
		if not module then
			error("NovaData needs ProfileStore: add lm-loleris/profilestore to [server-dependencies], or pass profileStore = require(...)", 2)
		end
		ProfileStore = require(module :: ModuleScript) :: any
	end
	ReplicaServer = require(script.Parent.Parent.ReplicaServer) :: any
	options = merged

	store = ProfileStore.New(merged.storeName, merged.template)
	if IS_STUDIO and merged.mock then
		store = store.Mock
		print("[NovaData] Studio is using ProfileStore's mock store: saves start empty every playtest")
	elseif not IS_STUDIO and merged.productionPlaceId == 0 then
		warn(`[NovaData] productionPlaceId is not set, so this live server saves under "{merged.developmentSuffix}"`)
	end
	token = ReplicaServer.Token(merged.token)
	paths = Paths.compile(merged.template)
	Receipts.spentKey = merged.spentKey
	Receipts.historySize = merged.purchaseHistory

	if merged.receipts then
		MarketplaceService.ProcessReceipt = function(receipt)
			return Receipts.process(receipt, Server.awaitProfile)
		end
	end
	if merged.replicateTo == "owner" then
		-- A player's client asks for data after its boot; subscribe them to their own replica then.
		ReplicaServer.NewReadyPlayer:Connect(function(player)
			local wrapped = profiles[player]
			if wrapped and wrapped:GetReplica():IsActive() then
				wrapped:GetReplica():Subscribe(player)
			end
		end)
	end
	Players.PlayerAdded:Connect(load)
	Players.PlayerRemoving:Connect(unload)
	for _, player in Players:GetPlayers() do
		task.spawn(load, player)
	end
end

--- The player's profile if it has loaded, else nil. Does not yield.
function Server.getProfile(player: Player): Profile.Profile?
	requireStarted("getProfile")
	return profiles[player]
end

--[[ Yields until the player's profile has loaded and returns it, or nil if they leave first, it
	fails to load, or `timeout` seconds pass. ]]
function Server.awaitProfile(player: Player, timeout: number?): Profile.Profile?
	requireStarted("awaitProfile")
	local loaded = profiles[player]
	if loaded or player.Parent ~= Players then
		return loaded
	end
	local thread = coroutine.running()
	waiting[player] = waiting[player] or {}
	table.insert(waiting[player], thread)
	local timer = nil
	if timeout then
		timer = task.delay(timeout, function()
			local list = waiting[player]
			local index = list and table.find(list, thread)
			if index then
				table.remove(list, index)
				task.spawn(thread, nil)
			end
		end)
	end
	local wrapped = coroutine.yield()
	if timer and coroutine.status(timer) == "suspended" then
		task.cancel(timer)
	end
	return wrapped
end

--[[ Calls fn(player, profile) for every loaded profile, now and as each one loads, on its own
	thread. A function it returns runs when that player leaves, before the session closes, so a
	last write (an offline timestamp) is saved. Returns a connection; disconnecting runs the
	outstanding cleanups. ]]
function Server.observeProfiles(fn: (player: Player, profile: Profile.Profile) -> (() -> ())?): { Disconnect: (any) -> () }
	local observer = { fn = fn :: any, cleanups = {} }
	table.insert(observers, observer)
	for player, wrapped in profiles do
		runObserver(observer, player, wrapped)
	end
	return {
		Disconnect = function()
			local index = table.find(observers, observer)
			if index then
				table.remove(observers, index)
			end
			for _, cleanup in observer.cleanups do
				pcall(cleanup)
			end
			table.clear(observer.cleanups)
		end,
	}
end

--[[ What developer product `productId` grants: fn(profile, receipt). It errors, or returns false,
	when the grant did not land, and Roblox retries. See Receipts. ]]
function Server.onProduct(productId: number, fn: Receipts.Handler)
	if type(productId) ~= "number" or type(fn) ~= "function" then
		error("NovaData.onProduct(productId, function(profile, receipt) ... end)", 2)
	end
	if Receipts.handlers[productId] then
		error(`NovaData.onProduct: product {productId} already has a handler`, 2)
	end
	Receipts.handlers[productId] = fn
end

--[[ The handler for one kind of ProfileStore message: a list whose first element names it,
	{ "Gift", "Cash", 25000, fromUserId }. fn(profile, message) returns true when the message has
	landed and may be discarded; anything else keeps it, and it is offered again when the player's
	save next opens. Register at require time: a session replays its queued messages the moment it
	opens. ]]
function Server.onMessage(kind: string, fn: (profile: Profile.Profile, message: { any }) -> boolean)
	if type(kind) ~= "string" or type(fn) ~= "function" then
		error("NovaData.onMessage(kind, function(profile, message) return true end)", 2)
	end
	if messageHandlers[kind] then
		error(`NovaData.onMessage: "{kind}" already has a handler`, 2)
	end
	messageHandlers[kind] = fn :: any
end

--[[ Queues a message for a user's save, online or not, on any server: { "Gift", "Cash", 25000 }.
	Yields; returns whether it was queued. ]]
function Server.sendMessage(userId: number, message: { any }): boolean
	requireStarted("sendMessage")
	if type(message) ~= "table" or type(message[1]) ~= "string" then
		error("NovaData.sendMessage: a message is a list whose first element names it, { \"Gift\", ... }", 2)
	end
	return store:MessageAsync(Server.keyFor(userId), message)
end

--[[ Marks the player's save to be emptied back to the template the next time it opens, keeping its
	purchase history. Marked rather than wiped now, because services still hold this player's state
	and may write on the way out; the mark rides out on that last save. Send the player away after
	(a rejoin). False when there is no live session to mark. ]]
function Server.markForWipe(player: Player): boolean
	requireStarted("markForWipe")
	local wrapped = profiles[player]
	if not (wrapped and wrapped:IsActive()) then
		return false
	end
	wrapped:GetProfile().Data[WIPE_KEY] = true
	return true
end

--- True when this server uses Studio's mock store, which starts empty every playtest.
function Server.isMock(): boolean
	return options ~= nil and IS_STUDIO and options.mock == true
end

--- The ProfileStore store itself, for offline reads (GetAsync, VersionQuery) and admin tools.
function Server.store(): any
	requireStarted("store")
	return store
end

return Server
