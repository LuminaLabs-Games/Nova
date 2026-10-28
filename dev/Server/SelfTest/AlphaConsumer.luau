local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Nova = require(ReplicatedStorage.Packages.Nova)
local Record = require(script.Parent.Record)

local AlphaConsumer = Nova.new("AlphaConsumer"):withDependencies({ "ZetaSource" })

-- Plain methods instead of withLifecycle, the other way Shard modules declare their phases.
function AlphaConsumer:init()
	table.insert(Record.order, "AlphaConsumer.init")
	Record.undeclaredGet = select(2, pcall(Nova.get, "CombatService"))
	Record.transitiveGet = select(2, pcall(function()
		return Nova.get("ZetaSource"):rootName()
	end))
end

function AlphaConsumer:start()
	table.insert(Record.order, "AlphaConsumer.start")
	Record.at.alphaStart = os.clock()
end

return AlphaConsumer
