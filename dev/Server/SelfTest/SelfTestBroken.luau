-- Throws in init when NovaSelfTest is on: Nova must fail it, skip what depends on it, boot the rest.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Nova = require(ReplicatedStorage.Packages.Nova)

return Nova.new("SelfTestBroken"):withLifecycle({
	init = function(self)
		if self:flag("NovaSelfTest") then
			error("deliberate failure (NovaSelfTest)")
		end
	end,
})
