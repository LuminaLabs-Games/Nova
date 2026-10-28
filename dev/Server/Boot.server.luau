-- The server's one entry point: everything else is a service under Services.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Nova = require(ReplicatedStorage.Packages.Nova)
local NovaData = require(ReplicatedStorage.Packages.NovaData)

local SelfTest = script.Parent.SelfTest

Nova.boot({
	modules = { script.Parent.Services, SelfTest },
	flags = ReplicatedStorage.Shared.Flags,
	before = function()
		-- The data layer starts before any service's init. It does not yield: saves load on their
		-- own threads, and services wait for one with NovaData.awaitProfile(player).
		NovaData.start({
			template = require(script.Parent.DataTemplate),
			migrations = {
				-- 1: saves from before Bandages existed (Reconcile adds the key; this is the shape)
				function(data)
					data.Bandages = data.Bandages or 0
				end,
			},
		})
	end,
	after = function()
		if Nova.flags.get("NovaSelfTest") then
			require(SelfTest.Run)()
		end
	end,
})
