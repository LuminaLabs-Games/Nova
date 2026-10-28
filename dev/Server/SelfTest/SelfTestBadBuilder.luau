-- With NovaSelfTest on, this registers a module and then throws while loading (a builder given a
-- number). Nova must fail the module it registered, not boot it as an empty shell. Flags are not
-- live yet while modules load, so it reads the place override directly.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Nova = require(ReplicatedStorage.Packages.Nova)

local module = Nova.new("SelfTestBadBuilder")
local override = ReplicatedStorage:FindFirstChild("NovaFlags")
if override and override:GetAttribute("NovaSelfTest") then
	module:withLifecycle({ init = 5 :: any })
end
return module
