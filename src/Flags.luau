--!strict
--[[
	Flags: every feature flag in the game, flippable without a code edit.

	Where a value comes from, highest first:
	  1. per player: an attribute on the Player, `Flag_<Name>`, written by the server from
	     `Nova.flags.setProvider` (an A/B test) or `Nova.flags.setFor` (a Cmdr command);
	  2. live: an attribute on `ReplicatedStorage.NovaFlags`, which the server creates at boot with
	     every flag on it, so the Properties panel lists them all and `Nova.flags.set` flips one for
	     the whole server;
	  3. the default in the game's `Flags.luau` (or a module's `withFlags`), with an optional
	     Studio-only value: `SkipIntro = { default = false, studio = true }`.

	Only a flag the server knows (Flags.luau, or a service's withFlags) is on NovaFlags and can be
	flipped live. A flag only a controller declares is a fixed default; boot warns about one.

	Clients read and never write: both attribute sources replicate, so a client sees exactly what the
	server decided for it.

	A flag may be a boolean, a number or a string ("badge" | "notification" style experiments). A
	value of the wrong type from an attribute is ignored with a warning, never used. A name nobody
	declared is an error, so `flag("NewRecoli")` fails at the call instead of reading as off.

	A `NovaFlags` object saved in the place (made in edit mode) keeps its attribute values: that is a
	place-wide override, and the boot log lists every flag it changes so it is never invisible.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Log = require(script.Parent.Log)
local Signal = require(script.Parent.Signal)
local Util = require(script.Parent.Util)

export type Value = boolean | number | string
export type Definition = Value | { default: Value, studio: Value? }
export type Connection = { Connected: boolean, Disconnect: (self: any) -> () }

type Entry = { default: Value, source: string }

local IS_STUDIO = RunService:IsStudio()
local IS_SERVER = RunService:IsServer() and RunService:IsRunning()
local FOLDER_NAME = "NovaFlags"
local PLAYER_PREFIX = "Flag_"
local READY_ATTRIBUTE = "NovaFlagsReady"

local log = Log.new("Nova.flags")

local Flags = {}

local entries: { [string]: Entry } = {
	NovaDebug = { default = "", source = "Nova" },
}
local folder: Instance? = nil
local folderFound = Signal.new()
local started = false
local booted = false
local provider: ((name: string, player: Player) -> Value?)? = nil
--- Per player, the flags `setFor` pinned by hand; the provider leaves those alone.
local manual: { [Player]: { [string]: boolean } } = {}
--- Per player, which provider run is the newest; an older run that is still yielding stops.
local generation: { [Player]: number } = {}

local function resolveDefault(name: string, definition: Definition, source: string): Value
	local value: any = definition
	if type(definition) == "table" then
		Util.checkKeys(definition, { "default", "studio" }, `Flag {name}`)
		value = definition.default
		local studio = definition.studio
		if studio ~= nil then
			if type(studio) ~= type(value) then
				error(`Flag {name} in {source}: studio value is a {type(studio)} but the default is a {type(value)}`, 0)
			end
			if IS_STUDIO then
				value = studio
			end
		end
	end
	local kind = type(value)
	if kind ~= "boolean" and kind ~= "number" and kind ~= "string" then
		error(`Flag {name} in {source}: a flag is a boolean, a number or a string, not a {kind}`, 0)
	end
	if not string.match(name, "^[%a_][%w_]*$") or #name > 90 then
		error(`Flag name "{name}" in {source} must be letters, digits and underscores (it becomes an attribute name)`, 0)
	end
	return value
end

local function entryFor(name: string, level: number?): Entry
	local entry = entries[name]
	if entry then
		return entry
	end
	if type(name) ~= "string" then
		error(`A flag name is a string, got {typeof(name)}`, (level or 2) + 1)
	end
	-- A flag only the other side declared still reads if the server put it on NovaFlags.
	local value = folder and folder:GetAttribute(name)
	if value ~= nil then
		entry = { default = value, source = "NovaFlags" }
		entries[name] = entry
		return entry
	end
	error(`Unknown flag "{name}". Add it to Flags.luau or to a module's withFlags.{Util.suggest(name, entries)}`, (level or 2) + 1)
end

local function pick(entry: Entry, value: any): any
	if value ~= nil and type(value) == type(entry.default) then
		return value
	end
	return nil
end

local function read(name: string, player: Player?, level: number?): Value
	local entry = entryFor(name, (level or 2) + 1)
	if player then
		local value = pick(entry, player:GetAttribute(PLAYER_PREFIX .. name))
		if value ~= nil then
			return value
		end
	end
	if folder then
		local value = pick(entry, folder:GetAttribute(name))
		if value ~= nil then
			return value
		end
	end
	return entry.default
end

local function defaultPlayer(player: Player?): Player?
	if player == nil and RunService:IsClient() then
		return Players.LocalPlayer
	end
	return player
end

local function requireServer(what: string)
	if not IS_SERVER then
		error(`Nova.flags.{what} is server only; clients read flags and never write them`, 3)
	end
end

local function checkValue(name: string, value: any)
	local entry = entryFor(name, 3)
	if value ~= nil and type(value) ~= type(entry.default) then
		error(`Flag {name} is a {type(entry.default)}; got a {type(value)}`, 3)
	end
end

--[[ Registers the game's flags (the table `Flags.luau` returns). Nova.boot calls this with its
	`flags` option; call it yourself only to read flags outside a booted game. ]]
function Flags.define(definitions: { [string]: Definition })
	if type(definitions) ~= "table" then
		error("Nova.flags.define expects the table of flags Flags.luau returns", 2)
	end
	for name, definition in definitions do
		local existing = entries[name]
		if existing and existing.source == "Nova" then
			error(`Flag name {name} is reserved by Nova`, 2)
		end
		entries[name] = { default = resolveDefault(name, definition, "Flags.luau"), source = "Flags.luau" }
	end
end

--[[ A module's `withFlags`. A default it gives is used only when Flags.luau lacks the flag; when both
	give a value and they differ, Flags.luau wins and this returns the warning to print. ]]
function Flags._declare(moduleName: string, definitions: { [string]: Definition }): { string }
	local warnings = {}
	for name, definition in definitions do
		local value = resolveDefault(name, definition, moduleName)
		local existing = entries[name]
		if not existing then
			entries[name] = { default = value, source = moduleName }
		elseif existing.default ~= value then
			if existing.source == "Flags.luau" then
				table.insert(warnings, `{moduleName} declares {name} = {tostring(value)} but Flags.luau says {tostring(existing.default)}; Flags.luau wins`)
			elseif existing.source ~= "Nova" then
				table.insert(warnings, `{moduleName} and {existing.source} both declare {name} with different defaults; {existing.source} wins`)
			end
		end
	end
	return warnings
end

function Flags._has(name: string): boolean
	return entries[name] ~= nil
end

--- The value of a flag, for `player` when given (the local player on a client).
function Flags.get(name: string, player: Player?): Value
	return read(name, defaultPlayer(player), 2)
end

--[[ Calls `fn` with the flag's value now, then again every time it changes, for `player` when
	given (the local player on a client). Returns a connection to stop. ]]
function Flags.observe(name: string, fn: (value: any) -> (), player: Player?): Connection
	entryFor(name, 2)
	player = defaultPlayer(player)
	local connections: { RBXScriptConnection } = {}
	local handle = { Connected = true }
	local last: any = read(name, player)

	local function update()
		if not handle.Connected then
			return
		end
		local value = read(name, player)
		if value ~= last then
			last = value
			task.spawn(fn, value)
		end
	end

	local function watchFolder(found: Instance)
		table.insert(connections, found:GetAttributeChangedSignal(name):Connect(update))
		update()
	end

	if folder then
		watchFolder(folder)
	else
		local waiting
		waiting = folderFound:Connect(function(found)
			waiting:Disconnect()
			if handle.Connected then
				watchFolder(found)
			end
		end)
		table.insert(connections, waiting :: any)
	end
	if player then
		table.insert(connections, player:GetAttributeChangedSignal(PLAYER_PREFIX .. name):Connect(update))
	end

	function handle.Disconnect(_self: any)
		handle.Connected = false
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
	end

	task.spawn(fn, last)
	return handle :: any
end

--- Every flag's current value, for `player` when given (the local player on a client).
function Flags.all(player: Player?): { [string]: Value }
	player = defaultPlayer(player)
	local values = {}
	for name in entries do
		values[name] = read(name, player)
	end
	return values
end

--- Server: sets a flag for the whole server, live. `nil` puts it back to its default.
function Flags.set(name: string, value: Value?)
	requireServer("set")
	checkValue(name, value)
	assert(folder, "Nova.flags.set before Nova.boot")
	folder:SetAttribute(name, if value == nil then entries[name].default else value)
end

--- Server: pins a flag for one player (an admin command, a tester). `nil` hands it back to the provider.
function Flags.setFor(player: Player, name: string, value: Value?)
	requireServer("setFor")
	checkValue(name, value)
	manual[player] = manual[player] or {}
	if value == nil then
		manual[player][name] = nil
		player:SetAttribute(PLAYER_PREFIX .. name, nil)
		Flags.refresh(player)
	else
		manual[player][name] = true
		player:SetAttribute(PLAYER_PREFIX .. name, value)
	end
end

local function pinned(player: Player, name: string): boolean
	local pins = manual[player]
	return pins ~= nil and pins[name] == true
end

local function applyProvider(player: Player)
	local run = (generation[player] or 0) + 1
	generation[player] = run
	local current = provider
	if current then
		for _, name in Util.keys(entries) do
			local entry = entries[name]
			if pinned(player, name) then
				continue
			end
			local ok, value = pcall(current, name, player)
			if not player.Parent or generation[player] ~= run then
				return -- left, or a newer run (a refresh, a new provider) took over
			end
			if pinned(player, name) then
				continue -- setFor pinned it while the provider was yielding
			end
			if not ok then
				log:warn(`The flag provider failed for {name} ({player.Name}): {value}`)
			elseif value ~= nil and type(value) ~= type(entry.default) then
				log:warn(`The flag provider gave {name} a {type(value)} for {player.Name}; the flag is a {type(entry.default)}`)
			else
				player:SetAttribute(PLAYER_PREFIX .. name, value)
			end
		end
	end
	if booted then
		player:SetAttribute(READY_ATTRIBUTE, true)
	end
end

--[[ Server: `fn(name, player)` returns what one player sees, or nil for the server's value. Set it
	in a module's init or start; every player is evaluated again at once and on join. It may yield
	(an experiment lookup), so values can land a moment after the player joins: a client's boot
	waits for them (a few seconds at most) before any controller runs. ]]
function Flags.setProvider(fn: (name: string, player: Player) -> Value?)
	requireServer("setProvider")
	provider = fn
	Flags.refresh()
end

--- Server: asks the provider again, for one player or for everyone.
function Flags.refresh(player: Player?)
	requireServer("refresh")
	if player then
		task.spawn(applyProvider, player)
	else
		for _, each in Players:GetPlayers() do
			task.spawn(applyProvider, each)
		end
	end
end

-- Server: makes NovaFlags and writes every flag on it. Client: finds it. Called once by Nova.boot,
-- after every module's withFlags is in.
function Flags._start()
	if started or not RunService:IsRunning() then
		return
	end
	started = true
	if IS_SERVER then
		local found = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		local made = found or Instance.new("Configuration")
		local overridden = {}
		for name, entry in entries do
			local existing = made:GetAttribute(name)
			if existing == nil then
				made:SetAttribute(name, entry.default)
			elseif type(existing) ~= type(entry.default) then
				log:warn(`NovaFlags.{name} is a {type(existing)} but the flag is a {type(entry.default)}; using the default`)
				made:SetAttribute(name, entry.default)
			elseif existing ~= entry.default then
				table.insert(overridden, `{name}={tostring(existing)}`)
			end
		end
		for name in made:GetAttributes() do
			if not entries[name] then
				log:warn(`NovaFlags has an attribute "{name}" that no flag declares.{Util.suggest(name, entries)}`)
			end
		end
		if #overridden > 0 then
			table.sort(overridden)
			log:info(`The place's NovaFlags overrides: {table.concat(overridden, ", ")}`)
		end
		made.AttributeChanged:Connect(function(name)
			local entry = entries[name]
			local value = made:GetAttribute(name)
			if entry and value ~= nil and type(value) ~= type(entry.default) then
				log:warn(`NovaFlags.{name} was set to a {type(value)}; the flag is a {type(entry.default)}, so it is ignored`)
			end
		end)
		made.Name = FOLDER_NAME
		made.Parent = ReplicatedStorage
		folder = made
		Players.PlayerAdded:Connect(function(player)
			task.spawn(applyProvider, player)
		end)
		Players.PlayerRemoving:Connect(function(player)
			task.defer(function()
				manual[player] = nil
				generation[player] = nil
			end)
		end)
		folderFound:Fire(made)
	else
		local found = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if found then
			folder = found
			folderFound:Fire(found)
		else
			local connection
			connection = ReplicatedStorage.ChildAdded:Connect(function(child)
				if child.Name == FOLDER_NAME then
					connection:Disconnect()
					folder = child
					folderFound:Fire(child)
				end
			end)
		end
	end
end

-- Server, at the end of boot: from here a player's flags are settled once the provider has run.
function Flags._serverBooted()
	booted = true
	for _, player in Players:GetPlayers() do
		task.spawn(applyProvider, player)
	end
end

-- Client: flags only a controller declared (withFlags) that the server does not know, so they
-- are not on NovaFlags and can never be flipped live. Boot warns about them.
function Flags._unknownToServer(): { string }
	local names = {}
	if folder then
		for name, entry in entries do
			if entry.source ~= "Flags.luau" and entry.source ~= "Nova" and entry.source ~= "NovaFlags" and folder:GetAttribute(name) == nil then
				table.insert(names, name)
			end
		end
		table.sort(names)
	end
	return names
end

-- Client: waits (up to `timeout`) for the server to settle this player's flags. True when it did.
function Flags._waitForPlayer(timeout: number): boolean
	local player = Players.LocalPlayer
	if player:GetAttribute(READY_ATTRIBUTE) then
		return true
	end
	local ok = Signal.waitFor(player:GetAttributeChangedSignal(READY_ATTRIBUTE) :: any, timeout)
	return ok
end

return Flags
