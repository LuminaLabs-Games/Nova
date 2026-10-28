-- What a strike means is the game's call. Here: a debug line, and a kick past a sustained count.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Nova = require(ReplicatedStorage.Packages.Nova)

local KICK_AT = 500

local AbuseService = Nova.new("AbuseService"):withLifecycle({
	init = function(self)
		Nova.Net.onAbuse(function(player, packetName, reason)
			self.log:debug(`{player.Name}: {packetName or "batch"}: {reason}`)
			if not RunService:IsStudio() and Nova.Net.strikes(player) >= KICK_AT then
				player:Kick("Too many bad requests")
			end
		end)
	end,
})

return AbuseService
