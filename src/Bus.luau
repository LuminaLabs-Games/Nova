--!strict
--[[
	Bus: game-wide events and states, declared once in a shared module. Replaces Dispatcher.

		-- ReplicatedStorage/Shared/Events.luau
		local Nova = require(ReplicatedStorage.Packages.Nova)
		return Nova.bus.define({
			PageOpened = Nova.bus.event() :: Nova.Event<string>,
			PlayerDowned = Nova.bus.event() :: Nova.Event<Player>,
			Showcasing = Nova.bus.state(false),
		})

		Events.PageOpened:Connect(function(pageName) ... end)  -- returns a real connection
		Events.PageOpened:Fire("Inventory")
		Events.Showcasing:set(true)
		Events.Showcasing:observe(function(on) ... end)        -- runs now, then on every change

	Events are table keys, so a misspelt one is an editor error, and at run time reading a key that
	was never declared errors instead of publishing to nobody.

	What Dispatcher 1.0.2 got wrong, and Nova does not carry over:
	  * the function `Subscribe` returned for an unnamed listener cleared EVERY listener on the
	    event (live in CarSteal: an Upgrades prompt's teardown erased DiscoveryController's
	    ShowcaseEnded listener). Here a connection disconnects itself and nothing else;
	  * `Publish` ran listeners inline with no pcall, so one that threw stopped the rest and the
	    publisher. Here each listener gets its own thread (see Signal);
	  * `Publish` returned the listeners' results. Here there are none: to ask another module
	    something, call it (`Nova.get("X"):method()`);
	  * on/off conditions were pairs of events (ShowcaseStarted / ShowcaseEnded), so a listener that
	    connected late never learnt the current answer. A state remembers it.

	A bus is local to one side (server or client). For the network, see Net.
]]

local Signal = require(script.Parent.Signal)
local Util = require(script.Parent.Util)

export type Connection = Signal.Connection
export type Event<T...> = Signal.Signal<T...>
export type State<T> = {
	get: (self: State<T>) -> T,
	set: (self: State<T>, value: T) -> (),
	observe: (self: State<T>, fn: (value: T) -> ()) -> Connection,
}

local State = {}
State.__index = State

function State.get(self: any): any
	return self._value
end

function State.set(self: any, value: any)
	if self._value == value then
		return
	end
	self._value = value
	self._changed:Fire(value)
end

function State.observe(self: any, fn: (any) -> ()): Connection
	local connection = self._changed:Connect(fn)
	task.spawn(fn, self._value)
	return connection
end

local Bus = {}

--- An event: `Connect`, `Once`, `Wait`, `Fire`, like any signal.
function Bus.event(): Event<...any>
	local event = Signal.new()
	;(event :: any)._novaBus = "event"
	return event :: any
end

--- A state: a value that is on or off (or anything else) right now, with `get`, `set` and `observe`.
function Bus.state<T>(initial: T): State<T>
	return (setmetatable({ _value = initial, _changed = Signal.new(), _novaBus = "state" }, State) :: any) :: State<T>
end

--[[ Seals a table of events and states. Returns the same table, so its type (and every key's) is
	what you wrote; reading a key that is not there errors with the closest names. ]]
function Bus.define<T>(definitions: T): T
	if type(definitions) ~= "table" then
		error("Nova.bus.define expects a table of bus.event() and bus.state(value)", 2)
	end
	for name, value in definitions :: any do
		if type(name) ~= "string" or type(value) ~= "table" or not rawget(value, "_novaBus") then
			error(`Nova.bus.define: {tostring(name)} must be bus.event() or bus.state(value)`, 2)
		end
	end
	return setmetatable(definitions :: any, {
		__index = function(_, key)
			error(`No bus event or state named "{tostring(key)}".{Util.suggest(tostring(key), definitions :: any)}`, 2)
		end,
		__newindex = function(_, key)
			error(`The bus is sealed; declare "{tostring(key)}" in its define call`, 2)
		end,
	})
end

return Bus
