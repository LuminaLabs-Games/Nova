-- A start that waits 1.5 seconds must hold up nobody else's start.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Nova = require(ReplicatedStorage.Packages.Nova)
local Record = require(script.Parent.Record)

return Nova.new("SelfTestSlowStart"):withLifecycle({
	start = function(self)
		Record.at.slowStartBegan = os.clock()
		if self:flag("NovaSelfTest") then
			task.wait(1.5)
		end
		Record.at.slowStartEnded = os.clock()
	end,
})
