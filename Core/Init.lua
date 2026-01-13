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
	-- Cooldown toggles (priority system)
	-- burst = Death Wish + Racials (Blood Fury, Berserking, Perception)
	-- reckless = Recklessness
	-- Both OFF = sustain mode
	BurstEnabled = true,
	RecklessEnabled = false,
	-- Auto-interrupt with Pummel
	PummelEnabled = true,
	-- AoE rotation toggle (true = auto based on enemy count, false = force single target)
	AoEEnabled = true,
	-- Rend spreading toggle (true = spread to multiple targets, false = main target only)
	RendSpread = true,
	-- Sync racials with Death Wish (wait up to 10s for DW before using racials)
	SyncCooldowns = true,
	-- Bloodrage CD Mode: soft-sync with burst while maintaining rage economy
	-- Philosophy: Rage economy is king. Only hold Bloodrage if DW coming soon AND rage > 40.
	-- When enabled: waits up to 15s for Death Wish if rage comfortable (>40)
	--               respects BurstEnabled toggle (off in sustain mode)
	--               emergency override: ALWAYS uses if rage < 30
	-- When disabled: uses Bloodrage on CD for rage generation (vanilla behavior)
	-- TurtleWoW (Nov 2024): Bloodrage can crit and proc Enrage (+15% dmg for 8s)
	-- Source: https://forum.turtle-wow.org/viewtopic.php?t=16775
	BloodrageBurstMode = true,
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

	-- GUARDRAILS: Last known spell readiness (for detecting when spells go on cooldown)
	-- These track if Overpower/Pummel were ready on the last check
	-- If they transition from ready -> not ready, we know they were used
	LastOverpowerReady = false,  -- Was Overpower off-cooldown last check?
	LastPummelReady = false,     -- Was Pummel off-cooldown last check?
}

---------------------------------------
-- Overpower Multi-Target Iteration
-- When a dodge happens, we don't know WHICH mob dodged
-- This system tries Overpower on each nameplate until one works
---------------------------------------
ATW.OverpowerIteration = {
	targets = {},      -- List of GUIDs to try
	index = 0,         -- Current index in the list
	lastBuild = 0,     -- When we last built the target list
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
