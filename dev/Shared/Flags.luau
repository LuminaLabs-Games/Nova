--[[
	Every flag in the game, in one place. A flag is a value, or { default = ..., studio = ... } for a
	different value in Studio playtests. Flip one live from the server's ReplicatedStorage.NovaFlags
	in the Properties panel, with Nova.flags.set, or per player with Nova.flags.setFor.

	The built-in NovaDebug (a list of module names, or "*") turns on their self.log:debug lines.
]]

return {
	NewRecoil = false,
	StaminaV2 = true,
	-- "badge" | "notification"
	StreakDisplay = "notification",
	SkipIntro = { default = false, studio = true },
	-- Nova's own self-test fixtures (ServerScriptService.SelfTest, StarterPlayerScripts.SelfTest).
	-- Turn on with a NovaFlags object in ReplicatedStorage carrying NovaSelfTest = true.
	NovaSelfTest = false,
}
