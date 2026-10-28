-- The client's one entry point: everything else is a controller under Controllers. Controllers
-- live in StarterPlayerScripts from the start, so their path is the same in edit mode and in play.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Nova = require(ReplicatedStorage.Packages.Nova)
local NovaData = require(ReplicatedStorage.Packages.NovaData)

Nova.boot({
	modules = script.Parent.Controllers,
	flags = ReplicatedStorage.Shared.Flags,
	waitForServer = 60,
	after = function()
		-- Asks for this player's data once every controller's observers are connected.
		NovaData.request()
		if Nova.flags.get("NovaSelfTest") then
			require(script.Parent.SelfTest.Run)()
		end
	end,
})
