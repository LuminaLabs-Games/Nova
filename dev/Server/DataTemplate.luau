-- Every new save starts as this. NovaData.start({ template = ... }) in Boot.server.

return {
	Cash = 0,
	Bandages = 0,
	Stats = { Level = 1, Experience = 0 },
	-- Pets.Dog.Level makes "Level" ambiguous on purpose (the self-test checks that it errors).
	Pets = { Dog = { Level = 1 } },
	Inventory = {},
}
