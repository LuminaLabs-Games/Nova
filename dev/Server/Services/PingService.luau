local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Nova = require(ReplicatedStorage.Packages.Nova)
local Packets = require(ReplicatedStorage.Shared.Packets)

local PingService = Nova.new("PingService"):withLifecycle({
	start = function()
		Packets.Ping:listen(function(player)
			Packets.Pong:sendTo(player)
		end)
	end,
})

return PingService
