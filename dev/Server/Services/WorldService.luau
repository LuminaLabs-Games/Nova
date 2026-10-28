-- Streams a snapshot to every client ten times a second: unreliable, newest only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Nova = require(ReplicatedStorage.Packages.Nova)
local Packets = require(ReplicatedStorage.Shared.Packets)

local WorldService = Nova.new("WorldService"):withLifecycle({
	start = function(self)
		self.trove:Add(task.spawn(function()
			local tick = 0
			while true do
				task.wait(0.1)
				tick += 1
				Packets.Snapshot:sendAll({ tick = tick, pose = CFrame.new(0, 5, 0) * CFrame.Angles(0, tick / 10, 0) })
			end
		end))
	end,
})

return WorldService
