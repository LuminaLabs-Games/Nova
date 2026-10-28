--!strict
--[[
	Boot: requires the modules, checks them, and runs init then start, on one side (server or
	client).

	  * ONE ORDER FOR BOTH PHASES. Modules are sorted by withDependencies, ties broken by name, so
	    every boot runs the same order, and start follows it too. Shard sorted init only; start
	    walked a hash table, which is how PoliceService marked zero road sections in CarSteal.
	  * INIT MUST NOT YIELD. Each init runs as a coroutine; one that yields is failed and named.
	    WaitForChild, DataStore calls and anything else that waits belong in start.
	  * EACH START RUNS ON ITS OWN THREAD, in order, so a start that waits holds up nobody.
	  * ONE FAILURE COSTS ONE MODULE (CarSteal's BootGuard, built in). A module that fails to load,
	    or throws in init or start, is logged with a traceback and marked failed; modules that
	    declared it as a dependency are skipped; everything else boots.
	  * STALLS ARE NAMED. A require, init hook or start still running after `stallWarning` seconds
	    (10) is named in the log.
	  * MISTAKES STOP THE BOOT BEFORE ANY INIT RUNS: two modules with one name (the duplicate
	    ModuleScript trap), a dependency that does not exist, a dependency cycle (printed A > B > A).
	  * THE CLIENT NEVER WAITS FOREVER. The server sets `NovaServerReady` (and `NovaServerFailed`
	    with the names) on Workspace once every start has returned; a client waits up to
	    `waitForServer` seconds for it, then boots anyway and says why.

	Workspace attributes, for a join screen (written once, never cleared). Workspace and not
	ReplicatedFirst, because attributes the server sets on ReplicatedFirst never reach clients.
	  NovaServerReady, NovaServerFailed      replicated from the server
	  NovaClientReady, NovaClientFailed      set locally by the client boot
	  NovaBootSlowest, NovaBootSlowestSeconds
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Flags = require(script.Parent.Flags)
local Log = require(script.Parent.Log)
local Module = require(script.Parent.Module)
local Signal = require(script.Parent.Signal)
local Util = require(script.Parent.Util)

local IS_SERVER = RunService:IsServer()
local KIND = if IS_SERVER then "service" else "controller"
local SIDE = if IS_SERVER then "server" else "client"

export type Options = {
	modules: (Instance | { Instance })?,
	flags: (ModuleScript | { [string]: any })?,
	before: (() -> ())?,
	after: (() -> ())?,
	waitForServer: number?,
	stallWarning: number?,
}

export type Report = {
	side: string,
	state: string,
	seconds: number?,
	order: { string },
	failed: { { name: string, phase: string, error: string } },
	skipped: { { name: string, reason: string } },
	timings: { [string]: number },
	slowest: { name: string, seconds: number }?,
	server: { ready: boolean, failed: string?, waited: number }?,
}

local log = Log.new("Nova")

local Boot = {}

-- idle -> booting -> init -> start -> ready, or -> stopped when a mistake stops it
Boot.state = "idle"
Boot.changed = Signal.new()
Boot.modules = {} :: { [string]: any }
Boot.current = nil :: any

local duplicates: { { string } } = {}
-- Every module Nova.new made, in order, so a require that fails can fail what it registered.
local registered: { any } = {}
local order: { string } = {}
local failed: { { name: string, phase: string, error: string } } = {}
local skipped: { { name: string, reason: string } } = {}
local timings: { [string]: number } = {}
local loadFailed: { [string]: boolean } = {}
local totalSeconds: number? = nil
local serverStatus: { ready: boolean, failed: string?, waited: number }? = nil

local function setState(state: string)
	Boot.state = state
	Boot.changed:Fire(state)
end

--- Called by Nova.new: adds a module to this side's registry.
function Boot.register(name: string, source: string): any
	if type(name) ~= "string" or name == "" then
		error("Nova.new expects the module's name", 3)
	end
	if Boot.state ~= "idle" and Boot.state ~= "booting" then
		error(`Nova.new("{name}") ran after the boot read its modules, so it would never init or start. Put its script in the folder Nova.boot loads`, 3)
	end
	local module = Module.new(name, KIND, source)
	table.insert(registered, module)
	local existing = Boot.modules[name]
	if existing then
		table.insert(duplicates, { name, existing._nova.source, source })
	else
		Boot.modules[name] = module
	end
	return module
end

--[[ Warns once if `label` is still running after `seconds`. Returns the function that marks it done.
	`what` finishes the sentence: "...; the server's ready signal waits on it". ]]
local function watch(label: string, seconds: number, what: string): () -> ()
	local done = false
	task.delay(seconds, function()
		if not done then
			log:warn(`{label} has been running for {seconds}s; {what}`)
		end
	end)
	return function()
		done = true
	end
end

local function fail(name: string, phase: string, message: string, module: any?)
	table.insert(failed, { name = name, phase = phase, error = message })
	log:error(`{name} failed in {phase}; it is off for this session and everything else carries on.\n{message}`)
	if module then
		module._nova.state = "failed"
		pcall(module.destroy, module)
	end
end

local function skip(module: any, reason: string)
	local ranInit = module._nova.state == "initialized"
	module._nova.state = "skipped"
	table.insert(skipped, { name = module.name, reason = reason })
	log:warn(`{module.name} skipped: {reason}`)
	if ranInit then
		-- Its init ran (a dependency failed in start): undo what init connected.
		pcall(module.destroy, module)
	end
end

-- The first dependency that cannot be used, and why, or nil.
local function blockedBy(module: any): string?
	for _, dependency in module._nova.dependencies do
		if loadFailed[dependency] then
			return `needs {dependency}, which failed to load`
		end
		local other = Boot.modules[dependency]
		if other then
			local state = other._nova.state
			if state == "failed" or state == "skipped" then
				return `needs {dependency}, which {state}`
			end
		end
	end
	return nil
end

-- The ModuleScripts under `root`, not descending into a ModuleScript (its children are its own).
local function collect(root: Instance, into: { ModuleScript })
	if root:IsA("ModuleScript") then
		table.insert(into, root)
		return
	end
	local children = root:GetChildren()
	table.sort(children, function(a, b)
		return a.Name < b.Name
	end)
	for _, child in children do
		collect(child, into)
	end
end

local function requireAll(roots: any, stall: number)
	if roots == nil then
		return
	end
	if typeof(roots) == "Instance" then
		roots = { roots }
	end
	local scripts: { ModuleScript } = {}
	for _, root in roots do
		if typeof(root) ~= "Instance" then
			error("Nova.boot: modules must be an Instance (a folder) or a list of them", 3)
		end
		collect(root, scripts)
	end
	for _, moduleScript in scripts do
		local name = moduleScript.Name
		local done = watch(`require({moduleScript:GetFullName()})`, stall, "the boot waits on it. Nothing should yield while a module loads")
		local began = os.clock()
		local registeredBefore = #registered
		local ok, result = pcall(require, moduleScript)
		done()
		timings[name .. ".require"] = os.clock() - began
		if not ok then
			loadFailed[name] = true
			fail(name, "require", `{moduleScript:GetFullName()}: {tostring(result)} (the engine printed the real error above)`)
			-- A module the script registered before it threw (a builder that errored) is failed too,
			-- or it would boot as an empty shell.
			for i = registeredBefore + 1, #registered do
				local module = registered[i]
				loadFailed[module.name] = true
				module._nova.state = "failed"
				pcall(module.destroy, module)
			end
		elseif Module.is(result) and result.name ~= name then
			log:warn(`{moduleScript:GetFullName()} returns the {KIND} "{result.name}"; name the script after it so Nova.get finds what you expect`)
		end
	end
end

-- Every mistake that stops the boot, as lines. Locks the modules against late builder calls.
local function validate(): { string }
	local problems = {}
	for _, duplicate in duplicates do
		table.insert(problems, `Two {KIND}s are named {duplicate[1]}: {duplicate[2]} and {duplicate[3]}`)
	end
	local names = Util.keys(Boot.modules)
	for _, name in names do
		local module = Boot.modules[name]
		module._nova.locked = true
		for _, dependency in module._nova.dependencies do
			if not Boot.modules[dependency] and not loadFailed[dependency] then
				table.insert(problems, `{name} depends on {dependency}, which does not exist.{Util.suggest(dependency, Boot.modules)}`)
			end
		end
		local ok, warnings = pcall(Flags._declare, name, module._nova.flags)
		if not ok then
			table.insert(problems, tostring(warnings))
		else
			for _, warning in warnings do
				log:warn(warning)
			end
		end
	end

	-- Cycles: a depth-first walk; reaching a module still on the path is a cycle.
	local color: { [string]: number } = {}
	local path: { string } = {}
	local seen: { [string]: boolean } = {}
	local function visit(name: string)
		color[name] = 1
		table.insert(path, name)
		local dependencies = table.clone(Boot.modules[name]._nova.dependencies)
		table.sort(dependencies)
		for _, dependency in dependencies do
			if Boot.modules[dependency] then
				if color[dependency] == 1 then
					local cycle = {}
					for i = table.find(path, dependency) :: number, #path do
						table.insert(cycle, path[i])
					end
					local key = table.clone(cycle)
					table.sort(key)
					local id = table.concat(key, ",")
					if not seen[id] then
						seen[id] = true
						table.insert(cycle, dependency)
						table.insert(problems, `Dependency cycle: {table.concat(cycle, " > ")}`)
					end
				elseif not color[dependency] then
					visit(dependency)
				end
			end
		end
		table.remove(path)
		color[name] = 2
	end
	for _, name in names do
		if not color[name] then
			visit(name)
		end
	end
	return problems
end

-- Dependencies first, ties broken by name (Kahn's algorithm over a sorted ready list).
local function sortModules(): { string }
	local waiting: { [string]: number } = {}
	local dependents: { [string]: { string } } = {}
	for name, module in Boot.modules do
		waiting[name] = 0
		dependents[name] = dependents[name] or {}
		for _, dependency in module._nova.dependencies do
			if Boot.modules[dependency] then
				waiting[name] += 1
				dependents[dependency] = dependents[dependency] or {}
				table.insert(dependents[dependency], name)
			end
		end
	end
	local ready = {}
	for name, count in waiting do
		if count == 0 then
			table.insert(ready, name)
		end
	end
	table.sort(ready)
	local sorted = {}
	while #ready > 0 do
		local name = table.remove(ready, 1) :: string
		table.insert(sorted, name)
		for _, dependent in dependents[name] do
			waiting[dependent] -= 1
			if waiting[dependent] == 0 then
				table.insert(ready, dependent)
				table.sort(ready)
			end
		end
	end
	return sorted
end

local function runInit(module: any)
	local fn = module._nova.lifecycle.init or rawget(module, "init")
	module._nova.state = "initializing"
	if type(fn) == "function" then
		Boot.current = module
		local began = os.clock()
		local thread = coroutine.create(fn)
		local ok, err = coroutine.resume(thread, module)
		Boot.current = nil
		timings[module.name .. ".init"] = os.clock() - began
		if not ok then
			fail(module.name, "init", debug.traceback(thread, tostring(err)), module)
			return
		elseif coroutine.status(thread) ~= "dead" then
			pcall(task.cancel, thread)
			fail(module.name, "init", "init yielded. init must finish without waiting: move WaitForChild, DataStore calls and anything else that waits to start", module)
			return
		end
	end
	module._nova.state = "initialized"
end

local function runHook(label: string, fn: any, stall: number)
	if fn == nil then
		return
	end
	if type(fn) ~= "function" then
		error(`Nova.boot: {label} must be a function`, 3)
	end
	local done = watch(`Nova.boot's {label}`, stall, `the {SIDE} boot waits on it`)
	local began = os.clock()
	local ok, err = xpcall(fn, debug.traceback)
	done()
	timings[label] = os.clock() - began
	if not ok then
		fail("boot", label, tostring(err))
	end
end

local function slowest(): (string?, number)
	local name, seconds = nil, 0
	for key, took in timings do
		if took > seconds then
			name, seconds = key, took
		end
	end
	return name, seconds
end

local function failedNames(): string?
	if #failed == 0 then
		return nil
	end
	local names = {}
	for _, entry in failed do
		table.insert(names, `{entry.name}.{entry.phase}`)
	end
	return table.concat(names, ", ")
end

local function announce(failure: string?)
	if IS_SERVER then
		if failure then
			Workspace:SetAttribute("NovaServerFailed", failure)
		end
		Workspace:SetAttribute("NovaServerReady", true)
	else
		local name, seconds = slowest()
		if name then
			Workspace:SetAttribute("NovaBootSlowest", name)
			Workspace:SetAttribute("NovaBootSlowestSeconds", seconds)
		end
		local reasons = {}
		if serverStatus and not serverStatus.ready then
			table.insert(reasons, "the server never reported ready")
		elseif serverStatus and serverStatus.failed then
			table.insert(reasons, "server: " .. serverStatus.failed)
		end
		if failure then
			table.insert(reasons, failure)
		end
		if #reasons > 0 then
			Workspace:SetAttribute("NovaClientFailed", table.concat(reasons, "; "))
		end
		Workspace:SetAttribute("NovaClientReady", true)
	end
end

local function waitForServer(seconds: number)
	local began = os.clock()
	if Workspace:GetAttribute("NovaServerReady") ~= true then
		local signal = Workspace:GetAttributeChangedSignal("NovaServerReady")
		while Workspace:GetAttribute("NovaServerReady") ~= true do
			local remaining = seconds - (os.clock() - began)
			if remaining <= 0 or not Signal.waitFor(signal :: any, remaining) then
				break
			end
		end
	end
	local ready = Workspace:GetAttribute("NovaServerReady") == true
	local serverFailed = Workspace:GetAttribute("NovaServerFailed")
	serverStatus = { ready = ready, failed = serverFailed, waited = os.clock() - began }
	if not ready then
		log:warn(`The server did not report ready within {seconds}s; starting the client anyway`)
		return
	end
	if serverFailed then
		log:warn(`The server booted with failures: {serverFailed}`)
	end
	-- Per-player flag values (an A/B provider) settle before any controller reads them.
	local remaining = math.clamp(seconds - (os.clock() - began), 0, 10)
	if not Flags._waitForPlayer(remaining) then
		log:warn("This player's flags were not settled in time; controllers may see a value change after boot")
	end
end

function Boot.run(options: Options?): Report
	if Boot.state ~= "idle" then
		error("Nova.boot was already called on this side", 3)
	end
	if not RunService:IsRunning() then
		error("Nova.boot runs in a running game (a playtest or a live server), not in edit mode", 3)
	end
	local opts: any = options or {}
	Util.checkKeys(opts, { "modules", "flags", "before", "after", "waitForServer", "stallWarning" }, "Nova.boot")
	local stall = opts.stallWarning or 10
	local began = os.clock()
	setState("booting")

	if not IS_SERVER then
		waitForServer(opts.waitForServer or 60)
	end

	if opts.flags ~= nil then
		local definitions = opts.flags
		if typeof(definitions) == "Instance" then
			definitions = require(definitions :: ModuleScript)
		end
		Flags.define(definitions)
	end

	requireAll(opts.modules, stall)

	local problems = validate()
	if #problems > 0 then
		local message = `Nova.boot stopped before any init ran ({#problems} problem{if #problems == 1 then "" else "s"}):\n  ` .. table.concat(problems, "\n  ")
		setState("stopped")
		announce("boot stopped: " .. problems[1])
		error(message, 0)
	end

	Flags._start()
	if not IS_SERVER then
		for _, name in Flags._unknownToServer() do
			log:warn(`Flag {name} is declared only by a controller, so the server cannot flip it live. Move it to Flags.luau`)
		end
	end
	Flags.observe("NovaDebug", function(value)
		Log._setDebugNames(tostring(value))
	end)

	runHook("before", opts.before, stall)

	order = sortModules()
	setState("init")
	for _, name in order do
		local module = Boot.modules[name]
		if module._nova.state == "failed" then
			continue -- failed to load
		end
		local blocked = blockedBy(module)
		if blocked then
			skip(module, blocked)
		else
			runInit(module)
		end
	end

	setState("start")
	local pending = 0
	local launched = false
	local allStarted = Signal.new()
	for _, name in order do
		local module = Boot.modules[name]
		if module._nova.state ~= "initialized" then
			continue
		end
		local blocked = blockedBy(module)
		if blocked then
			skip(module, blocked)
			continue
		end
		local fn = module._nova.lifecycle.start or rawget(module, "start")
		if type(fn) ~= "function" then
			module._nova.state = "started"
			continue
		end
		module._nova.state = "starting"
		pending += 1
		local done = watch(`{name}.start`, stall, `the {SIDE}'s ready signal waits on it`)
		local startedAt = os.clock()
		task.spawn(function()
			local ok, err = xpcall(fn, debug.traceback, module)
			done()
			timings[name .. ".start"] = os.clock() - startedAt
			if ok then
				module._nova.state = "started"
			else
				fail(name, "start", tostring(err), module)
			end
			pending -= 1
			if launched and pending == 0 then
				allStarted:Fire()
			end
		end)
	end
	launched = true
	if pending > 0 then
		allStarted:Wait()
	end

	totalSeconds = os.clock() - began
	local failure = failedNames()
	announce(failure)
	setState("ready")
	if IS_SERVER then
		Flags._serverBooted()
	end

	local count = #order
	local summary = `{SIDE} ready in {string.format("%.2f", totalSeconds :: number)}s: {count} {KIND}{if count == 1 then "" else "s"}`
	if failure then
		summary ..= `, failed: {failure}`
	end
	if #skipped > 0 then
		local names = {}
		for _, entry in skipped do
			table.insert(names, entry.name)
		end
		summary ..= `, skipped: {table.concat(names, ", ")}`
	end
	local slowName, slowSeconds = slowest()
	if slowName then
		summary ..= `. Slowest: {slowName} {string.format("%.2f", slowSeconds)}s`
	end
	if failure or #skipped > 0 then
		log:warn(summary)
	else
		log:info(summary)
	end

	runHook("after", opts.after, stall)
	return Boot.report()
end

-- True when `module` depends on `name`, directly or through its dependencies: all of those have
-- finished init before `module`'s init runs.
local function dependsOn(module: any, name: string): boolean
	local seen = {}
	local function walk(current: any): boolean
		for _, dependency in current._nova.dependencies do
			if dependency == name then
				return true
			end
			local other = Boot.modules[dependency]
			if other and not seen[dependency] then
				seen[dependency] = true
				if walk(other) then
					return true
				end
			end
		end
		return false
	end
	return walk(module)
end

--[[ Nova.get. Never returns nil: an unknown name errors with the closest names, and during init
	only the calling module's declared dependencies are allowed. ]]
function Boot.get(name: string, level: number): any
	if type(name) ~= "string" then
		error(`Nova.get expects a name; got {typeof(name)}`, level)
	end
	local state = Boot.state
	if state == "idle" or state == "booting" then
		error(`Nova.get("{name}") ran before the boot reached init. Call it inside init or start, or use Nova.await outside a module`, level)
	end
	if state == "stopped" then
		error(`Nova.get("{name}"): the {SIDE} boot stopped (see the error above)`, level)
	end
	local module = Boot.modules[name]
	if not module then
		error(`No {KIND} named "{name}".{Util.suggest(name, Boot.modules)}`, level)
	end
	local current = Boot.current
	if state == "init" and current and current ~= module and not dependsOn(current, name) then
		error(`{current.name}.init asked for {name}, which it does not depend on. Add :withDependencies(\{ "{name}" \}) to {current.name}, or get it in start`, level)
	end
	local moduleState = module._nova.state
	if moduleState == "failed" or moduleState == "skipped" then
		error(`{name} {moduleState} during boot (see Nova.report()), so it cannot be used`, level)
	end
	return module
end

--[[ Nova.await: yields (on a signal) until Nova.get(name) can answer, then returns it. Errors on a
	timeout (30 seconds by default) rather than returning nil. `level` points errors at the caller. ]]
function Boot.await(name: string, timeout: number?, level: number): any
	local limit = timeout or 30
	local deadline = os.clock() + limit
	while Boot.state == "idle" or Boot.state == "booting" or Boot.state == "init" do
		local remaining = deadline - os.clock()
		if remaining <= 0 or not Signal.waitFor(Boot.changed, remaining) then
			error(`Nova.await("{name}") timed out after {limit}s; the {SIDE} boot is at "{Boot.state}"`, level)
		end
	end
	return Boot.get(name, level + 1)
end

function Boot.report(): Report
	local name, seconds = slowest()
	local failedCopy = {}
	for i, entry in failed do
		failedCopy[i] = table.clone(entry)
	end
	local skippedCopy = {}
	for i, entry in skipped do
		skippedCopy[i] = table.clone(entry)
	end
	return {
		side = SIDE,
		state = Boot.state,
		seconds = totalSeconds,
		order = table.clone(order),
		failed = failedCopy,
		skipped = skippedCopy,
		timings = table.clone(timings),
		slowest = if name then { name = name, seconds = seconds } else nil,
		server = if serverStatus then table.clone(serverStatus) else nil,
	}
end

return Boot
