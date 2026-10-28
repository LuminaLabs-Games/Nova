local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Nova = require(ReplicatedStorage.Packages.Nova)
local Events = require(ReplicatedStorage.Shared.Events)
local Packets = require(ReplicatedStorage.Shared.Packets)

local WorldController = Nova.new("WorldController")
	:withDependencies({ "CombatController" })
	:withLifecycle({
		init = function(self)
			self.latest = nil :: { tick: number, pose: CFrame }?
		end,
		start = function(self)
			Packets.Snapshot:listen(function(snapshot)
				self.latest = snapshot
			end)
			self.trove:Add(Events.Showcasing:observe(function(on)
				self.log:debug("Showcasing", on)
			end))
		end,
	})

return WorldController
