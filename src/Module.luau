--!strict
--[[
	Module: the builder behind `Nova.new`, one file for services (server) and controllers (client).
	Shard had ShardService and ShardController, two near-identical 500-line files.

		local CombatService = Nova.new("CombatService")
			:withDependencies({ "InventoryService" })
			:withSignals({ "PlayerDowned" })
			:withFlags({ NewRecoil = false })
			:withLifecycle({
				init = function(self) ... end,   -- must not yield
				start = function(self) ... end,  -- its own thread; may yield
			})

	Plain `function CombatService:init()` / `:start()` methods work too, as in Shard.

	Nova keeps its own state under one key, `_nova`, and puts only `name`, `log` and `trove` on the
	module: a Shard module was a plain table, so a field the game parked on `self` (`self._decline`)
	could shadow a framework method of the same name. Fewer framework names, fewer collisions.

	Builders run at require time. Calling one after boot has read the module is an error, because
	it would silently do nothing.
]]

local Flags = require(script.Parent.Flags)
local Log = require(script.Parent.Log)
local Signal = require(script.Parent.Signal)
local Trove = require(script.Parent.Parent.Trove)
local Util = require(script.Parent.Util)

export type Lifecycle = {
	init: ((self: any) -> ())?,
	start: ((self: any) -> ())?,
}

export type Module = {
	name: string,
	log: Log.Logger,
	trove: any,
	withLifecycle: (self: Module, lifecycle: Lifecycle) -> Module,
	withDependencies: (self: Module, names: { string }) -> Module,
	withSignals: (self: Module, names: { string }) -> Module,
	getSignal: (self: Module, name: string) -> Signal.Signal<...any>,
	withCleanup: (self: Module, task: any) -> Module,
	withFlags: (self: Module, flags: { [string]: Flags.Definition }) -> Module,
	flag: (self: Module, name: string, player: Player?) -> any,
	withConfig: (self: Module, config: { [string]: any }) -> Module,
	getConfig: (self: Module, key: string, default: any?) -> any,
	destroy: (self: Module) -> (),
	[any]: any,
}

local Module = {}
Module.__index = Module

function Module.new(name: string, kind: string, source: string): Module
	local self = setmetatable({
		name = name,
		log = Log.new(name),
		trove = Trove.new(),
		_nova = {
			kind = kind,
			source = source,
			lifecycle = {} :: Lifecycle,
			dependencies = {} :: { string },
			signals = {} :: { [string]: any },
			flags = {} :: { [string]: Flags.Definition },
			config = {} :: { [string]: any },
			locked = false,
			state = "registered",
		},
	}, Module)
	return (self :: any) :: Module
end

function Module.is(value: any): boolean
	return type(value) == "table" and getmetatable(value) == Module
end

local function open(self: any, what: string)
	if self._nova.locked then
		error(`{self.name}:{what} was called after Nova.boot read the module; call builders when the module is required`, 3)
	end
end

local function nameList(self: any, names: any, what: string): { string }
	if type(names) ~= "table" then
		error(`{self.name}:{what} expects a list of names`, 3)
	end
	for _, name in names do
		if type(name) ~= "string" then
			error(`{self.name}:{what} expects a list of names; got a {typeof(name)}`, 3)
		end
	end
	return names
end

function Module.withLifecycle(self: any, lifecycle: Lifecycle): Module
	open(self, "withLifecycle")
	Util.checkKeys(lifecycle, { "init", "start" }, `{self.name}:withLifecycle`)
	for phase, fn in lifecycle :: any do
		if type(fn) ~= "function" then
			error(`{self.name}:withLifecycle: {phase} must be a function`, 2)
		end
		(self._nova.lifecycle :: any)[phase] = fn
	end
	return self
end

--[[ The modules this one needs. Nova runs their init before this one's, and their start before
	this one's (Shard only ordered init). During init, Nova.get returns only these. ]]
function Module.withDependencies(self: any, names: { string }): Module
	open(self, "withDependencies")
	for _, name in nameList(self, names, "withDependencies") do
		if name == self.name then
			error(`{self.name} cannot depend on itself`, 2)
		end
		if not table.find(self._nova.dependencies, name) then
			table.insert(self._nova.dependencies, name)
		end
	end
	return self
end

--- Signals this module owns: `self:getSignal("PlayerDowned"):Fire(player)`.
function Module.withSignals(self: any, names: { string }): Module
	open(self, "withSignals")
	for _, name in nameList(self, names, "withSignals") do
		if not self._nova.signals[name] then
			self._nova.signals[name] = Signal.new()
		end
	end
	return self
end

function Module.getSignal(self: any, name: string): any
	local signal = self._nova.signals[name]
	if not signal then
		error(`{self.name} has no signal "{tostring(name)}".{Util.suggest(tostring(name), self._nova.signals)}`, 2)
	end
	return signal
end

--[[ Something to clean up when the module is destroyed (or fails to boot): a function, which is
	called with the module, or anything Trove takes (an Instance, a connection). Same as
	`self.trove:Add(thing)`. Shard stored these and never ran them, and called the functions with
	no arguments. ]]
function Module.withCleanup(self: any, thing: any): Module
	if type(thing) == "function" then
		self.trove:Add(function()
			thing(self)
		end)
	else
		self.trove:Add(thing)
	end
	return self
end

--[[ The flags this module reads, with a default for each. Flags.luau is the place for flags; a
	default here is used only when Flags.luau lacks the flag. ]]
function Module.withFlags(self: any, flags: { [string]: Flags.Definition }): Module
	open(self, "withFlags")
	if type(flags) ~= "table" then
		error(`{self.name}:withFlags expects \{ FlagName = default \}`, 2)
	end
	for name, value in flags do
		self._nova.flags[name] = value
	end
	return self
end

--- A flag's value, for `player` when given (the local player on a client). Unknown names error.
function Module.flag(self: any, name: string, player: Player?): any
	return Flags.get(name, player)
end

--[[ Constants for this module: `self:getConfig("MaxStack")`. A key that is not there errors
	unless a default is given. For values that should change without a code edit, use a flag. ]]
function Module.withConfig(self: any, config: { [string]: any }): Module
	if type(config) ~= "table" then
		error(`{self.name}:withConfig expects a table`, 2)
	end
	for key, value in config do
		self._nova.config[key] = value
	end
	return self
end

function Module.getConfig(self: any, key: string, default: any?): any
	local value = self._nova.config[key]
	if value ~= nil then
		return value
	end
	if default ~= nil then
		return default
	end
	error(`{self.name} has no config "{tostring(key)}".{Util.suggest(tostring(key), self._nova.config)}`, 2)
end

--- Cleans the trove and disconnects every signal. Nova does this to a module that fails to boot.
function Module.destroy(self: any)
	if self._nova.state == "destroyed" then
		return
	end
	self.trove:Clean()
	for _, signal in self._nova.signals do
		signal:Destroy()
	end
	if self._nova.state ~= "failed" and self._nova.state ~= "skipped" then
		self._nova.state = "destroyed"
	end
end

return Module
