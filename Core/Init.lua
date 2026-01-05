--[[
	Auto Turtle Warrior - Core/Init
	Addon namespace, configuration, and state
]]--

-- Global addon namespace
ATW = {}

---------------------------------------
-- Configuration Defaults
---------------------------------------
AutoTurtleWarrior_Config = AutoTurtleWarrior_Config or {}

ATW.DEFAULT = {
	Enabled = true,
	Debug = false,
	PrimaryStance = 0,  -- 0 = auto-detect (Berserker if available, else Battle)
	DanceRage = 10,
	MaxRage = 60,
	AoE = "auto",
	AoECount = 3,
	WWRange = 8,
	UseCooldowns = true,
}

---------------------------------------
-- State Variables
---------------------------------------
ATW.State = {
	LastStance = 0,
	Overpower = nil,
	Interrupt = nil,
	OldStance = nil,
	Dancing = nil,
	Attacking = nil,
}

---------------------------------------
-- Talent Cache
---------------------------------------
ATW.Talents = {
	TM = 0,        -- Tactical Mastery
	HSCost = 15,   -- Heroic Strike cost
	ExecCost = 15, -- Execute cost
	HasBT = nil,   -- Bloodthirst
	HasMS = nil,   -- Mortal Strike
	HasDW = nil,   -- Death Wish
	HasIBR = nil,  -- Improved Berserker Rage
}
