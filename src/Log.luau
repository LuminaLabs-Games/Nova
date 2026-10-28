--!strict
--[[
	Log: one logger per module, as `self.log`, plus `Nova.log` for code outside a module.

		self.log:info("Loaded", profile)       -- [CombatService] Loaded {table}
		self.log:debug("Ray", origin, hit)     -- only when debug is on for this module

	DEBUG IS SWITCHED BY NAME, LIVE, NOT BY A FLAG PER MODULE. Shard 1.0.8 projects declared a
	`debugMode` feature flag in nearly every service just to write
	`self.log:setDebugEnabled(self:isFeatureEnabled("debugMode"))`, so turning debug on meant a code
	edit. In Nova the built-in flag `NovaDebug` holds a comma-separated list of module names ("*" for
	all), and `debug` lines from those modules print. Flip it live like any other flag; per player it
	turns on one tester's client logs only.

	Extra values are passed to print as their own arguments, so tables stay expandable in Studio's
	Output. Outside Studio they are flattened into the line, since a server log shows only text.
]]

local RunService = game:GetService("RunService")

local IS_STUDIO = RunService:IsStudio()

local Log = {}
Log.__index = Log

Log.Level = {
	TRACE = 1,
	DEBUG = 2,
	INFO = 3,
	WARN = 4,
	ERROR = 5,
	FATAL = 6,
}

local NAMES = { "TRACE", "DEBUG", "INFO", "WARN", "ERROR", "FATAL" }

export type Level = number | "trace" | "debug" | "info" | "warn" | "error" | "fatal"

export type Logger = {
	name: string,
	trace: (self: Logger, message: string, ...any) -> (),
	debug: (self: Logger, message: string, ...any) -> (),
	info: (self: Logger, message: string, ...any) -> (),
	warn: (self: Logger, message: string, ...any) -> (),
	error: (self: Logger, message: string, ...any) -> (),
	fatal: (self: Logger, message: string, ...any) -> (),
	setLevel: (self: Logger, level: Level?) -> (),
}

local globalLevel = Log.Level.INFO
--- Module names whose debug lines print, from the `NovaDebug` flag. `true` means every module.
local debugNames: { [string]: boolean } | boolean = {}

local function toLevel(level: Level): number
	if type(level) == "number" then
		return level
	end
	local value = (Log.Level :: any)[string.upper(level)]
	if not value then
		error(`Unknown log level "{level}"; use trace, debug, info, warn, error or fatal`, 3)
	end
	return value
end

local function flatten(value: any): string
	if type(value) ~= "table" then
		return tostring(value)
	end
	local parts = {}
	for key, item in value do
		table.insert(parts, `{tostring(key)}={tostring(item)}`)
		if #parts >= 16 then
			table.insert(parts, "...")
			break
		end
	end
	return "{ " .. table.concat(parts, ", ") .. " }"
end

function Log.new(name: string): Logger
	return (setmetatable({ name = name, _level = nil :: number? }, Log) :: any) :: Logger
end

--- Sets the level every logger uses unless it has its own. Default "info". (`Nova.setLogLevel`.)
function Log.setGlobalLevel(level: Level)
	globalLevel = toLevel(level)
end

--- Called by Nova with the `NovaDebug` flag's value: "CombatService, InventoryService" or "*".
function Log._setDebugNames(value: string)
	if string.match(value, "^%s*%*%s*$") then
		debugNames = true
		return
	end
	local names = {}
	for name in string.gmatch(value, "[^,%s]+") do
		names[name] = true
	end
	debugNames = names
end

local function enabled(self: any, level: number): boolean
	if level == Log.Level.DEBUG then
		if debugNames == true or (debugNames :: { [string]: boolean })[self.name] then
			return true
		end
	end
	return level >= (self._level or globalLevel)
end

local function emit(self: any, level: number, message: string, ...: any)
	if not enabled(self, level) then
		return
	end
	local line = `[{self.name}] {message}`
	if level ~= Log.Level.INFO then
		line = `[{self.name}] {NAMES[level]}: {message}`
	end
	local out = if level >= Log.Level.WARN then warn else print
	if select("#", ...) == 0 then
		out(line)
	elseif IS_STUDIO then
		out(line, ...)
	else
		local extras = {}
		for i = 1, select("#", ...) do
			extras[i] = flatten((select(i, ...)))
		end
		out(line .. " " .. table.concat(extras, " "))
	end
end

--- Sets this logger's own level, or clears it (nil) to follow the global one.
function Log.setLevel(self: any, level: Level?)
	self._level = if level == nil then nil else toLevel(level)
end

function Log.trace(self: any, message: string, ...: any)
	emit(self, Log.Level.TRACE, message, ...)
end

function Log.debug(self: any, message: string, ...: any)
	emit(self, Log.Level.DEBUG, message, ...)
end

function Log.info(self: any, message: string, ...: any)
	emit(self, Log.Level.INFO, message, ...)
end

function Log.warn(self: any, message: string, ...: any)
	emit(self, Log.Level.WARN, message, ...)
end

function Log.error(self: any, message: string, ...: any)
	emit(self, Log.Level.ERROR, message, ...)
end

function Log.fatal(self: any, message: string, ...: any)
	emit(self, Log.Level.FATAL, message, ...)
end

return Log
