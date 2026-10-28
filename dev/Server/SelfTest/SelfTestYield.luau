-- Yields in init when NovaSelfTest is on: Nova must fail it by name.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Nova = require(ReplicatedStorage.Packages.Nova)

return Nova.new("SelfTestYield"):withLifecycle({
	init = function(self)
		if self:flag("NovaSelfTest") then
			task.wait()
		end
	end,
})
