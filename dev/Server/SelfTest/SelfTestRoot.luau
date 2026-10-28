-- ZetaSource depends on this, and AlphaConsumer on ZetaSource: AlphaConsumer's init reaches it
-- through ZetaSource, which must be allowed (a dependency's dependency has finished init too).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Nova = require(ReplicatedStorage.Packages.Nova)

return Nova.new("SelfTestRoot")
