--!strict
--[[
	Nova: Shard v2.

	It keeps the Shard features games actually use (the builder, Shard.get, per-module logs,
	dependencies, cleanup, signals, config, feature flags), cuts the rest, and adds a typed buffer
	network layer, an event bus with real connections, live feature flags, and a boot that one broken
	module cannot take down.

		-- ServerScriptService/Boot.server.luau
		Nova.boot({ modules = script.Parent.Services, flags = Shared.Flags,
			before = function() Data:initialize() end })

		-- StarterPlayerScripts/Boot.client.luau
		Nova.boot({ modules = script.Parent.Controllers, flags = Shared.Flags, waitForServer = 60,
			after = function() ReplicaClient.RequestData() end })

	README.md has the whole API and the Shard-to-Nova table.
]]

local Boot = require(script.Boot)
local Bus = require(script.Bus)
local Flags = require(script.Flags)
local Log = require(script.Log)
local Module = require(script.Module)
local Net = require(script.Net)
local Signal = require(script.Signal)

export type Module = Module.Module
export type Logger = Log.Logger
export type Signal<T...> = Signal.Signal<T...>
export type Connection = Signal.Connection
export type Event<T...> = Bus.Event<T...>
export type State<T> = Bus.State<T>
export type Codec<T> = Net.Codec<T>
export type Packet<T> = Net.Packet<T>
export type Request<T, R> = Net.Request<T, R>
export type BootOptions = Boot.Options
export type Report = Boot.Report

local Nova = {}

Nova.version = "0.1.0"

--- Feature flags: get, observe, all; server: set, setFor, setProvider, refresh.
Nova.flags = Flags
--- The event bus: event, state, define.
Nova.bus = Bus
--- The network layer: types, packet, request, define; server: onAbuse, strikes; stats.
Nova.Net = Net
--- The signal Nova uses everywhere: a fresh thread per listener.
Nova.Signal = Signal
--- A logger for code outside a module.
Nova.log = Log.new("Game")

--- A logger with its own name, for code outside a module.
function Nova.logger(name: string): Logger
	return Log.new(name)
end

--- The level every logger uses: "trace", "debug", "info" (the default), "warn", "error", "fatal".
function Nova.setLogLevel(level: Log.Level)
	Log.setGlobalLevel(level)
end

--- A service on the server, a controller on the client.
function Nova.new(name: string): Module
	return Boot.register(name, debug.info(2, "s"))
end

--[[ The module named `name`. Never nil: an unknown name errors with the closest names, during init
	only declared dependencies are allowed, and a module that failed to boot errors. ]]
function Nova.get(name: string): any
	return Boot.get(name, 3)
end

--- For code outside a module: yields until `name` can be got, then returns it. Errors on timeout.
function Nova.await(name: string, timeout: number?): any
	return Boot.await(name, timeout, 3)
end

--[[ Boots this side: waits for the server (client), loads the flags, requires the modules, checks
	them, runs `before`, every init, every start, then `after`. Returns the report. ]]
function Nova.boot(options: Boot.Options?): Boot.Report
	return Boot.run(options)
end

--- What failed, what was skipped, how long each phase took, and the slowest.
function Nova.report(): Boot.Report
	return Boot.report()
end

return Nova
