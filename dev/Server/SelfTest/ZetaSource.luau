-- Sorts after AlphaConsumer by name, but AlphaConsumer depends on it: both of its phases must run first.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Nova = require(ReplicatedStorage.Packages.Nova)
local Record = require(script.Parent.Record)

local ZetaSource = Nova.new("ZetaSource"):withDependencies({ "SelfTestRoot" }):withLifecycle({
	init = function()
		table.insert(Record.order, "ZetaSource.init")
	end,
	start = function()
		table.insert(Record.order, "ZetaSource.start")
	end,
})

function ZetaSource:rootName(): string
	return Nova.get("SelfTestRoot").name
end

return ZetaSource
