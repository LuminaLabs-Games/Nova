-- Depends on SelfTestBroken, so with NovaSelfTest on it must be skipped, not run.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Nova = require(ReplicatedStorage.Packages.Nova)
local Record = require(script.Parent.Record)

return Nova.new("SelfTestDependent"):withDependencies({ "SelfTestBroken" }):withLifecycle({
	init = function()
		table.insert(Record.order, "SelfTestDependent.init")
	end,
})
