-- Game-wide events and states, local to each side. A misspelt name is an error.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Nova = require(ReplicatedStorage.Packages.Nova)
local bus = Nova.bus

return bus.define({
	PageOpened = bus.event() :: Nova.Event<string>,
	PlayerDowned = bus.event() :: Nova.Event<Player>,
	Showcasing = bus.state(false),
})
