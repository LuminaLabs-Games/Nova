--!strict
--[[
	Client: this player's save, read-only, as it replicates.

		NovaData.request()                       -- once, after the controllers are up (Nova.boot's after)
		NovaData.observe("Cash", function(cash) ... end)  -- runs when the data arrives, then on every change
		local level = NovaData.read("Level")     -- nil until it has arrived
		NovaData.ready(10)                       -- yields until it arrives; false on timeout

	It replaces the block every NeedohEscape controller repeated: ReplicaClient.OnNew("PlayerData"),
	then a check that the replica is the local player's, then OnSet listeners per key.

	Paths resolve exactly as on the server (the server sends the template's index on the replica's
	tags), so "Level" means Stats.Level on both sides. `observe` fires for a change at its path or
	anywhere under it; for a table that is any change inside it.

	Writes happen on the server only. To change data, send a packet and let a service write it.
]]

local Players = game:GetService("Players")

local Paths = require(script.Parent.Paths)

export type Connection = { Connected: boolean, Disconnect: (self: any) -> () }

type Observer = { path: any, fn: (any) -> (), last: any, connection: any?, handle: any }

local Client = {}

local requested = false
local mine: any = nil
local others: { [Player]: any } = {}
local waiting: { thread } = {}
local observers: { Observer } = {}

local function compiled(replica: any): Paths.Compiled
	return replica.Tags.NovaPaths or { names = {}, ambiguous = {} }
end

local function resolve(replica: any, path: any, level: number): Paths.Path
	local ok, result = pcall(Paths.resolve, compiled(replica), path)
	if not ok then
		error(`NovaData: {result}`, level + 1)
	end
	return result
end

local function attach(observer: Observer)
	local replica = mine
	local path = resolve(replica, observer.path, 2)
	observer.connection = replica:OnChange(function(_action, changed)
		if not observer.handle.Connected or not Paths.overlaps(changed, path) then
			return
		end
		local value = Paths.read(replica.Data, path)
		if value ~= observer.last or type(value) == "table" then
			observer.last = value
			task.spawn(observer.fn, value)
		end
	end)
	observer.last = Paths.read(replica.Data, path)
	task.spawn(observer.fn, observer.last)
end

--[[ Asks the server for this player's data. Call it once, after anything that observes is
	connected (in Nova.boot's `after`). `token` must match the server's (default "PlayerData"). ]]
function Client.request(options: { token: string? }?)
	if requested then
		error("NovaData.request was already called; it asks once", 2)
	end
	requested = true
	local tokenName = options and options.token or "PlayerData"
	local ReplicaClient = require(script.Parent.Parent.ReplicaClient) :: any
	ReplicaClient.OnNew(tokenName, function(replica)
		local owner = replica.Tags.Player
		if owner == Players.LocalPlayer then
			mine = replica
			for _, observer in observers do
				if observer.handle.Connected then
					task.spawn(attach, observer)
				end
			end
			local threads = waiting
			waiting = {}
			for _, thread in threads do
				if coroutine.status(thread) == "suspended" then
					task.spawn(thread, true)
				end
			end
		elseif typeof(owner) == "Instance" then
			others[owner] = replica
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		others[player] = nil
	end)
	ReplicaClient.RequestData()
end

--- Yields until this player's data has arrived. False after `timeout` seconds without it.
function Client.ready(timeout: number?): boolean
	if mine then
		return true
	end
	local thread = coroutine.running()
	table.insert(waiting, thread)
	local timer = nil
	if timeout then
		timer = task.delay(timeout, function()
			local index = table.find(waiting, thread)
			if index then
				table.remove(waiting, index)
				task.spawn(thread, false)
			end
		end)
	end
	local arrived = coroutine.yield()
	if timer and coroutine.status(timer) == "suspended" then
		task.cancel(timer)
	end
	return arrived
end

--- The value at `path` in this player's data (the whole table with no path), or nil before it arrives.
function Client.read(path: any?): any
	if not mine then
		return nil
	end
	if path == nil then
		return mine.Data
	end
	return Paths.read(mine.Data, resolve(mine, path, 2))
end

--[[ Another player's data, when the server replicates to everyone (`replicateTo = "everyone"`);
	nil otherwise or before it arrives. ]]
function Client.readFor(player: Player, path: any?): any
	local replica = others[player]
	if player == Players.LocalPlayer then
		replica = mine
	end
	if not replica then
		return nil
	end
	if path == nil then
		return replica.Data
	end
	return Paths.read(replica.Data, resolve(replica, path, 2))
end

--[[ Calls fn(value) with the value at `path` once the data has arrived, then after every change at
	or under it. Returns a connection. ]]
function Client.observe(path: any, fn: (value: any) -> ()): Connection
	if type(fn) ~= "function" then
		error("NovaData.observe(path, function(value) ... end)", 2)
	end
	local handle = { Connected = true }
	local observer: Observer = { path = path, fn = fn, last = nil, connection = nil, handle = handle }
	function handle.Disconnect(_self: any)
		handle.Connected = false
		if observer.connection then
			observer.connection:Disconnect()
		end
		local index = table.find(observers, observer)
		if index then
			table.remove(observers, index)
		end
	end
	table.insert(observers, observer)
	if mine then
		-- Resolve now, so a misspelt path errors at this call.
		resolve(mine, path, 2)
		attach(observer)
	end
	return handle :: any
end

return Client
