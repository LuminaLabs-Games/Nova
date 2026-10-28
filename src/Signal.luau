--!strict
--[[
	Signal: the one event type Nova uses everywhere (module signals, the bus, flags, the network
	listeners).

	EVERY LISTENER GETS A FRESH THREAD. Most signal libraries (GoodSignal, sleitnick/signal) recycle
	one "runner" thread between handlers to save an allocation. That is only safe while no handler
	ever yields mid-dispatch: ReplicaClient 1.0.0 shipped that pattern and a yielding handler later
	got resumed with no payload, which surfaced as "attempt to call a nil value" (fixed in
	replicaclient 1.0.1 by spawning per handler). A fresh `task.spawn` per listener costs little and
	means a listener that yields or throws affects nobody else.

	Listeners still run straight away and in the order they connected: `task.spawn` runs the new
	thread immediately, up to its first yield.
]]

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
	Destroy: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
	Destroy: (self: Signal<T...>) -> (),
}

local Connection = {}
Connection.__index = Connection

function Connection.Disconnect(self: any)
	if not self.Connected then
		return
	end
	self.Connected = false
	local listeners = self._signal._listeners
	local index = table.find(listeners, self)
	if index then
		table.remove(listeners, index)
	end
end

Connection.Destroy = Connection.Disconnect

local Signal = {}
Signal.__index = Signal

function Signal.new<T...>(): Signal<T...>
	return (setmetatable({ _listeners = {} }, Signal) :: any) :: Signal<T...>
end

function Signal.is(value: any): boolean
	return type(value) == "table" and getmetatable(value) == Signal
end

function Signal.Connect(self: any, fn: (...any) -> ()): Connection
	assert(type(fn) == "function", "Signal:Connect expects a function")
	local connection = setmetatable({ Connected = true, _signal = self, _fn = fn }, Connection)
	table.insert(self._listeners, connection)
	return (connection :: any) :: Connection
end

function Signal.Once(self: any, fn: (...any) -> ()): Connection
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		fn(...)
	end)
	return connection
end

function Signal.Wait(self: any): ...any
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal.Fire(self: any, ...: any)
	local listeners = self._listeners
	if #listeners == 0 then
		return
	end
	-- A snapshot, so a listener that connects or disconnects during the fire changes nothing here.
	for _, connection in table.clone(listeners) do
		if connection.Connected then
			task.spawn(connection._fn, ...)
		end
	end
end

function Signal.DisconnectAll(self: any)
	for _, connection in self._listeners do
		connection.Connected = false
	end
	table.clear(self._listeners)
end

Signal.Destroy = Signal.DisconnectAll

--[[
	Waits for `signal` to fire, up to `timeout` seconds. Returns true and the fired values, or false
	on timeout. Used by `Nova.await` and the client's wait for the server.
]]
function Signal.waitFor(signal: any, timeout: number): (boolean, ...any)
	local thread = coroutine.running()
	local done = false
	local connection = signal:Once(function(...)
		if not done then
			done = true
			task.spawn(thread, true, ...)
		end
	end)
	local timer = task.delay(timeout, function()
		if not done then
			done = true
			connection:Disconnect()
			task.spawn(thread, false)
		end
	end)
	local results = table.pack(coroutine.yield())
	if results[1] then
		-- Fired in time: the timer is still waiting. (On a timeout the timer thread is the one that
		-- resumed this thread, and cancelling it from here would throw.)
		task.cancel(timer)
	end
	return table.unpack(results, 1, results.n)
end

return Signal
