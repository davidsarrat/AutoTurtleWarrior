--[[
	Auto Turtle Warrior - Sim/Engine
	TACTICAL LAYER - Combat simulation engine (30 second horizon, configurable)
	Based on Zebouski/WarriorSim-TurtleWoW patterns

	ARCHITECTURE:
	=============
	Single-layer tactical simulation (100-200ms decisions).
	Cooldowns controlled via manual toggles (BurstEnabled/RecklessEnabled).
	CD sync for racials handled via shouldWaitForDWSync() in GetValidActions().

	MAIN ENTRY POINT:
	Engine.GetRecommendation() → abilityName, isOffGCD, pooling, time, targetGUID, targetStance

	CORE FUNCTIONS:
	- CaptureCurrentState()      - Snapshot game state (line ~1700)
	- GetValidActions()          - Generate valid actions (line ~2200)
	- GetActionDamage()          - Calculate damage value (line ~2550)
	- ApplyAction()              - Apply action effects (line ~2800)
	- SimulateDecisionHorizon()  - 9s forward simulation (line ~3030)
	- GetBestAction()            - Main decision function (line ~3095)

	FEATURES:
	- Time-step simulation (milliseconds precision)
	- Multi-target support with per-enemy state
	- Complete buff/aura system with durations
	- Rage generation model (hits, Bloodrage, talents)
	- Cooldown and GCD management
	- Off-GCD ability handling
	- Swing timer tracking with Flurry haste
	- Deep Wounds DoT simulation
	- Execute rage dump optimization
	- Cooldown toggle integration (BurstEnabled/RecklessEnabled)
	- Auto-interrupt state capture (PummelEnabled)

	See docs/Simulation.md for detailed documentation.
]]--

ATW.Engine = {}

---------------------------------------
-- Constants (from Zebouski/WarriorSim-TurtleWoW)
---------------------------------------
local Engine = ATW.Engine

-- Rage conversion formula at level 60
-- Formula: 0.0091107836 * level^2 + 3.225598133 * level + 4.2652911
-- Level 60: 0.0091107836 * 3600 + 3.225598133 * 60 + 4.2652911 = 230.6
Engine.RAGE_CONVERSION = 230.6

-- Rage from hit formula (Zebouski): (dmg / rageconversion) * 7.5 * ragemod
Engine.RAGE_HIT_FACTOR = 7.5
Engine.RAGE_DODGE_FACTOR = 0.75  -- Dodge generates 75% of normal rage
Engine.RAGE_OH_PENALTY = 0.5  -- OH generates 50% rage (not in Zebouski but vanilla)

-- Unbridled Wrath: TurtleWoW 15/30/45/60/75% chance per hit for 1 rage (2 if 2H)
-- This is loaded from talents, default is 0 (no talent)
Engine.UNBRIDLED_WRATH_CHANCE = 75  -- Fallback if not loaded from talents

-- GCD in milliseconds
Engine.GCD = 1500

-- Execute phase threshold
Engine.EXECUTE_THRESHOLD = 20  -- 20% HP

-- Spell values are now DYNAMIC based on player's spell ranks
-- Use ATW.GetXXX() functions from Player/Talents.lua
-- These fallback constants are only used if functions not available

-- Execute: ATW.GetExecuteBase(), ATW.GetExecuteCoeff()
Engine.EXECUTE_BASE = 600      -- Fallback: Rank 5
Engine.EXECUTE_RAGE_MULT = 15

-- Bloodthirst: ATW.GetBloodthirstDamage(ap)
Engine.BT_BASE = 200
Engine.BT_AP_COEFF = 0.35

-- Whirlwind: normalized speed (2.4 for 1H, 3.3 for 2H)
-- Now dynamic based on equipped weapon
function Engine.GetNormalizationSpeed()
	-- Check if Gear scan has determined weapon type
	if ATW.Gear and ATW.Gear.normSpeed then
		return ATW.Gear.normSpeed  -- 2.4 for 1H, 3.3 for 2H
	end
	return 2.4  -- Fallback to 1H
end

-- Legacy constant (kept for compatibility, but prefer GetNormalizationSpeed())
Engine.WW_NORM_SPEED = 2.4

-- Mortal Strike: ATW.GetMortalStrikeBonus()
Engine.MS_BONUS = 120          -- Fallback: Rank 4

-- Heroic Strike: ATW.GetHeroicStrikeBonus()
Engine.HS_BONUS = 157          -- Fallback: Rank 9

-- Cleave: ATW.GetCleaveBonus()
Engine.CLEAVE_BONUS = 50       -- Fallback: Rank 5

-- Overpower: ATW.GetOverpowerBonus()
Engine.OP_BONUS = 35           -- Fallback: Rank 4

-- Hamstring: ATW.GetHamstringDamage()
Engine.HAMSTRING_DMG = 45      -- Fallback: Rank 3

-- Slam: ATW.GetSlamBonus()
Engine.SLAM_BONUS = 87         -- Fallback: Rank 4

-- Battle Shout: ATW.GetBattleShoutAP()
Engine.BATTLE_SHOUT_AP = 232   -- Fallback: Rank 7

-- Rend (TurtleWoW): base damage + 5% AP per tick
-- Base tick damage and ticks are dynamically calculated from spell rank
-- Use ATW.GetRendTickDamage(), ATW.GetRendTicks(), ATW.GetRendDuration()
Engine.REND_AP_COEFF = 0.05  -- Per tick (constant across ranks)

-- Deep Wounds: 60% weapon damage over 6s (4 ticks every 1.5s in TurtleWoW)
Engine.DW_PERCENT = 0.60
Engine.DW_TICKS = 4
Engine.DW_TICK_INTERVAL = 1500

-- Buff durations (milliseconds)
Engine.BUFF_DURATIONS = {
	Enrage = 8000,          -- 8s in TurtleWoW (Bloodrage can proc it, Nov 2024 change)
	DeathWish = 30000,      -- 30s
	Recklessness = 15000,   -- 15s
	Flurry = 0,             -- 3 charges, not time-based
	BattleShout = 120000,   -- 2 min
	BerserkerRage = 10000,  -- 10s
	Bloodrage = 10000,      -- 10s (generates rage over time)
	SweepingStrikes = 0,    -- 5 charges
	DeepWounds = 6000,      -- 6s DoT
	Rend = 21000,           -- Default 21s DoT (actual duration from ATW.GetRendDuration())
	-- Racial abilities (TurtleWoW values)
	BloodFury = 15000,      -- 15s (Orc)
	Berserking = 10000,     -- 10s (Troll)
	Perception = 20000,     -- 20s (Human)
}

-- Buff effects (damage multipliers, etc)
Engine.BUFF_EFFECTS = {
	Enrage = { dmgmod = 1.15 },           -- +15% damage (TurtleWoW)
	DeathWish = { dmgmod = 1.20 },        -- +20% damage
	Recklessness = { critbonus = 100 },   -- +100% crit
	Flurry = { haste = 1.30 },            -- +30% attack speed
	BattleShout = { ap = 232 },           -- +232 AP (Rank 7)
	-- Racial effects (TurtleWoW values)
	BloodFury = { ap = 120 },             -- +AP = level*2 (120 at 60), off GCD
	Berserking = { haste = 1.10 },        -- 10-15% haste (use 10% base)
	Perception = { critbonus = 2 },       -- +2% crit (TurtleWoW)
}

---------------------------------------
-- Movement and Range Constants
-- From TrinityCore research: Charge uses min(runSpeed*3, max(28, runSpeed*4))
-- Base run speed = 7 y/s, so minimum Charge speed = 28 y/s
---------------------------------------
Engine.CHARGE_SPEED = 28         -- Yards per second (minimum Charge travel speed)
Engine.MELEE_RANGE = 5           -- Melee range in yards
Engine.CHARGE_MIN_RANGE = 8      -- Minimum Charge range
Engine.CHARGE_MAX_RANGE = 25     -- Maximum Charge range

---------------------------------------
-- Stance Switching Mechanics
-- Tactical Mastery: 5/10/15/20/25 rage retained
---------------------------------------
Engine.STANCE_GCD = 1500  -- 1.5s GCD on stance switch

-- Perform stance switch in simulation (loses rage based on Tactical Mastery)
function Engine.SwitchStance(state, newStance)
	if state.stance == newStance then
		return false  -- Already in stance
	end

	-- Check stance GCD
	if state.stanceGcdEnd and state.stanceGcdEnd > state.time then
		return false
	end

	-- Calculate rage retention from Tactical Mastery
	local tacticalMastery = 0
	if ATW.Talents and ATW.Talents.TM then
		tacticalMastery = ATW.Talents.TM  -- 0/5/10/15/20/25
	end

	-- Lose rage above TM cap
	if state.rage > tacticalMastery then
		state.rage = tacticalMastery
	end

	-- Switch stance
	local oldStance = state.stance
	state.stance = newStance
	state.stanceGcdEnd = state.time + Engine.STANCE_GCD

	-- Record in sequence
	table.insert(state.sequence, {
		time = state.time,
		ability = "StanceSwitch",
		damage = 0,
		rage = state.rage,
		fromStance = oldStance,
		toStance = newStance,
	})

	return true
end

-- Check if stance switch is needed for ability
function Engine.NeedsStanceSwitch(state, abilityName)
	local ability = ATW.Abilities and ATW.Abilities[abilityName]
	if not ability or not ability.stance then
		return false, nil
	end

	-- Check if current stance is valid
	for _, validStance in ipairs(ability.stance) do
		if validStance == 0 or validStance == state.stance then
			return false, nil
		end
	end

	-- Need to switch - return preferred stance
	return true, ability.stance[1]
end

-- Calculate effective rage cost including potential stance switch
function Engine.GetEffectiveRageCost(state, abilityName)
	local ability = ATW.Abilities and ATW.Abilities[abilityName]
	if not ability then return 999 end

	local cost = ability.rage or 0
	if ATW.GetModifiedRageCost then
		cost = ATW.GetModifiedRageCost(abilityName, cost)
	end

	-- If we need to switch stance, factor in rage loss
	local needsSwitch, targetStance = Engine.NeedsStanceSwitch(state, abilityName)
	if needsSwitch then
		local tacticalMastery = (ATW.Talents and ATW.Talents.TM) or 0
		local rageAfterSwitch = math.min(state.rage, tacticalMastery)
		-- Effective cost = ability cost + rage lost from switch
		local rageLost = state.rage - rageAfterSwitch
		cost = cost + rageLost
	end

	return cost
end

---------------------------------------
-- Simulation State
---------------------------------------
function Engine.CreateState()
	return {
		-- Time tracking (milliseconds)
		time = 0,
		maxTime = 30000,  -- Default 30s fight

		-- Player resources
		rage = 0,
		health = 100,  -- Percentage

		-- Stance (1=Battle, 2=Defensive, 3=Berserker)
		stance = 3,
		stanceGcdEnd = 0,  -- GCD on stance switching

		-- Tactical Mastery (cached from talents)
		tacticalMastery = 0,

		-- GCD tracking
		gcdEnd = 0,

		-- Swing timers (milliseconds until next swing)
		mhTimer = 0,
		ohTimer = 0,
		mhSpeed = 2600,  -- Base speed
		ohSpeed = 2600,

		-- HS/Cleave queue
		swingQueued = nil,  -- nil, "hs", "cleave"

		-- Combat state (for Charge - can only be used out of combat)
		inCombat = false,

		-- Melee range tracking (for travel time simulation)
		-- Charge speed: 28 yards/second minimum (from TrinityCore research)
		inMeleeRange = true,   -- Are we currently in melee range (<=5 yards)?
		timeToMelee = 0,       -- Milliseconds until we reach melee range (after Charge)
		targetDistance = nil,  -- Current distance to target in yards

		-- Cooldowns (time when available, 0 = ready)
		cooldowns = {
			Bloodthirst = 0,
			Whirlwind = 0,
			Execute = 0,
			Overpower = 0,
			MortalStrike = 0,
			DeathWish = 0,
			Recklessness = 0,
			Bloodrage = 0,
			BerserkerRage = 0,
			SweepingStrikes = 0,
			Pummel = 0,
			Slam = 0,
			Charge = 0,
			-- Racial cooldowns
			BloodFury = 0,
			Berserking = 0,
			Perception = 0,
		},

		-- Active buffs: {endTime, stacks, effect}
		buffs = {},

		-- Active DoTs on targets: {[targetId] = {endTime, tickTime, tickDamage}}
		dots = {},

		-- Flurry charges
		flurryCharges = 0,

		-- Sweeping Strikes charges
		sweepingCharges = 0,

		-- Overpower available (dodge proc)
		overpowerReady = false,
		overpowerEnd = 0,

		-- Targets: {[id] = {hp, maxHp, ttd, bleedImmune, inExecute}}
		targets = {},

		-- Statistics
		totalDamage = 0,
		abilityDamage = 0,
		autoDamage = 0,
		dotDamage = 0,

		-- Sequence of abilities used
		sequence = {},
	}
end

---------------------------------------
-- Initialize targets from current combat
-- Properly checks bleed immunity for each target
---------------------------------------
function Engine.InitTargets(state)
	-- Get enemies in range
	local enemies = {}
	if ATW.GetEnemiesWithTTD then
		enemies = ATW.GetEnemiesWithTTD(8)
	end

	-- If no enemies detected, create a single target from current target
	if table.getn(enemies) == 0 then
		local ttd = ATW.GetTargetTTD and ATW.GetTargetTTD() or 30
		local hp = ATW.GetHealthPercent and ATW.GetHealthPercent("target") or 100

		-- Check bleed immunity for main target
		local isBleedImmune = false
		if ATW.IsBleedImmune then
			isBleedImmune = ATW.IsBleedImmune("target")
		end

		state.targets["target"] = {
			hp = hp,
			maxHp = 100,
			ttd = ttd * 1000,  -- Convert to ms
			bleedImmune = isBleedImmune,
			inExecute = hp < Engine.EXECUTE_THRESHOLD,
			guid = nil,  -- No GUID for "target" unit
		}
	else
		for i, enemy in ipairs(enemies) do
			-- Check bleed immunity using GUID if available
			local isBleedImmune = false
			if enemy.guid and ATW.IsBleedImmuneGUID then
				isBleedImmune = ATW.IsBleedImmuneGUID(enemy.guid)
			elseif enemy.bleedImmune ~= nil then
				isBleedImmune = enemy.bleedImmune
			end

			state.targets[enemy.guid or ("enemy" .. i)] = {
				hp = 100,  -- Assume full HP, will decay based on TTD
				maxHp = 100,
				ttd = enemy.ttd * 1000,
				bleedImmune = isBleedImmune,
				inExecute = false,
				guid = enemy.guid,  -- Store GUID for GUID-based casting
			}
		end
	end

	-- Calculate HP decay rate per target
	for id, target in pairs(state.targets) do
		-- HP% lost per millisecond = 100 / ttd
		target.hpDecayRate = 100 / target.ttd
	end

	-- Count rendable targets (not bleed immune, TTD > 6s for 2+ ticks)
	-- TurtleWoW Rend DPR is excellent even with only 2 ticks
	state.rendableTargets = 0
	local minRendTTD = 6000  -- 6 seconds = 2 ticks minimum
	for id, target in pairs(state.targets) do
		if not target.bleedImmune and target.ttd >= minRendTTD then
			state.rendableTargets = state.rendableTargets + 1
		end
	end
end

---------------------------------------
-- Initialize player stats
---------------------------------------
function Engine.InitPlayer(state)
	ATW.UpdateStats()

	-- Scan gear for set bonuses, trinkets, enchants
	if ATW.ScanGear then
		ATW.ScanGear()
	end

	local stats = ATW.Stats or {}

	-- Base stats
	state.ap = stats.AP or 1000
	state.crit = stats.Crit or 20
	state.mhSpeed = (stats.MainHandSpeed or 2.6) * 1000
	state.ohSpeed = (stats.OffHandSpeed or 2.6) * 1000
	state.hasOH = stats.HasOffHand or false

	-- Add gear stat bonuses (trinkets, enchant procs)
	if ATW.GetGearStatBonuses then
		local gearBonuses = ATW.GetGearStatBonuses()
		-- STR -> AP (2 AP per STR for warriors)
		if gearBonuses.str and gearBonuses.str > 0 then
			state.ap = state.ap + (gearBonuses.str * 2)
		end
		if gearBonuses.ap and gearBonuses.ap > 0 then
			state.ap = state.ap + gearBonuses.ap
		end
		if gearBonuses.crit and gearBonuses.crit > 0 then
			state.crit = state.crit + gearBonuses.crit
		end
	end

	-- Conditional bonuses based on current target creature type
	-- (Mark of the Champion vs Undead/Demons, Seal of the Dawn vs Undead)
	if ATW.GetConditionalGearBonuses then
		local condBonuses = ATW.GetConditionalGearBonuses("target")
		if condBonuses.str and condBonuses.str > 0 then
			state.ap = state.ap + (condBonuses.str * 2)
		end
		if condBonuses.ap and condBonuses.ap > 0 then
			state.ap = state.ap + condBonuses.ap
		end
		if condBonuses.crit and condBonuses.crit > 0 then
			state.crit = state.crit + condBonuses.crit
		end
	end

	-- Store set bonus effects for later use
	if ATW.GetSetBonusEffects then
		state.setEffects = ATW.GetSetBonusEffects()
	else
		state.setEffects = {}
	end

	-- Store equipped trinkets for proc simulation
	if ATW.Gear and ATW.Gear.trinkets then
		state.trinkets = ATW.Gear.trinkets
	else
		state.trinkets = {}
	end

	-- Estimate weapon damage
	local estimatedDPS = 50 + (state.ap / 14)
	state.mhDmgMin = estimatedDPS * (state.mhSpeed / 1000) * 0.85
	state.mhDmgMax = estimatedDPS * (state.mhSpeed / 1000) * 1.15
	state.ohDmgMin = state.mhDmgMin * 0.5
	state.ohDmgMax = state.mhDmgMax * 0.5

	-- Current rage
	state.rage = UnitMana("player") or 0

	-- Current stance
	state.stance = ATW.Stance and ATW.Stance() or 3
	state.stanceGcdEnd = 0

	-- Tactical Mastery talent (rage retained on stance switch)
	-- TM = 0/5/10/15/20/25 based on talent points
	state.tacticalMastery = 0
	if ATW.Talents and ATW.Talents.TM then
		state.tacticalMastery = ATW.Talents.TM
	end

	-- Get current cooldown states
	for name, _ in pairs(state.cooldowns) do
		local ability = ATW.Abilities and ATW.Abilities[name]
		if ability then
			local spellID = ATW.SpellID and ATW.SpellID(ability.name)
			if spellID then
				local start, duration = GetSpellCooldown(spellID, BOOKTYPE_SPELL)
				if start and start > 0 and duration then
					local remaining = (start + duration) - GetTime()
					if remaining > 0 then
						state.cooldowns[name] = remaining * 1000
					end
				end
			end
		end
	end

	-- Check for current buffs
	if ATW.Buff("player", "Spell_Shadow_UnholyFrenzy") then
		state.buffs.Enrage = {
			endTime = state.time + Engine.BUFF_DURATIONS.Enrage,
			stacks = 1,
		}
	end
	if ATW.Buff("player", "Spell_Shadow_DeathPact") then
		state.buffs.DeathWish = {
			endTime = state.time + Engine.BUFF_DURATIONS.DeathWish,
			stacks = 1,
		}
	end
	if ATW.Buff("player", "Ability_Warrior_BattleShout") then
		state.buffs.BattleShout = {
			endTime = state.time + Engine.BUFF_DURATIONS.BattleShout,
			stacks = 1,
		}
	end

	-- Check for Crusader proc (from Gear.lua)
	-- Note: AP bonus is handled in GetEffectiveAP(), not added to base state.ap
	if ATW.Gear and ATW.Gear.enchants and ATW.Gear.enchants.crusader then
		if ATW.Gear.enchants.crusader.active then
			state.buffs.Crusader = {
				endTime = state.time + 15000,  -- 15s duration
				stacks = 1,
			}
		end
	end

	-- Get swing timer if available
	if ATW.GetMHSwingRemaining then
		state.mhTimer = (ATW.GetMHSwingRemaining() or 0) * 1000
	end
	if ATW.GetOHSwingRemaining and state.hasOH then
		state.ohTimer = (ATW.GetOHSwingRemaining() or 0) * 1000
	end

	-- Initialize Overpower state from real game state
	if ATW.State and ATW.State.Overpower then
		local windowRemaining = 4 - (GetTime() - ATW.State.Overpower)
		if windowRemaining > 0 then
			state.overpowerReady = true
			state.overpowerEnd = state.time + (windowRemaining * 1000)
		end
	end
end

---------------------------------------
-- Calculate damage modifier from active buffs
---------------------------------------
function Engine.GetDamageMod(state)
	local mod = 1.0

	for buffName, buff in pairs(state.buffs) do
		if buff.endTime > state.time or (buff.stacks and buff.stacks > 0) then
			local effect = Engine.BUFF_EFFECTS[buffName]
			if effect and effect.dmgmod then
				mod = mod * effect.dmgmod
			end
		end
	end

	-- Master of Arms (Mace): ignore 2/4/6/8/10 armor per player level
	-- Formula: ArmorReduction = Armor / (Armor + 400 + 85*Level)
	-- Against level 63 bosses (~3730 armor):
	--   Without pen: 3730 / 8485 = 43.9% reduction
	--   With 20% pen (746 armor ignored): 2984 / 7739 = 38.6% reduction
	--   Damage increase: (1 - 0.386) / (1 - 0.439) = 1.094 = +9.4% damage
	-- Approximation: 20% armor pen ≈ 9.4% damage increase vs raid bosses
	-- Per point: ~0.47% damage increase per 1% armor pen
	if ATW.Gear and ATW.Gear.weaponType == "Mace" and ATW.Talents and ATW.Talents.MasterOfArms and ATW.Talents.MasterOfArms > 0 then
		local playerLevel = UnitLevel and UnitLevel("player") or 60
		local ignoredArmor = ATW.Talents.MasterOfArms * 2 * playerLevel

		-- Calculate damage increase based on boss armor
		-- Simplified formula for level 63 bosses (3730 armor baseline)
		local bossArmor = 3730
		local armorConstant = 400 + 85 * 63  -- 5755

		-- Reduction without armor pen
		local baseReduction = bossArmor / (bossArmor + armorConstant)

		-- Reduction with flat armor ignored
		local effectiveArmor = math.max(0, bossArmor - ignoredArmor)
		local penReduction = effectiveArmor / (effectiveArmor + armorConstant)

		-- Damage increase = (1 - newReduction) / (1 - oldReduction)
		local damageMultiplier = (1 - penReduction) / (1 - baseReduction)
		mod = mod * damageMultiplier
	end

	-- Two-Handed Weapon Specialization: TurtleWoW 3 points, +2/4/6% damage
	if ATW.Gear and ATW.Gear.is2H and ATW.Talents and ATW.Talents.TwoHandSpec and ATW.Talents.TwoHandSpec > 0 then
		local bonus = ATW.Talents.TwoHandSpec * 2
		mod = mod * (1 + bonus / 100)
	end

	return mod
end

---------------------------------------
-- Calculate crit chance with buffs and talents
---------------------------------------
function Engine.GetCritChance(state, isAbility)
	local crit = state.crit or 20

	-- Berserker Stance: +3% crit (CRITICAL for stance decision value)
	if state.stance == 3 then
		crit = crit + 3
	end

	-- Cruelty talent: +1/2/3/4/5% crit (if not already in base stats)
	-- Note: This may already be included in state.crit from Stats module
	-- Uncomment if not included:
	-- if ATW.Talents and ATW.Talents.Cruelty then
	-- 	crit = crit + ATW.Talents.Cruelty
	-- end

	-- Master of Arms (Axe): +1/2/3/4/5% crit (TurtleWoW 1.17.2)
	-- Source: https://turtle-wow.fandom.com/wiki/Patch_1.17.2
	if ATW.Gear and ATW.Gear.weaponType == "Axe" and ATW.Talents and ATW.Talents.MasterOfArms and ATW.Talents.MasterOfArms > 0 then
		crit = crit + ATW.Talents.MasterOfArms  -- 0-5% depending on points
	end

	-- Recklessness (+100% crit)
	if state.buffs.Recklessness and state.buffs.Recklessness.endTime > state.time then
		crit = crit + 100
	end

	-- Perception (+2% crit - TurtleWoW Human racial)
	if state.buffs.Perception and state.buffs.Perception.endTime > state.time then
		crit = crit + 2
	end

	-- Overpower has +25/50% crit from Improved Overpower talent
	if isAbility == "Overpower" and ATW.Talents and ATW.Talents.ImpOP then
		crit = crit + ATW.Talents.ImpOP  -- 0/25/50%
	end

	return math.min(crit, 100)
end

---------------------------------------
-- Calculate effective AP including active buffs
-- This accounts for Battle Shout, Crusader procs, etc.
---------------------------------------
function Engine.GetEffectiveAP(state)
	local ap = state.ap or 1000

	-- Battle Shout buff
	if state.buffs.BattleShout and state.buffs.BattleShout.endTime > state.time then
		ap = ap + Engine.BUFF_EFFECTS.BattleShout.ap
	end

	-- Crusader enchant proc (+100 STR = +200 AP)
	if state.buffs.Crusader and state.buffs.Crusader.endTime > state.time then
		ap = ap + 200
	end

	-- Blood Fury (Orc racial): +AP = level*2
	if state.buffs.BloodFury and state.buffs.BloodFury.endTime > state.time then
		local bfAP = ATW.GetBloodFuryAP and ATW.GetBloodFuryAP() or (UnitLevel("player") * 2)
		ap = ap + bfAP
	end

	return ap
end

---------------------------------------
-- Calculate haste modifier from Flurry and Berserking
-- Flurry talent: +10/15/20/25/30% attack speed for 3 swings after crit
-- Berserking (Troll racial): +10-15% haste for 10s
---------------------------------------
function Engine.GetHasteMod(state)
	local haste = 1.0

	-- Flurry haste (stacks multiplicatively)
	if state.flurryCharges > 0 then
		local flurryPoints = (ATW.Talents and ATW.Talents.Flurry) or 5
		local hastePercent = flurryPoints * 6  -- 6% per point: 6/12/18/24/30%
		if flurryPoints >= 5 then
			haste = haste * 1.30
		else
			haste = haste * (1 + (hastePercent / 100))
		end
	end

	-- Berserking haste (Troll racial, stacks multiplicatively)
	if state.buffs.Berserking and state.buffs.Berserking.endTime > state.time then
		-- TurtleWoW: 10-15% based on HP (we use average 12.5% in sim)
		local berserkHaste = 1.125
		if ATW.GetBerserkingHaste then
			berserkHaste = 1 + (ATW.GetBerserkingHaste() / 100)
		end
		haste = haste * berserkHaste
	end

	return haste
end

---------------------------------------
-- Roll for damage (weapon + AP)
---------------------------------------
function Engine.RollWeaponDamage(state, isOH, normalized, normSpeed)
	local minDmg, maxDmg
	if isOH then
		minDmg, maxDmg = state.ohDmgMin, state.ohDmgMax
	else
		minDmg, maxDmg = state.mhDmgMin, state.mhDmgMax
	end

	-- Random roll between min and max
	local baseDmg = minDmg + math.random() * (maxDmg - minDmg)

	-- Add AP bonus (using effective AP with buffs)
	local effectiveAP = Engine.GetEffectiveAP(state)
	local apBonus
	if normalized and normSpeed then
		apBonus = effectiveAP * (normSpeed / 14)
	else
		local speed = isOH and (state.ohSpeed / 1000) or (state.mhSpeed / 1000)
		apBonus = effectiveAP * (speed / 14)
	end

	return baseDmg + apBonus
end

---------------------------------------
-- Process a hit with crit chance (Zebouski formula)
-- Crit multiplier: 1 + 1 * (1 + abilitiescrit) * (1 + critdmgbonus * 2)
---------------------------------------
function Engine.ProcessHit(state, damage, critChance, isMH, isAbility)
	local roll = math.random() * 100
	local isCrit = roll < critChance
	local finalDamage = damage

	-- Apply crit multiplier (Zebouski formula)
	if isCrit then
		-- Base: 2x damage
		-- With Impale talent (+20% crit damage): 2.2x
		-- Formula: 1 + 1 * (1 + abilitiescrit) * (1 + critdmgbonus * 2)
		local abilitiesCrit = 0
		local critDmgBonus = 0

		if isAbility and ATW.Talents then
			-- Impale: +10/20% crit damage on abilities
			if ATW.Talents.Impale then
				abilitiesCrit = ATW.Talents.Impale * 0.10  -- 0.10 or 0.20
			end
		end

		local critMod = 1 + 1 * (1 + abilitiesCrit) * (1 + critDmgBonus * 2)
		finalDamage = damage * critMod

		-- Proc Flurry on crit (if talented) - 3 charges
		if ATW.Talents and ATW.Talents.Flurry then
			state.flurryCharges = 3
		end

		-- Proc Deep Wounds on crit (if talented)
		if ATW.Talents and ATW.Talents.DeepWounds and isMH then
			Engine.ApplyDeepWounds(state, damage)
		end

		-- Proc Enrage on crit (if talented - Wrecking Crew in Zebouski)
		if ATW.Talents and ATW.Talents.Enrage then
			state.buffs.Enrage = {
				endTime = state.time + Engine.BUFF_DURATIONS.Enrage,
				stacks = 1,
			}
		end
	end

	-- Apply Dual Wield Specialization to offhand hits (Fury talent)
	-- +5/10/15/20/25% offhand damage (5 talent points)
	local isOH = not isMH
	if isOH and ATW.Talents and ATW.Talents.DualWieldSpec and ATW.Talents.DualWieldSpec > 0 then
		local bonus = ATW.Talents.DualWieldSpec * 5  -- 5% per point
		finalDamage = finalDamage * (1 + bonus / 100)
	end

	-- Apply damage modifiers from buffs
	finalDamage = finalDamage * Engine.GetDamageMod(state)

	return finalDamage, isCrit
end

---------------------------------------
-- Apply Deep Wounds DoT
---------------------------------------
function Engine.ApplyDeepWounds(state, weaponDamage)
	-- Deep Wounds: 60% of weapon damage over 6 seconds (4 ticks)
	local totalDmg = weaponDamage * 0.60
	local tickDamage = totalDmg / Engine.DW_TICKS

	-- Apply to main target
	if not state.dots.deepwounds then
		state.dots.deepwounds = {}
	end

	state.dots.deepwounds["target"] = {
		endTime = state.time + Engine.BUFF_DURATIONS.DeepWounds,
		nextTick = state.time + Engine.DW_TICK_INTERVAL,
		tickDamage = tickDamage,
		tickInterval = Engine.DW_TICK_INTERVAL,
	}
end

---------------------------------------
-- Generate rage from damage dealt (Zebouski formula)
-- Formula: (dmg / rageconversion) * 7.5 * ragemod
-- Dodge: (weapon.avgdmg() / rageconversion) * 7.5 * 0.75
---------------------------------------
function Engine.GenerateRage(state, damage, isOH, isDodge, avgWeaponDmg)
	local rage = 0

	if isDodge then
		-- Dodge generates 75% rage based on average weapon damage
		local avgDmg = avgWeaponDmg or ((state.mhDmgMin + state.mhDmgMax) / 2)
		rage = (avgDmg / Engine.RAGE_CONVERSION) * Engine.RAGE_HIT_FACTOR * Engine.RAGE_DODGE_FACTOR
	else
		-- Normal hit
		rage = (damage / Engine.RAGE_CONVERSION) * Engine.RAGE_HIT_FACTOR
	end

	-- Stance rage modifier
	-- Berserker Stance: base rage gen (no modifier in Zebouski)
	-- Could add stance-specific modifiers here if TurtleWoW has them

	-- OH penalty (if applicable)
	if isOH then
		rage = rage * Engine.RAGE_OH_PENALTY
	end

	-- Unbridled Wrath talent: 8/16/24/32/40% chance for +1 rage per hit
	-- Uses talent-loaded percentage (0 if no talent points)
	local uwChance = 0
	if ATW.Talents and ATW.Talents.UnbridledWrath then
		uwChance = ATW.Talents.UnbridledWrath  -- 0/8/16/24/32/40%
	end

	if uwChance > 0 then
		local uwRoll = math.random() * 100
		if uwRoll < uwChance then
			-- TurtleWoW: 2H weapons get +2 rage, 1H weapons get +1
			local bonusRage = (ATW.Gear and ATW.Gear.is2H) and 2 or 1
			rage = rage + bonusRage
		end
	end

	state.rage = math.min(state.rage + rage, 100)
	return rage
end

---------------------------------------
-- Update target HP based on time passing
---------------------------------------
function Engine.UpdateTargetHP(state, deltaTime)
	for id, target in pairs(state.targets) do
		-- Decay HP based on estimated DPS
		target.hp = target.hp - (target.hpDecayRate * deltaTime)
		if target.hp < 0 then target.hp = 0 end

		-- Check execute phase
		if target.hp <= Engine.EXECUTE_THRESHOLD and not target.inExecute then
			target.inExecute = true
		end
	end
end

---------------------------------------
-- Check if any target is in execute phase
---------------------------------------
function Engine.AnyTargetInExecute(state)
	for id, target in pairs(state.targets) do
		if target.inExecute and target.hp > 0 then
			return true
		end
	end
	return false
end

---------------------------------------
-- Count alive targets
---------------------------------------
function Engine.CountAliveTargets(state, maxRange)
	local count = 0
	for id, target in pairs(state.targets) do
		if target.hp > 0 then
			count = count + 1
		end
	end
	return count
end

---------------------------------------
-- Process DoT ticks
---------------------------------------
function Engine.ProcessDoTs(state)
	local damage = 0

	-- Deep Wounds
	if state.dots.deepwounds then
		for targetId, dot in pairs(state.dots.deepwounds) do
			if state.time >= dot.nextTick and state.time < dot.endTime then
				damage = damage + dot.tickDamage
				dot.nextTick = dot.nextTick + dot.tickInterval
			end
		end
	end

	-- Rend (tracked per target)
	if state.dots.rend then
		for targetId, dot in pairs(state.dots.rend) do
			if state.time >= dot.nextTick and state.time < dot.endTime then
				-- Check target still alive
				local target = state.targets[targetId]
				if target and target.hp > 0 then
					damage = damage + dot.tickDamage
				end
				dot.nextTick = dot.nextTick + dot.tickInterval
			end
		end
	end

	state.dotDamage = state.dotDamage + damage
	state.totalDamage = state.totalDamage + damage

	return damage
end

---------------------------------------
-- Get next event time
---------------------------------------
function Engine.GetNextEvent(state)
	local next = state.maxTime - state.time

	-- MH swing
	if state.mhTimer < next then
		next = state.mhTimer
	end

	-- OH swing
	if state.hasOH and state.ohTimer < next then
		next = state.ohTimer
	end

	-- GCD end
	if state.gcdEnd > state.time then
		local gcdRemain = state.gcdEnd - state.time
		if gcdRemain < next then
			next = gcdRemain
		end
	end

	-- Cooldowns
	for name, cdEnd in pairs(state.cooldowns) do
		if cdEnd > state.time then
			local cdRemain = cdEnd - state.time
			if cdRemain < next then
				next = cdRemain
			end
		end
	end

	-- DoT ticks
	if state.dots.deepwounds then
		for _, dot in pairs(state.dots.deepwounds) do
			if dot.nextTick > state.time then
				local remain = dot.nextTick - state.time
				if remain < next then next = remain end
			end
		end
	end
	if state.dots.rend then
		for _, dot in pairs(state.dots.rend) do
			if dot.nextTick > state.time then
				local remain = dot.nextTick - state.time
				if remain < next then next = remain end
			end
		end
	end

	-- Minimum step
	if next < 1 then next = 1 end

	return next
end

---------------------------------------
-- Check if ability can be used
---------------------------------------
function Engine.CanUseAbility(state, name)
	local ability = ATW.Abilities and ATW.Abilities[name]
	if not ability then return false end

	-- Check cooldown
	if state.cooldowns[name] and state.cooldowns[name] > state.time then
		return false
	end

	-- Check rage (with set bonus modifications)
	local cost = ability.rage or 0
	if ATW.GetModifiedRageCost then
		cost = ATW.GetModifiedRageCost(name, cost)
	elseif ATW.GetRageCost then
		cost = ATW.GetRageCost(name)
	end
	if state.rage < cost then
		return false
	end

	-- Check GCD (for GCD abilities)
	if ability.gcd and state.gcdEnd > state.time then
		return false
	end

	-- Check stance
	if ability.stance and ability.stance[1] ~= 0 then
		local validStance = false
		for _, s in ipairs(ability.stance) do
			if s == state.stance then
				validStance = true
				break
			end
		end
		if not validStance then
			return false
		end
	end

	-- Ability-specific conditions
	if name == "Execute" then
		return Engine.AnyTargetInExecute(state)
	elseif name == "Overpower" then
		return state.overpowerReady and state.overpowerEnd > state.time
	elseif name == "Cleave" then
		return Engine.CountAliveTargets(state) >= 2
	end

	return true
end

---------------------------------------
-- Execute ability and return damage (Zebouski formulas)
---------------------------------------
function Engine.UseAbility(state, name)
	local ability = ATW.Abilities and ATW.Abilities[name]
	if not ability then return 0 end

	-- Get rage cost with set bonus modifications
	local cost = ability.rage or 0
	if ATW.GetModifiedRageCost then
		cost = ATW.GetModifiedRageCost(name, cost)
	elseif ATW.GetRageCost then
		cost = ATW.GetRageCost(name)
	end
	local damage = 0

	-- Special handling for Execute (consumes all rage)
	if name == "Execute" then
		local baseCost = cost
		local usedRage = state.rage  -- Uses ALL rage

		-- Dreadnaught 8-set bonus: +200 AP during Execute
		local execAP = state.ap
		if state.setEffects and state.setEffects.dread8 then
			execAP = execAP + 200
		end

		-- TurtleWoW Execute: base + (rage * multiplier)
		-- Rank 5: 600 + (usedRage * 15)
		local execBase = ATW.GetExecuteBase and ATW.GetExecuteBase() or Engine.EXECUTE_BASE
		local execCoeff = ATW.GetExecuteCoeff and ATW.GetExecuteCoeff() or Engine.EXECUTE_RAGE_MULT
		damage = execBase + (usedRage * execCoeff)

		-- Consume ALL rage (Zebouski: spell.usedrage = ~~this.player.rage)
		state.rage = 0
	else
		-- Normal rage cost
		state.rage = state.rage - cost
		if state.rage < 0 then state.rage = 0 end

		-- Calculate damage using Zebouski formulas
		if name == "Bloodthirst" then
			-- TurtleWoW: 200 + AP * 0.35
			damage = Engine.BT_BASE + Engine.GetEffectiveAP(state) * Engine.BT_AP_COEFF

			-- Wrath 3-set bonus: +20 rage on Bloodthirst
			if state.setEffects and state.setEffects.wrath3 then
				state.rage = math.min(state.rage + 20, 100)
			end

		elseif name == "Whirlwind" then
			-- Normalized weapon damage + AP bonus
			-- Formula: weaponDmg + (ap/14) * normSpeed
			-- Dynamic normalization: 2.4 for 1H, 3.3 for 2H
			local normSpeed = Engine.GetNormalizationSpeed()
			local weaponDmg = Engine.RollWeaponDamage(state, false, true, normSpeed)
			local targets = math.min(Engine.CountAliveTargets(state), 4)
			damage = weaponDmg * targets

			-- Wrath 5-set bonus: +8% Whirlwind damage
			if state.setEffects and state.setEffects.wrath5 then
				damage = damage * 1.08
			end

		elseif name == "MortalStrike" then
			-- Weapon + bonus + (ap/14) * normSpeed
			-- Dynamic normalization: 2.4 for 1H, 3.3 for 2H
			local msBonus = ATW.GetMortalStrikeBonus and ATW.GetMortalStrikeBonus() or Engine.MS_BONUS
			local normSpeed = Engine.GetNormalizationSpeed()
			damage = Engine.RollWeaponDamage(state, false, true, normSpeed) + msBonus

		elseif name == "Slam" then
			-- Weapon + bonus + (ap/14) * weaponSpeed
			local slamBonus = ATW.GetSlamBonus and ATW.GetSlamBonus() or Engine.SLAM_BONUS
			damage = Engine.RollWeaponDamage(state, false, false) + slamBonus

		elseif name == "HeroicStrike" then
			-- Queue for next swing (damage calculated on swing)
			state.swingQueued = "hs"
			damage = 0

		elseif name == "Cleave" then
			-- Queue for next swing (damage calculated on swing)
			state.swingQueued = "cleave"
			damage = 0

		elseif name == "Rend" then
			-- Apply Rend DoT (damage from ticks, not instant)
			Engine.ApplyRend(state, "target")
			damage = 0

		elseif name == "Overpower" then
			-- Weapon + bonus + (ap/14) * speed
			local opBonus = ATW.GetOverpowerBonus and ATW.GetOverpowerBonus() or Engine.OP_BONUS
			damage = Engine.RollWeaponDamage(state, false, false) + opBonus
			state.overpowerReady = false

			-- Dreadnaught 6-set bonus: +30% Overpower damage
			if state.setEffects and state.setEffects.dread6 then
				damage = damage * 1.30
			end

		elseif name == "Hamstring" then
			damage = Engine.HAMSTRING_DMG
		end
	end

	-- Process crit (except for DoTs and queued abilities)
	if damage > 0 then
		local critChance = Engine.GetCritChance(state, name)
		damage = Engine.ProcessHit(state, damage, critChance, true, name)
	end

	-- Handle rage generation abilities
	if ability.rageGen then
		state.rage = math.min(state.rage + ability.rageGen, 100)
	end

	-- Apply buff effects for buff abilities
	if name == "BattleShout" then
		state.buffs.BattleShout = {
			endTime = state.time + Engine.BUFF_DURATIONS.BattleShout,
			stacks = 1,
		}
	elseif name == "DeathWish" then
		state.buffs.DeathWish = {
			endTime = state.time + Engine.BUFF_DURATIONS.DeathWish,
			stacks = 1,
		}
	elseif name == "Recklessness" then
		state.buffs.Recklessness = {
			endTime = state.time + Engine.BUFF_DURATIONS.Recklessness,
			stacks = 1,
		}
	elseif name == "BerserkerRage" then
		state.buffs.BerserkerRage = {
			endTime = state.time + Engine.BUFF_DURATIONS.BerserkerRage,
			stacks = 1,
		}
	elseif name == "Bloodrage" then
		state.buffs.Bloodrage = {
			endTime = state.time + Engine.BUFF_DURATIONS.Bloodrage,
			stacks = 1,
		}
		-- TurtleWoW (Nov 2024): Bloodrage self-damage can crit and proc Enrage
		-- Chance = player's physical crit chance
		if ATW.Talents and ATW.Talents.Enrage and ATW.Talents.Enrage > 0 then
			local critChance = Engine.GetCritChance(state) / 100
			if math.random() < critChance then
				state.buffs.Enrage = {
					endTime = state.time + Engine.BUFF_DURATIONS.Enrage,
					stacks = 1,
				}
			end
		end
	end

	-- Apply cooldown (check talents for dynamic CDs)
	local cooldownSeconds = ATW.GetAbilityCooldown and ATW.GetAbilityCooldown(name) or ability.cd
	if cooldownSeconds and cooldownSeconds > 0 then
		state.cooldowns[name] = state.time + (cooldownSeconds * 1000)
	end

	-- Apply GCD
	if ability.gcd then
		state.gcdEnd = state.time + Engine.GCD
	end

	-- Record in sequence
	table.insert(state.sequence, {
		time = state.time,
		ability = name,
		damage = damage,
		rage = state.rage,
	})

	state.abilityDamage = state.abilityDamage + damage
	state.totalDamage = state.totalDamage + damage

	return damage
end

---------------------------------------
-- Apply Rend DoT to target
-- Uses dynamic spell rank for damage/duration
---------------------------------------
function Engine.ApplyRend(state, targetId)
	if not state.dots.rend then
		state.dots.rend = {}
	end

	-- TurtleWoW Rend: base damage (from rank) + 5% AP per tick
	-- Uses effective AP (snapshots buffs at application time)
	-- ATW.GetRendTickDamage() includes Improved Rend talent bonus
	local baseTickDmg = ATW.GetRendTickDamage and ATW.GetRendTickDamage() or 21
	local tickDamage = baseTickDmg + (Engine.GetEffectiveAP(state) * Engine.REND_AP_COEFF)

	-- Duration from cached spell rank (set by LoadSpells)
	local duration = (ATW.RendDuration and ATW.RendDuration > 0) and ATW.RendDuration or 22
	local durationMs = duration * 1000

	state.dots.rend[targetId] = {
		endTime = state.time + durationMs,
		nextTick = state.time + 3000,
		tickDamage = tickDamage,
		tickInterval = 3000,
	}
end

---------------------------------------
-- Process Sweeping Strikes charge consumption
-- Duplicates damage to secondary target when SS is active
-- Returns additional damage dealt
---------------------------------------
function Engine.ProcessSweepingStrikes(state, primaryDamage, abilityName)
	-- Check if SS is active with charges
	if not state.sweepingCharges or state.sweepingCharges <= 0 then
		return 0
	end

	-- Need 2+ enemies in melee range for secondary target
	local meleeTargets = state.enemyCountMelee or 1
	if meleeTargets < 2 then
		return 0
	end

	-- Sweeping Strikes duplicates the damage to secondary target
	local ssDamage = primaryDamage

	-- Consume one charge
	state.sweepingCharges = state.sweepingCharges - 1

	-- Deactivate SS buff if no charges left
	if state.sweepingCharges <= 0 then
		state.hasSweepingStrikes = false
	end

	-- Track SS damage
	state.ssDamage = (state.ssDamage or 0) + ssDamage
	state.totalDamage = (state.totalDamage or 0) + ssDamage

	return ssDamage
end

---------------------------------------
-- Process auto-attack (MH or OH) - Zebouski style
-- Handles HS/Cleave queue, rage generation, and procs
---------------------------------------
function Engine.ProcessAutoAttack(state, isOH)
	local damage = Engine.RollWeaponDamage(state, isOH, false)
	local aliveTargets = Engine.CountAliveTargets(state)
	local isSpell = false  -- Whether this is a spell (HS/Cleave) or white hit

	if aliveTargets == 0 then
		return 0
	end

	-- Check for HS/Cleave queue (MH only)
	if not isOH and state.swingQueued then
		isSpell = true

		if state.swingQueued == "hs" then
			-- Heroic Strike: weapon + bonus (uses weapon speed for AP, not normalized)
			local hsBonus = ATW.GetHeroicStrikeBonus and ATW.GetHeroicStrikeBonus() or Engine.HS_BONUS
			damage = damage + hsBonus
			state.swingQueued = nil

			table.insert(state.sequence, {
				time = state.time,
				ability = "HeroicStrike",
				damage = damage,
				rage = state.rage,
			})

		elseif state.swingQueued == "cleave" then
			-- Cleave: weapon + bonus, hits 2 targets
			local cleaveBonus = ATW.GetCleaveBonus and ATW.GetCleaveBonus() or Engine.CLEAVE_BONUS
			damage = damage + cleaveBonus
			state.swingQueued = nil

			-- First target damage
			local firstTargetDmg = damage

			-- Second target (if available) - Zebouski calls attackmh recursively
			if aliveTargets >= 2 then
				local secondTargetDmg = Engine.RollWeaponDamage(state, false, false) + cleaveBonus
				damage = firstTargetDmg + secondTargetDmg
			end

			table.insert(state.sequence, {
				time = state.time,
				ability = "Cleave",
				damage = damage,
				rage = state.rage,
			})
		end
		-- No rage generated from HS/Cleave (already paid rage cost)
	else
		-- Generate rage from white hit
		Engine.GenerateRage(state, damage, isOH, false)
	end

	-- Process crit (applies to both white hits and HS/Cleave)
	local critChance = Engine.GetCritChance(state, isSpell and "HeroicStrike" or nil)
	local finalDamage, wasCrit = Engine.ProcessHit(state, damage, critChance, not isOH, isSpell)

	-- Consume Flurry charge on any swing
	if state.flurryCharges > 0 then
		state.flurryCharges = state.flurryCharges - 1
	end

	-- Sweeping Strikes: duplicate hit to secondary target (MH only, not Cleave)
	if not isOH and state.swingQueued ~= "cleave" then
		local abilityName = isSpell and "HS" or "Auto"
		local ssDamage = Engine.ProcessSweepingStrikes(state, finalDamage, abilityName)
		if ssDamage > 0 then
			state.autoDamage = state.autoDamage + ssDamage
			finalDamage = finalDamage + ssDamage
		end
	end

	state.autoDamage = state.autoDamage + finalDamage
	state.totalDamage = state.totalDamage + finalDamage

	-- Check for Hand of Justice proc (2% chance for extra attack)
	local hojDamage = Engine.CheckTrinketProcs(state, not isOH)
	if hojDamage > 0 then
		state.autoDamage = state.autoDamage + hojDamage
		state.totalDamage = state.totalDamage + hojDamage
		finalDamage = finalDamage + hojDamage
	end

	-- Master of Arms (Sword): 1/2/3/4/5% chance for an extra attack after MH hits.
	if not isOH then
		if ATW.Gear and ATW.Gear.weaponType == "Sword" and ATW.Talents and ATW.Talents.MasterOfArms and ATW.Talents.MasterOfArms > 0 then
			local procChance = ATW.Talents.MasterOfArms
			local roll = math.random() * 100
			if roll < procChance then
				-- Extra MH attack
				local damage = Engine.RollWeaponDamage(state, false, false)
				local critChance = Engine.GetCritChance(state, nil)
				local procDamage = Engine.ProcessHit(state, damage, critChance, true, nil)

				-- Generate rage from the extra attack
				Engine.GenerateRage(state, procDamage, false, false)

				state.autoDamage = state.autoDamage + procDamage
				state.totalDamage = state.totalDamage + procDamage
				finalDamage = finalDamage + procDamage
			end
		end
	end

	return finalDamage
end

---------------------------------------
-- Check trinket procs on auto-attack
---------------------------------------
function Engine.CheckTrinketProcs(state, isMH)
	local extraDamage = 0

	if not state.trinkets then return 0 end

	for _, trinket in ipairs(state.trinkets) do
		if trinket.data and trinket.data.proc then
			local proc = trinket.data.proc

			-- Hand of Justice: 2% chance extra attack
			if trinket.name == "Hand of Justice" then
				local roll = math.random() * 100
				if roll < (proc.chance or 2) then
					-- Extra MH attack
					local damage = Engine.RollWeaponDamage(state, false, false)
					local critChance = Engine.GetCritChance(state, nil)
					local procDamage, wasCrit = Engine.ProcessHit(state, damage, critChance, true, nil)

					-- Generate rage from the extra attack
					Engine.GenerateRage(state, procDamage, false, false)

					extraDamage = extraDamage + procDamage
				end
			end

			-- Flurry Axe: 5% chance extra attack (if equipped as MH)
			if trinket.name == "Flurry Axe" and isMH then
				local roll = math.random() * 100
				if roll < 5 then
					local damage = Engine.RollWeaponDamage(state, false, false)
					local critChance = Engine.GetCritChance(state, nil)
					local procDamage = Engine.ProcessHit(state, damage, critChance, true, nil)
					Engine.GenerateRage(state, procDamage, false, false)
					extraDamage = extraDamage + procDamage
				end
			end
		end
	end

	return extraDamage
end

---------------------------------------
-- Choose best ability to use (greedy by immediate damage)
-- NO HARDCODED PRIORITIES - uses same GetValidActions + GetActionDamage
-- as the main decision system
---------------------------------------
function Engine.ChooseAbility(state)
	-- Get all valid actions using the standard function
	local actions = Engine.GetValidActions(state)

	if not actions or table.getn(actions) == 0 then
		return nil, false
	end

	-- Find the action with highest immediate damage
	local bestAction = nil
	local bestDamage = -1

	for _, action in ipairs(actions) do
		local damage = Engine.GetActionDamage(state, action)

		if damage > bestDamage then
			bestDamage = damage
			bestAction = action
		end
	end

	if bestAction and bestAction.name ~= "Wait" then
		return bestAction.name, bestAction.offGCD or false
	end

	return nil, false
end

---------------------------------------
-- Cancel HS/Cleave queue in simulation
-- This RESETS the swing timer (important!)
-- Returns: wasQueued, rageSaved
---------------------------------------
function Engine.CancelSwingQueue(state)
	if not state.swingQueued then
		return false, 0
	end

	local canceledAbility = state.swingQueued
	local rageSaved = 0

	-- Determine rage that would have been spent
	if canceledAbility == "hs" then
		local hsCost = 15
		if ATW.Talents and ATW.Talents.HSCost then
			hsCost = ATW.Talents.HSCost
		end
		rageSaved = hsCost
	elseif canceledAbility == "cleave" then
		rageSaved = 20
	end

	-- Clear the queue
	state.swingQueued = nil

	-- CRITICAL: Canceling HS/Cleave resets swing timer!
	-- This is a significant penalty - we lose the swing progress
	state.mhTimer = state.mhSpeed / Engine.GetHasteMod(state)

	-- Record in sequence
	table.insert(state.sequence, {
		time = state.time,
		ability = "CancelHS",
		damage = 0,
		rage = state.rage,
		note = "swing reset",
	})

	return true, rageSaved
end

---------------------------------------
-- Evaluate if we should cancel HS/Cleave
-- Compares: value of HS + auto damage vs value of using rage now
-- Returns: shouldCancel, reason, expectedGain
---------------------------------------
function Engine.ShouldCancelSwing(state)
	if not state.swingQueued then
		return false, "nothing queued", 0
	end

	-- If swing is imminent (< 300ms), don't cancel
	if state.mhTimer < 300 then
		return false, "swing imminent", 0
	end

	-- Check what abilities we could use instead
	local inExecute = Engine.AnyTargetInExecute(state)
	local btReady = state.cooldowns.Bloodthirst <= state.time
	local wwReady = state.cooldowns.Whirlwind <= state.time

	-- Calculate HS/Cleave expected value
	local hsBonus = ATW.GetHeroicStrikeBonus and ATW.GetHeroicStrikeBonus() or Engine.HS_BONUS
	local hsDamage = hsBonus + ((state.mhDmgMin + state.mhDmgMax) / 2)
	local hsValue = hsDamage * Engine.GetDamageMod(state)

	-- Factor in crit chance
	local critChance = Engine.GetCritChance(state, "HeroicStrike") / 100
	local critMod = 1 + (ATW.Talents and ATW.Talents.Impale and ATW.Talents.Impale * 0.10 or 0)
	hsValue = hsValue * (1 + critChance * critMod)

	-- Penalty: we ALSO lose the auto-attack and reset swing timer
	-- This means we delay rage generation significantly
	local swingSpeed = state.mhSpeed / Engine.GetHasteMod(state)
	local autoValue = ((state.mhDmgMin + state.mhDmgMax) / 2) * Engine.GetDamageMod(state)

	-- Total value of NOT canceling = HS + auto (later) + rage gen
	-- Time to swing if we don't cancel: state.mhTimer
	-- Time to swing if we cancel: full swingSpeed

	-- Value of canceling:
	-- We can cast a main ability NOW instead of waiting

	-- Execute phase: ALWAYS prioritize Execute
	if inExecute then
		local execCost = ATW.Talents and ATW.Talents.ExecCost or 15
		if state.rage < execCost then
			return false, "not enough rage for exec anyway", 0
		end

		-- Execute with full rage is MUCH better than HS
		-- Execute = base + (rage * coeff)
		local execBase = ATW.GetExecuteBase and ATW.GetExecuteBase() or Engine.EXECUTE_BASE
		local execCoeff = ATW.GetExecuteCoeff and ATW.GetExecuteCoeff() or Engine.EXECUTE_RAGE_MULT
		local execDmg = execBase + (state.rage * execCoeff)

		-- If we wait for HS, we get HS damage but Execute later with less rage
		-- (rage spent on HS is rage not spent on Execute)
		local rageCost = state.swingQueued == "hs" and 15 or 20
		local execWithHS = execBase + ((state.rage - rageCost) * execCoeff)

		local gainFromCancel = execDmg - (execWithHS + hsValue)

		if gainFromCancel > 0 then
			return true, "execute priority", gainFromCancel
		end
	end

	-- BT/WW ready but can't afford
	local btCost = 30
	local wwCost = 25

	if btReady and state.rage >= btCost then
		-- We CAN afford BT, so HS is fine (rage dump)
		return false, "can afford BT with HS", 0
	end

	if wwReady and state.rage >= wwCost then
		return false, "can afford WW with HS", 0
	end

	-- If we can't afford main ability, consider canceling
	if btReady and state.rage < btCost then
		-- Would canceling let us cast BT?
		-- HS doesn't consume rage until swing lands, so no
		-- But by NOT queueing HS, we get rage gen from white hit
		-- This logic is for when HS is ALREADY queued

		-- The rage from HS cancellation doesn't help here directly
		-- But the white hit WILL generate rage

		-- Estimate rage from white hit
		local whiteDmg = (state.mhDmgMin + state.mhDmgMax) / 2
		local rageFromHit = (whiteDmg / Engine.RAGE_CONVERSION) * Engine.RAGE_HIT_FACTOR

		-- If white + current rage >= BT cost, cancel might help
		if state.rage + rageFromHit >= btCost then
			-- But we have to wait for swing first anyway
			-- And we're resetting the timer by canceling
			-- So this is actually WORSE (longer wait)
			return false, "swing reset hurts more", 0
		end
	end

	return false, "hs is optimal", 0
end

---------------------------------------
-- Main simulation loop
---------------------------------------
function Engine.Simulate(duration, strategy)
	strategy = strategy or "normal"
	duration = duration or 30  -- 30 second simulation window

	local state = Engine.CreateState()
	state.maxTime = duration * 1000

	-- Initialize
	Engine.InitTargets(state)
	Engine.InitPlayer(state)

	-- Track Anger Management ticks (every 3 seconds = 3000ms)
	local lastAngerManagementTick = 0

	-- Simulation loop
	while state.time < state.maxTime do
		-- Get next event time
		local deltaTime = Engine.GetNextEvent(state)

		-- Advance time
		state.time = state.time + deltaTime
		if state.time > state.maxTime then
			break
		end

		-- Anger Management: +1 rage every 3 seconds (Zebouski formula)
		if ATW.Talents and ATW.Talents.AngerManagement then
			while state.time >= lastAngerManagementTick + 3000 do
				lastAngerManagementTick = lastAngerManagementTick + 3000
				if state.rage < 100 then
					state.rage = math.min(state.rage + 1, 100)
				end
			end
		end

		-- Update target HP
		Engine.UpdateTargetHP(state, deltaTime)

		-- Update swing timers
		state.mhTimer = state.mhTimer - deltaTime
		if state.hasOH then
			state.ohTimer = state.ohTimer - deltaTime
		end

		-- Process DoT ticks
		Engine.ProcessDoTs(state)

		-- Process MH swing
		if state.mhTimer <= 0 then
			Engine.ProcessAutoAttack(state, false)
			-- Reset timer with haste
			local haste = Engine.GetHasteMod(state)
			state.mhTimer = state.mhSpeed / haste
		end

		-- Process OH swing
		if state.hasOH and state.ohTimer <= 0 then
			Engine.ProcessAutoAttack(state, true)
			local haste = Engine.GetHasteMod(state)
			state.ohTimer = state.ohSpeed / haste
		end

		-- Check if we should cancel HS/Cleave
		local shouldCancel, cancelReason = Engine.ShouldCancelSwing(state)
		if shouldCancel then
			Engine.CancelSwingQueue(state)
		end

		-- Choose and use ability (greedy by immediate damage - no hardcoded pooling)
		local abilityName, isOffGCD = Engine.ChooseAbility(state)

		if abilityName then
			Engine.UseAbility(state, abilityName)
		end

		-- Expire buffs
		for buffName, buff in pairs(state.buffs) do
			if buff.endTime and buff.endTime <= state.time then
				state.buffs[buffName] = nil
			end
		end

		-- Safety: prevent infinite loop
		if deltaTime == 0 then
			state.time = state.time + 1
		end
	end

	-- Return results
	return {
		totalDamage = state.totalDamage,
		abilityDamage = state.abilityDamage,
		autoDamage = state.autoDamage,
		dotDamage = state.dotDamage,
		duration = state.maxTime / 1000,
		dps = state.totalDamage / (state.maxTime / 1000),
		sequence = state.sequence,
	}
end


---------------------------------------
-- GUID Targeting Functions
-- Implementations are in Combat/GUIDTargeting.lua
-- These are aliases for backwards compatibility
---------------------------------------
Engine.GetNextRendTarget = function()
	if ATW.GUIDTargeting then
		return ATW.GUIDTargeting.GetNextRendTarget()
	end
	return nil, false
end

Engine.CastRendOnGUID = function(guid)
	if ATW.GUIDTargeting then
		return ATW.GUIDTargeting.CastRendOnGUID(guid)
	end
	return false
end

Engine.GetExecuteTarget = function()
	if ATW.GUIDTargeting then
		return ATW.GUIDTargeting.GetExecuteTarget()
	end
	return nil, nil, 100
end

Engine.CastExecuteOnGUID = function(guid)
	if ATW.GUIDTargeting then
		return ATW.GUIDTargeting.CastExecuteOnGUID(guid)
	end
	-- Fallback: use explicit target GUID to reset spell target
	local _, targetGuid = UnitExists("target")
	if targetGuid and targetGuid ~= "" then
		CastSpellByName("Execute", targetGuid)
	else
		CastSpellByName("Execute")
	end
	return true
end

Engine.GetExecuteTargets = function()
	if ATW.GUIDTargeting then
		return ATW.GUIDTargeting.GetExecuteTargets()
	end
	return {}
end

---------------------------------------
-- Get next recommended ability (for display)
-- 100% SIMULATION-BASED - No hardcoded priorities
-- Simulates all valid actions over 6s horizon and picks highest damage
-- Returns: abilityName, isOffGCD, pooling, timeToExecute, targetGUID, targetStance
---------------------------------------
function Engine.GetRecommendation()
	return Engine.GetRecommendationSimBased()
end

-- NOTE: Legacy GetRecommendationLegacy has been REMOVED
-- All decisions are now 100% simulation-based via GetRecommendationSimBased()

---------------------------------------
-- Simulate ahead with full engine (returns sequence)
---------------------------------------
function Engine.SimulateAhead(steps, duration)
	steps = steps or 5
	duration = duration or 30  -- 30 second lookahead

	local result = Engine.Simulate(duration)

	-- Return first N abilities from sequence
	local sequence = {}
	for i = 1, math.min(steps, table.getn(result.sequence)) do
		local s = result.sequence[i]
		table.insert(sequence, {
			ability = s.ability,
			damage = s.damage,
			rageAfter = s.rage,
			timeOffset = s.time / 1000,
		})
	end

	return sequence
end

---------------------------------------
-- Debug: Print simulation results
---------------------------------------
function Engine.PrintSimulation(duration)
	local result = Engine.Simulate(duration or 30)

	ATW.Print("=== Combat Simulation ===")
	ATW.Print("Duration: " .. string.format("%.1f", result.duration) .. "s")
	ATW.Print("Total damage: " .. string.format("%.0f", result.totalDamage))
	ATW.Print("  Abilities: " .. string.format("%.0f", result.abilityDamage))
	ATW.Print("  Auto-attack: " .. string.format("%.0f", result.autoDamage))
	ATW.Print("  DoTs: " .. string.format("%.0f", result.dotDamage))
	ATW.Print("DPS: " .. string.format("%.0f", result.dps))

	ATW.Print("")
	ATW.Print("Ability sequence (first 10):")
	for i = 1, math.min(table.getn(result.sequence), 10) do
		local s = result.sequence[i]
		ATW.Print("  " .. string.format("+%.1fs", s.time/1000) .. " " ..
			s.ability .. " -> " .. string.format("%.0f", s.damage) .. " dmg")
	end
end

---------------------------------------
-- DECISION SIMULATOR
-- Single-layer tactical simulation with manual cooldown toggles
-- Cooldowns controlled via BurstEnabled/RecklessEnabled/SyncCooldowns
-- See Documentation/Toggles.md for details
---------------------------------------

-- Configuration
-- Decision horizon: how far ahead to simulate (in milliseconds)
-- Default: 9 seconds (6 GCDs) - enough for tactical choices without live lag
Engine.TACTICAL_HORIZON = 9000
Engine.DECISION_HORIZON = 9000  -- Alias for backwards compatibility
Engine.DECISION_GCD = 1500       -- 1.5s GCD

-- Get configured horizon (from config or default)
function Engine.GetHorizon()
	local cfg = AutoTurtleWarrior_Config
	if cfg and cfg.DecisionHorizon and cfg.DecisionHorizon > 0 then
		return cfg.DecisionHorizon
	end
	return Engine.DECISION_HORIZON
end

---------------------------------------
-- CACHING SYSTEM
-- Avoids redundant calculations when state hasn't changed
---------------------------------------
Engine.Cache = {
	lastState = nil,
	lastResult = nil,
	lastUpdateTime = 0,
	MIN_UPDATE_INTERVAL = 100,  -- 100ms minimum between full recalculations
	dirty = false,  -- Explicit dirty flag for event-driven invalidation
	hits = 0,
	misses = 0,
}

---------------------------------------
-- Invalidate Cache (Event-Driven)
-- Call this from events when something important changes:
-- - Cooldown completes
-- - Rage changes significantly
-- - Buff applies/expires
-- - Overpower proc
-- - Target HP changes (Execute range)
---------------------------------------
function Engine.InvalidateCache()
	Engine.Cache.dirty = true
	Engine.Cache.lastState = nil
	Engine.Cache.lastResult = nil
	-- Force recomputation on next GetNextAbility() call
end

function Engine.BuildRendStateKey(enemies)
	if not enemies then return "" end

	local key = ""
	local count = 0
	for _, enemy in ipairs(enemies) do
		if enemy.distance and enemy.distance <= 5 then
			count = count + 1
			local guid = enemy.guid or ("target" .. count)
			local rendBucket = math.floor((enemy.rendRemaining or 0) / Engine.GCD)
			local ttdBucket = math.floor((enemy.ttd or 0) / 3000)
			key = key .. guid .. ":" .. (enemy.hasRend and "1" or "0") .. ":" .. rendBucket .. ":" .. ttdBucket .. ";"
			if count >= 6 then break end
		end
	end
	return key
end

-- Check if state changed enough to require recalculation
function Engine.CacheValid(newState)
	local cache = Engine.Cache
	local now = GetTime() * 1000

	-- Check dirty flag first (event-driven invalidation)
	if cache.dirty then
		cache.dirty = false  -- Clear flag
		return false  -- Force recalculation
	end

	-- Always recalculate if enough time has passed
	if now - cache.lastUpdateTime > 500 then  -- Max 500ms cache lifetime
		return false
	end

	-- Minimum interval not passed - use cache
	if now - cache.lastUpdateTime < cache.MIN_UPDATE_INTERVAL then
		return true
	end

	local oldState = cache.lastState
	if not oldState then return false end

	-- Check for significant changes
	-- Rage changed by 5+ points
	if math.abs((newState.rage or 0) - (oldState.rage or 0)) >= 5 then
		return false
	end

	-- Stance changed
	if newState.stance ~= oldState.stance then
		return false
	end

	-- Target or mode toggles changed
	if (newState.targetGUID or "") ~= (oldState.targetGUID or "") then
		return false
	end
	if (newState.aoeEnabled or false) ~= (oldState.aoeEnabled or false) then
		return false
	end
	if (newState.rendSpreadEnabled or false) ~= (oldState.rendSpreadEnabled or false) then
		return false
	end

	-- Entered or left execute phase
	local oldExecute = (oldState.targetHPPercent or 100) < 20
	local newExecute = (newState.targetHPPercent or 100) < 20
	if oldExecute ~= newExecute then
		return false
	end

	if math.abs((newState.targetHPPercent or 100) - (oldState.targetHPPercent or 100)) >= 5 then
		return false
	end

	if math.abs((newState.targetTTD or 30000) - (oldState.targetTTD or 30000)) >= 3000 then
		return false
	end

	-- Rend spreading decisions depend on exact per-GUID DoT state.
	if (newState.rendOnTarget or false) ~= (oldState.rendOnTarget or false) then
		return false
	end
	if math.abs((newState.rendRemaining or 0) - (oldState.rendRemaining or 0)) >= Engine.GCD then
		return false
	end

	-- Overpower proc appeared/expired
	if (oldState.overpowerReady or false) ~= (newState.overpowerReady or false) then
		return false
	end

	-- Any major cooldown came off cooldown
	local majorCDs = {"Bloodthirst", "Whirlwind", "MortalStrike", "Overpower", "DeathWish", "Recklessness"}
	for _, cd in ipairs(majorCDs) do
		local oldCD = oldState.cooldowns and oldState.cooldowns[cd] or 0
		local newCD = newState.cooldowns and newState.cooldowns[cd] or 0
		-- CD just became ready
		if oldCD > 0 and newCD <= 0 then
			return false
		end
	end

	-- GCD ended
	if (oldState.gcdEnd or 0) > 0 and (newState.gcdEnd or 0) <= 0 then
		return false
	end

	-- Swing queue state changed (HS/Cleave toggle prevention)
	if (oldState.swingQueued or nil) ~= (newState.swingQueued or nil) then
		return false
	end

	-- MH swing is imminent (< 300ms) - recalculate to properly value HS/Cleave
	-- This ensures we make the right decision when a swing is about to land
	local mhTimer = newState.mhTimer or 0
	if mhTimer > 0 and mhTimer < 300 then
		return false
	end

	-- Enemy count changed
	if (oldState.enemyCount or 1) ~= (newState.enemyCount or 1) then
		return false
	end
	if (oldState.enemyCountMelee or 1) ~= (newState.enemyCountMelee or 1) then
		return false
	end
	if (oldState.enemyCountWW or 1) ~= (newState.enemyCountWW or 1) then
		return false
	end
	if (oldState.rendStateKey or "") ~= (newState.rendStateKey or "") then
		return false
	end

	-- Cache is valid
	return true
end

-- Update cache with new result
function Engine.UpdateCache(state, result)
	Engine.Cache.lastState = state
	Engine.Cache.lastResult = result
	Engine.Cache.lastUpdateTime = GetTime() * 1000
	Engine.Cache.misses = Engine.Cache.misses + 1
end

-- Get cached result
function Engine.GetCachedResult()
	Engine.Cache.hits = Engine.Cache.hits + 1
	return Engine.Cache.lastResult
end

---------------------------------------
-- Deep copy state for branching
---------------------------------------
function Engine.DeepCopyState(state)
	local copy = {}
	for k, v in pairs(state) do
		if type(v) == "table" then
			copy[k] = {}
			for k2, v2 in pairs(v) do
				if type(v2) == "table" then
					copy[k][k2] = {}
					for k3, v3 in pairs(v2) do
						copy[k][k2][k3] = v3
					end
				else
					copy[k][k2] = v2
				end
			end
		else
			copy[k] = v
		end
	end
	return copy
end

---------------------------------------
-- Capture current combat state from game
-- Used for live decision making
-- Full MULTI-TARGET support (Zebouski-style)
---------------------------------------
function Engine.CaptureCurrentState()
	local state = Engine.CreateState()

	-- Initialize from current game state
	Engine.InitPlayer(state)
	Engine.InitTargets(state)

	-- Current rage
	state.rage = UnitMana("player") or 0

	-- Current stance
	state.stance = ATW.Stance and ATW.Stance() or 3

	-- Stance GCD: check if we recently switched stances (1.5s internal CD)
	state.stanceGcdEnd = 0
	if ATW.State and ATW.State.LastStance then
		local stanceCdRemaining = (ATW.State.LastStance + 1.5) - GetTime()
		if stanceCdRemaining > 0 then
			state.stanceGcdEnd = stanceCdRemaining * 1000  -- Convert to ms
		end
	end

	---------------------------------------
	-- CAPTURE REAL GCD STATE
	-- Check any GCD-triggering spell to detect active GCD
	---------------------------------------
	state.gcdEnd = 0
	local gcdSpell = ATW.SpellID and (ATW.SpellID("Battle Shout") or ATW.SpellID("Heroic Strike") or ATW.SpellID("Rend"))
	if gcdSpell then
		local start, duration = GetSpellCooldown(gcdSpell, BOOKTYPE_SPELL)
		-- GCD shows as a short cooldown (1.5s) vs longer ability CDs
		if start and start > 0 and duration and duration > 0 and duration <= 1.5 then
			local remaining = (start + duration) - GetTime()
			if remaining > 0 then
				state.gcdEnd = remaining * 1000  -- Convert to ms
			end
		end
	end

	-- Overpower window
	if ATW.State and ATW.State.Overpower then
		local windowRemaining = 4 - (GetTime() - ATW.State.Overpower)
		if windowRemaining > 0 then
			state.overpowerReady = true
			state.overpowerEnd = windowRemaining * 1000
		end
	end

	-- Battle Shout status and AP value
	state.hasBattleShout = ATW.Buff and ATW.Buff("player", "Ability_Warrior_BattleShout")
	-- Read the AP value of the active Battle Shout (via tooltip scanning)
	-- This allows us to compare and only override if ours is better
	state.activeBattleShoutAP = 0
	if state.hasBattleShout and ATW.GetActiveBattleShoutAP then
		state.activeBattleShoutAP = ATW.GetActiveBattleShoutAP()
	end

	---------------------------------------
	-- BUFF TRACKING for cooldown abilities
	---------------------------------------
	-- Death Wish buff (+20% damage)
	state.hasDeathWish = ATW.Buff and ATW.Buff("player", "Spell_Shadow_DeathPact")

	-- Recklessness buff (+100% crit)
	state.hasRecklessness = ATW.Buff and ATW.Buff("player", "Ability_CriticalStrike")

	-- Berserker Rage buff (fear immunity + rage gen)
	state.hasBerserkerRage = ATW.Buff and ATW.Buff("player", "Spell_Nature_AncestralGuardian")

	-- Sweeping Strikes buff (AoE)
	state.hasSweepingStrikes = ATW.Buff and ATW.Buff("player", "Ability_Rogue_SliceDice")

	-- Enrage buff (TurtleWoW: from Bloodrage crit or taking crits with talent)
	state.hasEnrage = ATW.Buff and ATW.Buff("player", "Spell_Shadow_UnholyFrenzy")

	-- Bloodrage active (DoT on self = generating rage)
	state.hasBloodrageActive = ATW.Buff and ATW.Buff("player", "Ability_Racial_BloodRage")

	---------------------------------------
	-- RACIAL BUFF STATE
	---------------------------------------
	-- Blood Fury (Orc) - texture: Racial_Orc_BerserkerStrength
	state.hasBloodFury = ATW.Buff and ATW.Buff("player", "Racial_Orc_BerserkerStrength")

	-- Berserking (Troll) - texture: Racial_Troll_Berserk
	state.hasBerserking = ATW.Buff and ATW.Buff("player", "Racial_Troll_Berserk")

	-- Perception (Human) - texture: Spell_Nature_Sleep (TurtleWoW)
	state.hasPerception = ATW.Buff and ATW.Buff("player", "Spell_Nature_Sleep")

	---------------------------------------
	-- COOLDOWN CAPTURE FROM GAME API
	-- Read actual cooldowns so simulation knows what's available
	---------------------------------------
	if ATW.GetCooldownRemaining then
		-- Main abilities
		state.cooldowns.Bloodthirst = ATW.GetCooldownRemaining("Bloodthirst")
		state.cooldowns.MortalStrike = ATW.GetCooldownRemaining("Mortal Strike")
		state.cooldowns.Whirlwind = ATW.GetCooldownRemaining("Whirlwind")
		state.cooldowns.Overpower = ATW.GetCooldownRemaining("Overpower")
		state.cooldowns.Pummel = ATW.GetCooldownRemaining("Pummel")
		state.cooldowns.Slam = ATW.GetCooldownRemaining("Slam")
		state.cooldowns.Charge = ATW.GetCooldownRemaining("Charge")

		-- Cooldown abilities
		state.cooldowns.Bloodrage = ATW.GetCooldownRemaining("Bloodrage")
		state.cooldowns.BerserkerRage = ATW.GetCooldownRemaining("Berserker Rage")
		state.cooldowns.DeathWish = ATW.GetCooldownRemaining("Death Wish")
		state.cooldowns.Recklessness = ATW.GetCooldownRemaining("Recklessness")
		state.cooldowns.SweepingStrikes = ATW.GetCooldownRemaining("Sweeping Strikes")

		-- Racial cooldowns
		state.cooldowns.BloodFury = ATW.GetCooldownRemaining("Blood Fury")
		state.cooldowns.Berserking = ATW.GetCooldownRemaining("Berserking")
		state.cooldowns.Perception = ATW.GetCooldownRemaining("Perception")
	end

	---------------------------------------
	-- INTERRUPT STATE (for Pummel)
	-- Uses new CastingTracker for reliable detection
	---------------------------------------
	state.shouldInterrupt = false
	state.interruptTargetGUID = nil

	if AutoTurtleWarrior_Config.PummelEnabled and ATW.ShouldInterrupt then
		local shouldInt, targetGUID, spellName = ATW.ShouldInterrupt()
		state.shouldInterrupt = shouldInt
		state.interruptTargetGUID = targetGUID
		state.interruptSpellName = spellName
	elseif ATW.State and ATW.State.Interrupt then
		-- Legacy fallback: combat log detection
		state.shouldInterrupt = true
	end

	---------------------------------------
	-- COMBAT STATE (for Charge - only works out of combat)
	---------------------------------------
	state.inCombat = UnitAffectingCombat("player") or false

	---------------------------------------
	-- TARGET DISTANCE AND MELEE RANGE
	-- Key insight:
	-- - In combat: assume melee (we're fighting)
	-- - Out of combat + in Charge range: NOT in melee (need to Charge first!)
	-- This ensures Charge is properly valued vs buffs like Perception
	---------------------------------------
	-- Use horizontal distance (2D) for Charge and melee range validation
	-- This ignores height differences when on ramps/stairs (< 6 yards vertical)
	-- Matches how vanilla WoW Charge and melee combat work (see CMaNGOS Spell.cpp)
	state.targetDistance = nil
	if ATW.GetHorizontalDistance then
		state.targetDistance = ATW.GetHorizontalDistance("target")
	elseif ATW.GetDistance then
		-- Fallback to 3D distance if horizontal not available
		state.targetDistance = ATW.GetDistance("target")
	end

	state.timeToMelee = 0

	-- Determine melee range based on combat state and actual distance
	if state.inCombat then
		-- In combat: check REAL melee range (<=5 yards)
		-- This prevents recommending melee abilities after knockback/gap
		if state.targetDistance and state.targetDistance <= Engine.MELEE_RANGE then
			state.inMeleeRange = true
		else
			-- Out of melee range (e.g., after knockback)
			-- Don't recommend melee abilities until back in range
			state.inMeleeRange = false
		end
	else
		-- Out of combat: check if we're in Charge range (8-25 yards)
		-- If yes, we're NOT in melee - we need to Charge to get there!
		local inChargeRange = state.targetDistance and
			state.targetDistance >= Engine.CHARGE_MIN_RANGE and
			state.targetDistance <= Engine.CHARGE_MAX_RANGE

		if inChargeRange then
			-- We're at Charge range - NOT in melee
			-- Auto-attacks and melee abilities won't work until we Charge
			state.inMeleeRange = false
		else
			-- Either very close (<8yd) or no distance data - assume melee
			state.inMeleeRange = true
		end
	end

	---------------------------------------
	-- SWING QUEUE STATE (HS/Cleave already queued?)
	---------------------------------------
	if ATW.GetQueuedSwing then
		local queued = ATW.GetQueuedSwing()
		if queued == "HeroicStrike" or queued == "Heroic Strike" then
			state.swingQueued = "hs"
		elseif queued == "Cleave" then
			state.swingQueued = "cleave"
		elseif queued then
			state.swingQueued = queued  -- Any truthy value means queued
		end
	elseif ATW.IsSwingQueued and ATW.IsSwingQueued() then
		state.swingQueued = "hs"  -- Assume HS if we only know it's queued
	end

	---------------------------------------
	-- ALWAYS check current target FIRST (most reliable)
	-- Don't rely solely on nameplate detection
	---------------------------------------
	local targetGUID = nil
	if ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local _, guid = UnitExists("target")
		targetGUID = guid
	end
	state.targetGUID = targetGUID

	-- Get target stats directly from API (most reliable)
	if UnitExists("target") then
		local hp = UnitHealth("target") or 0
		local maxHp = UnitHealthMax("target") or 1
		state.targetHPPercent = maxHp > 0 and (hp / maxHp) * 100 or 100
		state.targetTTD = ATW.GetTargetTTD and (ATW.GetTargetTTD() * 1000) or 30000
		state.targetBleedImmune = ATW.IsBleedImmune and ATW.IsBleedImmune("target")

		-- CRITICAL: Check Rend on target directly using standard unit API
		-- This is the most reliable method - don't skip this!
		state.rendOnTarget = ATW.HasRend and ATW.HasRend("target") or false
		state.rendRemaining = 0

		if state.rendOnTarget then
			-- Get remaining duration from tracker
			if targetGUID and ATW.GetRendRemaining then
				state.rendRemaining = (ATW.GetRendRemaining(targetGUID) or 0) * 1000
			end
			-- If tracker has no info but Rend is active, assume full duration
			if state.rendRemaining <= 0 then
				local rendDur = (ATW.RendDuration and ATW.RendDuration > 0) and ATW.RendDuration or 22
				state.rendRemaining = rendDur * 1000
			end
		end
	else
		state.targetHPPercent = 100
		state.targetTTD = 30000
		state.targetBleedImmune = false
		state.rendOnTarget = false
		state.rendRemaining = 0
	end

	---------------------------------------
	-- MULTI-TARGET TRACKING
	-- Capture all enemies via nameplates
	-- OPTIMIZATION: Skip when AoEEnabled = false (single target mode)
	---------------------------------------
	state.enemies = {}
	state.enemyCount = 0
	state.enemyCountMelee = 0
	state.enemyCountWW = 0

	-- Check config toggles (with defaults)
	local aoeEnabled = AutoTurtleWarrior_Config.AoEEnabled
	if aoeEnabled == nil then aoeEnabled = true end
	local rendSpreadEnabled = AutoTurtleWarrior_Config.RendSpread
	if rendSpreadEnabled == nil then rendSpreadEnabled = true end

	-- AoE OFF implies Rend Spread OFF (single target funnel mode)
	if not aoeEnabled then
		rendSpreadEnabled = false
	end

	-- Store in state for GetValidActions to use
	state.aoeEnabled = aoeEnabled
	state.rendSpreadEnabled = rendSpreadEnabled

	local targetFoundInList = false

	-- Only build full enemy list if AoE OR RendSpread is enabled
	-- Otherwise we only need the main target
	if (aoeEnabled or rendSpreadEnabled) and ATW.GetEnemiesWithTTD then
		local allEnemies = ATW.GetEnemiesWithTTD(8)

		for _, enemy in ipairs(allEnemies) do
			local hpPercent = 100
			if enemy.hp and enemy.maxHp and enemy.maxHp > 0 then
				hpPercent = (enemy.hp / enemy.maxHp) * 100
			end

			local isTarget = (targetGUID and enemy.guid == targetGUID)

			local enemyState = {
				guid = enemy.guid,
				distance = enemy.distance or 5,
				ttd = (enemy.ttd or 30) * 1000,
				hpPercent = hpPercent,
				bleedImmune = enemy.bleedImmune or false,
				hasRend = enemy.hasRend or false,
				rendRemaining = (enemy.rendRemaining or 0) * 1000,
				isTarget = isTarget,
				inExecute = hpPercent < 20,
			}

			-- For current target, use our direct API check (more reliable)
			if isTarget then
				targetFoundInList = true
				enemyState.hasRend = state.rendOnTarget
				enemyState.rendRemaining = state.rendRemaining
				enemyState.hpPercent = state.targetHPPercent
				enemyState.ttd = state.targetTTD
				enemyState.bleedImmune = state.targetBleedImmune
				enemyState.inExecute = state.targetHPPercent < 20
			end

			table.insert(state.enemies, enemyState)
			state.enemyCount = state.enemyCount + 1

			if enemy.distance <= 5 then
				state.enemyCountMelee = state.enemyCountMelee + 1
			end
			if enemy.distance <= 8 then
				state.enemyCountWW = state.enemyCountWW + 1
			end
		end
	end

	-- If target exists but wasn't in nameplate list, add it
	if UnitExists("target") and not targetFoundInList then
		table.insert(state.enemies, {
			guid = targetGUID,
			distance = 5,
			ttd = state.targetTTD,
			hpPercent = state.targetHPPercent,
			bleedImmune = state.targetBleedImmune,
			hasRend = state.rendOnTarget,
			rendRemaining = state.rendRemaining,
			isTarget = true,
			inExecute = state.targetHPPercent < 20,
		})
		state.enemyCount = state.enemyCount + 1
		state.enemyCountMelee = state.enemyCountMelee + 1
		state.enemyCountWW = state.enemyCountWW + 1
	end

	if state.enemies and table.getn(state.enemies) > 1 then
		table.sort(state.enemies, function(a, b)
			if a.isTarget ~= b.isTarget then
				return a.isTarget
			end
			if (a.hasRend or false) ~= (b.hasRend or false) then
				return not a.hasRend
			end
			return (a.ttd or 0) > (b.ttd or 0)
		end)
	end
	state.rendStateKey = Engine.BuildRendStateKey(state.enemies)

	-- SINGLE TARGET MODE: Force enemy counts to 1 for AoE ability decisions
	-- This makes WW/Cleave behave as single-target (lower priority)
	if not aoeEnabled then
		state.enemyCountMelee = math.min(state.enemyCountMelee, 1)
		state.enemyCountWW = math.min(state.enemyCountWW, 1)
	end

	return state
end

---------------------------------------
-- Get all valid actions from current state
-- SIMULATION-BASED: Stance switches are explicit actions
-- Abilities only available in correct stance
-- Simulator decides EVERYTHING based on DPS calculations
---------------------------------------
function Engine.GetValidActions(state)
	local actions = {}
	local rage = state.rage
	local stance = state.stance
	local inExecute = state.targetHPPercent < 20

	-- Check if GCD is active (from CaptureCurrentState)
	local gcdActive = state.gcdEnd and state.gcdEnd > 0

	-- Tactical Mastery: rage retained on stance switch
	local tm = state.tacticalMastery or (ATW.Talents and ATW.Talents.TM) or 0

	-- Stance switch internal CD check
	local stanceCdReady = (state.stanceGcdEnd or 0) <= 0

	---------------------------------------
	-- GUARDRAILS: Direct Cooldown Verification
	-- Check if Overpower/Pummel just went on cooldown (meaning they were used)
	-- If they're still off-cooldown but should have been used, keep recommending
	---------------------------------------

	-- Check current readiness
	local overpowerCurrentlyReady = ATW.Ready and ATW.Ready("Overpower")
	local pummelCurrentlyReady = ATW.Ready and ATW.Ready("Pummel")

	-- OVERPOWER GUARDRAIL: Detect if it just went on cooldown
	if ATW.State then
		if ATW.State.LastOverpowerReady and not overpowerCurrentlyReady then
			-- Overpower transitioned from ready -> not ready = it was used!
			-- Clear the proc
			if ATW.State.Overpower then
				ATW.Debug("Overpower detected on cooldown - proc consumed")
				ATW.State.Overpower = nil
			end
			-- Also clear iteration state
			if ATW.OverpowerIteration then
				ATW.OverpowerIteration.targets = {}
				ATW.OverpowerIteration.index = 0
			end
		end
		ATW.State.LastOverpowerReady = overpowerCurrentlyReady
	end

	-- PUMMEL GUARDRAIL: Detect if it just went on cooldown
	if ATW.State then
		if ATW.State.LastPummelReady and not pummelCurrentlyReady then
			-- Pummel transitioned from ready -> not ready = it was used successfully!
			-- Clear the old combat-log-based interrupt state (backward compatibility)
			if ATW.State.Interrupt then
				ATW.Debug("Pummel detected on cooldown - interrupt consumed")
				ATW.State.Interrupt = nil
			end
			-- NOTE: Do NOT clear CastingTracker here!
			-- - UNIT_CASTEVENT will naturally clear it when the cast ends ("FAIL" event)
			-- - If we clear it here, we lose tracking for other casting enemies
			-- - If Pummel missed/failed somehow, the enemy might still be casting
		end
		ATW.State.LastPummelReady = pummelCurrentlyReady
	end

	---------------------------------------
	-- STANCE SWITCH ACTIONS
	-- These are explicit actions the simulator can choose
	-- Value comes from enabling abilities + Berserker crit bonus
	-- NOTE: Default to true if AvailableStances not set (warriors have all stances at 60)
	---------------------------------------
	if stanceCdReady then
		local hasStance = function(s)
			if ATW.AvailableStances then
				return ATW.AvailableStances[s]
			end
			return true  -- Default: assume all stances available
		end

		-- Berserker Stance (if not already in it)
		if stance ~= 3 and hasStance(3) then
			table.insert(actions, {
				name = "BerserkerStance",
				targetStance = 3,
				isStanceSwitch = true,
				rage = 0,
				rageLoss = math.max(0, rage - tm),
			})
		end

		-- Battle Stance (if not already in it)
		if stance ~= 1 and hasStance(1) then
			table.insert(actions, {
				name = "BattleStance",
				targetStance = 1,
				isStanceSwitch = true,
				rage = 0,
				rageLoss = math.max(0, rage - tm),
			})
		end

		-- Defensive Stance: NEVER recommended for DPS rotation
	end

	-- Helper: check if spell is learned (has rank > 0)
	-- CRITICAL: Default to FALSE if we can't verify - prevents pooling for unlearned abilities
	local function hasSpell(spellName)
		-- Map internal names to ATW.Spells rank keys
		local spellRankMap = {
			-- Core abilities (ranked)
			Execute = "ExecuteRank",
			Rend = "RendRank",
			HeroicStrike = "HeroicStrikeRank",
			Cleave = "CleaveRank",
			Overpower = "OverpowerRank",
			Whirlwind = "WhirlwindRank",
			Slam = "SlamRank",
			Hamstring = "HamstringRank",
			BattleShout = "BattleShoutRank",
			-- Talent abilities
			Bloodthirst = "BloodthirstRank",
			MortalStrike = "MortalStrikeRank",
			-- Utility abilities (ranked)
			Charge = "ChargeRank",
			Bloodrage = "BloodrageRank",
			BerserkerRage = "BerserkerRageRank",
			Recklessness = "RecklessnessRank",
			DeathWish = "DeathWishRank",
			SweepingStrikes = "SweepingStrikesRank",
			Pummel = "PummelRank",
		}

		-- Check ATW.Spells first (most reliable)
		if ATW.Spells then
			local rankKey = spellRankMap[spellName]
			if rankKey then
				local rank = ATW.Spells[rankKey]
				if rank ~= nil then
					return rank > 0
				end
			end
		end

		-- Fallback: check if spell ID exists in spellbook
		if ATW.SpellID then
			-- Convert internal names to display names for spellbook lookup
			local displayNames = {
				BattleShout = "Battle Shout",
				HeroicStrike = "Heroic Strike",
				MortalStrike = "Mortal Strike",
				BerserkerRage = "Berserker Rage",
				DeathWish = "Death Wish",
				SweepingStrikes = "Sweeping Strikes",
			}
			local displayName = displayNames[spellName] or spellName
			local spellId = ATW.SpellID(displayName)
			if spellId then
				return true
			end
		end

		-- CRITICAL: Default to FALSE - don't pool for potentially unlearned spells
		-- This prevents the simulator from waiting for Execute when it's not learned
		return false
	end

	---------------------------------------
	-- Helper: Check if we can use melee abilities
	-- Logic:
	--   inMeleeRange = true  → CAN melee (in combat or very close)
	--   inMeleeRange = false, timeToMelee > 0 → traveling after Charge, wait
	--   inMeleeRange = false, timeToMelee = 0 → at Charge range, CAN'T melee
	---------------------------------------
	local function canMelee()
		-- In melee range = can use melee abilities
		if state.inMeleeRange then
			return true
		end
		-- Not in melee range = can't melee (either traveling or at Charge range)
		return false
	end

	-- Whirlwind has 8-yard range, slightly longer than melee
	local function canWhirlwind()
		-- In melee range = can WW
		if state.inMeleeRange then
			return true
		end
		-- Not in melee = can't WW
		return false
	end

	---------------------------------------
	-- CHARGE (Battle Stance ONLY, OUT OF COMBAT ONLY)
	-- Simulator will recommend BattleStance first if needed
	---------------------------------------
	if hasSpell("Charge") and not state.inCombat and stance == 1 then
		local inChargeRange = state.targetDistance and state.targetDistance >= 8 and state.targetDistance <= 25
		local chargeReady = (state.cooldowns.Charge or 0) <= 0
		if chargeReady and inChargeRange then
			local chargeRage = (ATW.Talents and ATW.Talents.ChargeRage) or 9
			table.insert(actions, {name = "Charge", rage = 0, rageGain = chargeRage})
		end
	end

	---------------------------------------
	-- Execute (Battle OR Berserker, target < 20%, REQUIRES MELEE)
	-- Available in both stances - simulator picks based on crit bonus
	---------------------------------------
	if inExecute and hasSpell("Execute") and (stance == 1 or stance == 3) and canMelee() then
		local execCost = ATW.GetRageCost and ATW.GetRageCost("Execute") or 15
		if rage >= execCost then
			table.insert(actions, {name = "Execute", rage = execCost})
		end
	end

	---------------------------------------
	-- Bloodthirst (Berserker ONLY, 30 rage, 6s CD, REQUIRES MELEE)
	---------------------------------------
	if ATW.Talents and ATW.Talents.HasBT and stance == 3 and canMelee() then
		local btCost = 30
		local btReady = (state.cooldowns.Bloodthirst or 0) <= 0
		if btReady and rage >= btCost then
			table.insert(actions, {name = "Bloodthirst", rage = btCost})
		end
	end

	---------------------------------------
	-- Mortal Strike (Battle OR Berserker, 30 rage, 6s CD, REQUIRES MELEE)
	-- TurtleWoW allows MS in Berserker stance
	---------------------------------------
	if ATW.Talents and ATW.Talents.HasMS and (stance == 1 or stance == 3) and canMelee() then
		local msCost = 30
		local msReady = (state.cooldowns.MortalStrike or 0) <= 0
		if msReady and rage >= msCost then
			table.insert(actions, {name = "MortalStrike", rage = msCost})
		end
	end

	---------------------------------------
	-- Whirlwind (Berserker ONLY, 25 rage, 10s CD, 8 YARD RANGE)
	---------------------------------------
	if hasSpell("Whirlwind") and stance == 3 and canWhirlwind() then
		local wwCost = 25
		local wwReady = (state.cooldowns.Whirlwind or 0) <= 0
		if wwReady and rage >= wwCost then
			table.insert(actions, {name = "Whirlwind", rage = wwCost})
		end
	end

	---------------------------------------
	-- Overpower (Battle ONLY, 5 rage, requires dodge proc, REQUIRES MELEE)
	---------------------------------------
	if hasSpell("Overpower") and state.overpowerReady and state.overpowerEnd > 0 and stance == 1 and canMelee() then
		local opCost = 5
		local opReady = (state.cooldowns.Overpower or 0) <= 0
		if opReady and rage >= opCost then
			table.insert(actions, {name = "Overpower", rage = opCost})
		end
	end

	---------------------------------------
	-- Battle Shout (any stance, 10 rage)
	-- Smart override: Only cast if no buff OR if ours is better
	---------------------------------------
	if hasSpell("BattleShout") then
		local bsCost = 10
		local shouldCast = false

		if not state.hasBattleShout then
			-- No Battle Shout active - cast ours
			shouldCast = true
		else
			-- Battle Shout is active - compare AP values
			-- Calculate OUR Battle Shout AP (rank + Improved BS talent)
			local ourBattleShoutAP = ATW.GetBattleShoutAP and ATW.GetBattleShoutAP() or 232
			local activeBattleShoutAP = state.activeBattleShoutAP or 0

			-- Only override if ours is BETTER (more AP)
			-- Add 5 AP threshold to avoid spamming on equal values
			if ourBattleShoutAP > (activeBattleShoutAP + 5) then
				shouldCast = true
			end
		end

		if shouldCast and rage >= bsCost then
			table.insert(actions, {name = "BattleShout", rage = bsCost})
		end
	end

	---------------------------------------
	-- REND (Battle OR Defensive ONLY, 10 rage, REQUIRES MELEE)
	-- Simulator will recommend BattleStance first if needed
	-- CONSERVATIVE: Require 12s TTD for meaningful tick value
	---------------------------------------
	local rendCost = 10
	local MIN_REND_TTD = 9000  -- 9s = 3 ticks minimum; TurtleWoW Rend AP scaling is strong
	local MAX_REND_SPREAD_CANDIDATES = 4
	local rendCandidates = 0

	if not gcdActive and hasSpell("Rend") and (stance == 1 or stance == 2) and rage >= rendCost and canMelee() then
		-- Multi-target Rend spread (already checks enemy.distance <= 5)
		if state.rendSpreadEnabled and state.enemies and table.getn(state.enemies) > 0 then
			for _, enemy in ipairs(state.enemies) do
				if not enemy.bleedImmune and not enemy.inExecute then
					if not enemy.hasRend or enemy.rendRemaining < Engine.GCD then
						if enemy.ttd >= MIN_REND_TTD and enemy.distance <= 5 then
							table.insert(actions, {
								name = "Rend",
								rage = rendCost,
								targetGUID = enemy.guid,
								targetTTD = enemy.ttd,
								targetHP = enemy.hpPercent,
								isMainTarget = enemy.isTarget,
							})
							rendCandidates = rendCandidates + 1
							if rendCandidates >= MAX_REND_SPREAD_CANDIDATES then
								break
							end
						end
					end
				end
			end
		else
			-- Single target Rend
			if not state.targetBleedImmune and not inExecute then
				if not state.rendOnTarget or state.rendRemaining < Engine.GCD then
					if state.targetTTD >= MIN_REND_TTD then
						table.insert(actions, {name = "Rend", rage = rendCost})
					end
				end
			end
		end
	end

	---------------------------------------
	-- Slam (any stance, 15 rage, resets swing timer, REQUIRES MELEE)
	-- ONLY with 2H weapon, only after auto landed
	---------------------------------------
	if hasSpell("Slam") and not state.hasOH and canMelee() then
		local slamCost = 15
		local slamReady = (state.cooldowns.Slam or 0) <= 0
		if slamReady and rage >= slamCost then
			local mhTimer = state.mhTimer or 0
			local mhSpeed = state.mhSpeed or 2500
			local swingJustLanded = mhTimer >= (mhSpeed * 0.85)
			if swingJustLanded then
				table.insert(actions, {name = "Slam", rage = slamCost})
			end
		end
	end

	---------------------------------------
	-- Heroic Strike (any stance, off-GCD, CAN PRE-QUEUE)
	-- Queues for next MH swing - can be queued BEFORE reaching melee!
	-- This way HS is ready the instant we arrive and swing
	---------------------------------------
	if hasSpell("HeroicStrike") then
		local hsCost = ATW.GetHeroicStrikeCost and ATW.GetHeroicStrikeCost() or 15
		if rage >= hsCost and not state.swingQueued then
			table.insert(actions, {name = "HeroicStrike", rage = hsCost, offGCD = true})
		end
	end

	---------------------------------------
	-- Cleave (any stance, off-GCD, 2+ targets, CAN PRE-QUEUE)
	-- Queues for next MH swing - can be queued BEFORE reaching melee!
	-- This way Cleave is ready the instant we arrive and swing
	---------------------------------------
	if hasSpell("Cleave") then
		local numMeleeTargets = state.enemyCountMelee or 1
		local cleaveCost = 20
		if numMeleeTargets >= 2 and rage >= cleaveCost and not state.swingQueued then
			table.insert(actions, {name = "Cleave", rage = cleaveCost, offGCD = true})
		end
	end

	---------------------------------------
	-- Bloodrage (any stance, OFF-GCD)
	-- Philosophy: Use on CD for rage economy, soft-sync with burst
	-- TurtleWoW (Nov 2024): Can proc Enrage (+15% dmg 8s) based on crit chance
	-- Source: https://forum.turtle-wow.org/viewtopic.php?t=16775
	-- NOTE: Charge blocking is done in Rotation.lua (so timeline still shows Bloodrage)
	---------------------------------------
	if hasSpell("Bloodrage") then
		local bloodrageReady = (state.cooldowns.Bloodrage or 0) <= 0
		if bloodrageReady and not state.hasBloodrageActive then
			-- Check combat-only setting (default: true)
			local combatOnly = AutoTurtleWarrior_Config.BloodrageCombatOnly
			if combatOnly == nil then combatOnly = true end

			local shouldUse = true

			-- Combat-only check
			if combatOnly and not state.inCombat then
				shouldUse = false
			end

			-- Check CD mode
			local cdMode = AutoTurtleWarrior_Config.BloodrageBurstMode
			if cdMode == nil then cdMode = true end

			if cdMode then
				-- In CD mode: check BurstEnabled toggle (off in sustain)
				if not ATW.IsCooldownAllowed("Bloodrage") then
					shouldUse = false
				end

				-- SOFT SYNC with Death Wish (less restrictive than before)
				-- Only wait if: (1) DW coming soon AND (2) we have comfortable rage
				-- Philosophy: Rage economy > perfect sync. Don't starve yourself.
				if shouldUse and ATW.Has and ATW.Has.DeathWish then
					local syncEnabled = AutoTurtleWarrior_Config.SyncCooldowns
					if syncEnabled == nil then syncEnabled = true end
					if syncEnabled and rage > 40 then  -- Only hold if comfortable rage
						local dwCD = state.cooldowns and state.cooldowns.DeathWish or 999999
						if dwCD > 0 and dwCD <= 15000 then  -- 15s window (was 10s)
							shouldUse = false  -- Wait for DW
						end
					end
				end

				-- Emergency override: ALWAYS use if rage is low
				-- 30 rage threshold (was 20) - more aggressive to prevent starvation
				if not shouldUse and rage < 30 then
					shouldUse = true
				end
			end

			if shouldUse then
				table.insert(actions, {name = "Bloodrage", rage = 0, offGCD = true})
			end
		end
	end

	---------------------------------------
	-- Berserker Rage (Berserker ONLY, OFF-GCD)
	---------------------------------------
	if hasSpell("BerserkerRage") and ATW.Talents and ATW.Talents.HasIBR and stance == 3 then
		local brReady = (state.cooldowns.BerserkerRage or 0) <= 0
		if brReady and not state.hasBerserkerRage then
			table.insert(actions, {name = "BerserkerRage", rage = 0, offGCD = true})
		end
	end

	---------------------------------------
	-- Death Wish (any stance, OFF-GCD, +20% damage)
	---------------------------------------
	if ATW.IsCooldownAllowed("DeathWish") and ATW.Talents and ATW.Talents.HasDW then
		local dwReady = (state.cooldowns.DeathWish or 0) <= 0
		local dwCost = 10
		if dwReady and not state.hasDeathWish and rage >= dwCost then
			table.insert(actions, {name = "DeathWish", rage = dwCost, offGCD = true})
		end
	end

	---------------------------------------
	-- Recklessness (Berserker ONLY, OFF-GCD, +100% crit)
	---------------------------------------
	if ATW.IsCooldownAllowed("Recklessness") and hasSpell("Recklessness") and stance == 3 then
		local reckReady = (state.cooldowns.Recklessness or 0) <= 0
		if reckReady and not state.hasRecklessness then
			table.insert(actions, {name = "Recklessness", rage = 0, offGCD = true})
		end
	end

	---------------------------------------
	-- RACIAL ABILITIES (any stance, OFF-GCD)
	-- CD Sync: If enabled, racials wait for Death Wish
	---------------------------------------
	local function shouldWaitForDWSync()
		local syncEnabled = AutoTurtleWarrior_Config.SyncCooldowns
		if syncEnabled == nil then syncEnabled = true end
		if not syncEnabled then return false end
		if not ATW.Has or not ATW.Has.DeathWish then return false end
		local dwCD = state.cooldowns and state.cooldowns.DeathWish or 999999
		if dwCD <= 0 then return false end
		if dwCD > 0 and dwCD <= 10000 then return true end
		return false
	end

	local waitingForDW = shouldWaitForDWSync()

	-- Blood Fury (Orc)
	if ATW.IsCooldownAllowed("BloodFury") and ATW.Racials and ATW.Racials.HasBloodFury then
		local bfReady = (state.cooldowns.BloodFury or 0) <= 0
		if bfReady and not state.hasBloodFury and not waitingForDW then
			table.insert(actions, {name = "BloodFury", rage = 0, offGCD = true})
		end
	end

	-- Berserking (Troll)
	if ATW.IsCooldownAllowed("Berserking") and ATW.Racials and ATW.Racials.HasBerserking then
		local berserkReady = (state.cooldowns.Berserking or 0) <= 0
		local berserkCost = 5
		if berserkReady and not state.hasBerserking and rage >= berserkCost and not waitingForDW then
			table.insert(actions, {name = "Berserking", rage = berserkCost, offGCD = false})
		end
	end

	-- Perception (Human)
	if ATW.IsCooldownAllowed("Perception") and ATW.Racials and ATW.Racials.HasPerception then
		local percReady = (state.cooldowns.Perception or 0) <= 0
		if percReady and not state.hasPerception and not waitingForDW then
			table.insert(actions, {name = "Perception", rage = 0, offGCD = true})
		end
	end

	---------------------------------------
	-- Sweeping Strikes (Battle ONLY, 2+ targets)
	---------------------------------------
	local numMeleeTargets = state.enemyCountMelee or 1
	if hasSpell("SweepingStrikes") and numMeleeTargets >= 2 and stance == 1 then
		local ssReady = (state.cooldowns.SweepingStrikes or 0) <= 0
		local ssCost = 20
		if ssReady and not state.hasSweepingStrikes and rage >= ssCost then
			table.insert(actions, {name = "SweepingStrikes", rage = ssCost})
		end
	end

	---------------------------------------
	-- Pummel (Battle OR Berserker, OFF-GCD interrupt, REQUIRES MELEE)
	---------------------------------------
	if AutoTurtleWarrior_Config.PummelEnabled and hasSpell("Pummel") and state.shouldInterrupt and canMelee() then
		local pummelReady = (state.cooldowns.Pummel or 0) <= 0
		local pummelCost = 10
		if pummelReady and rage >= pummelCost and (stance == 1 or stance == 3) then
			table.insert(actions, {
				name = "Pummel",
				rage = pummelCost,
				offGCD = true,
				isInterrupt = true,
				targetGUID = state.interruptTargetGUID,
			})
		end
	end

	---------------------------------------
	-- Wait (always valid - for rage pooling)
	---------------------------------------
	table.insert(actions, {name = "Wait", rage = 0})

	return actions
end

---------------------------------------
-- Calculate damage for an action
-- Returns expected damage (includes crit expectation)
---------------------------------------
function Engine.GetActionDamage(state, action)
	-- Stance switches do 0 direct damage
	-- Their value comes from enabling future actions (captured by horizon simulation)
	if action.isStanceSwitch then
		return 0
	end

	local ap = state.ap or 1000

	-- If Battle Shout is active, add its AP
	if state.hasBattleShout then
		ap = ap + (ATW.GetBattleShoutAP and ATW.GetBattleShoutAP() or 232)
	end

	-- Crit chance already includes stance bonus via GetCritChance()
	local baseCrit = state.crit or 20
	-- Add Berserker bonus (GetCritChance does this too, but for consistency in damage calc)
	if state.stance == 3 then
		baseCrit = baseCrit + 3
	end
	local effectiveCrit = baseCrit

	-- Crit multiplier from Impale talent (10/20% bonus crit damage)
	-- Base crit = 2x damage, with Impale = 2.1x or 2.2x
	local impale = ATW.Talents and ATW.Talents.Impale or 0  -- 0/10/20
	local critMultiplier = 2.0 + (impale / 100)

	-- Expected damage multiplier from crit
	-- E[dmg] = baseDmg * (1 + critChance * (critMult - 1))
	local critExpectedMult = 1 + (effectiveCrit / 100) * (critMultiplier - 1)

	local damage = 0
	local canCrit = true  -- Most abilities can crit

	if action.name == "Execute" then
		local base = ATW.GetExecuteBase and ATW.GetExecuteBase() or 600
		local coeff = ATW.GetExecuteCoeff and ATW.GetExecuteCoeff() or 15
		local availableRage = state.rage
		local execCost = ATW.GetRageCost and ATW.GetRageCost("Execute") or 15
		local excess = math.max(0, availableRage - execCost)
		damage = base + (excess * coeff)

	elseif action.name == "Bloodthirst" then
		damage = ATW.GetBloodthirstDamage and ATW.GetBloodthirstDamage(ap) or (200 + ap * 0.35)

	elseif action.name == "MortalStrike" then
		local bonus = ATW.GetMortalStrikeBonus and ATW.GetMortalStrikeBonus() or 120
		local weaponDmg = (state.mhDmgMin + state.mhDmgMax) / 2
		damage = weaponDmg + bonus

	elseif action.name == "Whirlwind" then
		local weaponDmg = (state.mhDmgMin + state.mhDmgMax) / 2
		-- Use state.enemyCountWW (8yd range) from CaptureCurrentState
		local targetsHit = math.min(4, state.enemyCountWW or 1)
		if targetsHit < 1 then targetsHit = 1 end
		damage = weaponDmg * targetsHit

	elseif action.name == "Overpower" then
		local bonus = ATW.GetOverpowerBonus and ATW.GetOverpowerBonus() or 35
		local weaponDmg = (state.mhDmgMin + state.mhDmgMax) / 2
		damage = weaponDmg + bonus
		-- Overpower has +25/50% crit from Improved Overpower talent
		-- This is ON TOP of the stance crit bonus
		local opCritBonus = ATW.Talents and ATW.Talents.ImpOP or 0
		-- Overpower uses Battle Stance (no stance crit bonus)
		local opCrit = baseCrit + opCritBonus  -- No berserker bonus since it's Battle stance
		critExpectedMult = 1 + (opCrit / 100) * (critMultiplier - 1)

	elseif action.name == "Slam" then
		-- Slam: weapon damage + bonus; TurtleWoW pauses the swing timer
		local bonus = ATW.GetSlamBonus and ATW.GetSlamBonus() or 87
		local weaponDmg = (state.mhDmgMin + state.mhDmgMax) / 2
		damage = weaponDmg + bonus

	elseif action.name == "Charge" then
		-- Charge doesn't deal damage but generates free rage
		-- Value = rage gained converted to damage potential
		-- Rough estimate: rage * damage_per_rage (from Execute formula)
		-- 1 rage = ~15 damage via Execute, but much less normally
		-- Conservative: value as the AP-equivalent of having that rage for BT/WW
		local rageGain = action.rageGain or 9
		-- Value each rage point at ~5 damage (conservative estimate)
		-- This makes Charge worth ~45-75 "damage" for priority calculation
		damage = rageGain * 5
		canCrit = false

	elseif action.name == "BattleShout" then
		-- Battle Shout doesn't deal direct damage, but its AP boost
		-- is valuable. Calculate the AP benefit over the fight:
		-- ~232 AP for 2 minutes = significant damage increase
		-- Estimate: 232 AP * 0.35 (BT coeff) * ~10 BT casts = ~800 damage value
		-- But this is spread over time, so divide by horizon
		local bsAP = ATW.GetBattleShoutAP and ATW.GetBattleShoutAP() or 232
		local horizonSec = Engine.GetHorizon() / 1000
		local gcdsInHorizon = horizonSec / 1.5
		-- Rough value: AP bonus * ability coefficient * casts
		damage = bsAP * 0.35 * gcdsInHorizon * 0.5  -- Conservative estimate
		canCrit = false

	elseif action.name == "Rend" then
		-- Rend DoT - cannot crit
		-- Calculate damage based on TARGET-SPECIFIC TTD if available
		-- TurtleWoW: 147 base / 7 ticks = 21 per tick (without talents)
		local tickDamage = ATW.GetRendTickDamage and ATW.GetRendTickDamage() or 21
		local maxTicks = ATW.GetRendTicks and ATW.GetRendTicks() or 7
		local apPerTick = ap * 0.05
		local tickTotal = tickDamage + apPerTick

		-- Use target-specific TTD if this is a multi-target Rend action
		local targetTTD = action.targetTTD or state.targetTTD or 30000
		local remainingTTD = targetTTD - (state.time or 0)
		if remainingTTD < 0 then remainingTTD = 0 end
		local tickInterval = 3000  -- 3 seconds per tick
		local ticksFromTTD = math.floor(remainingTTD / tickInterval)
		local numTicks = math.min(maxTicks, ticksFromTTD)
		if numTicks < 0 then numTicks = 0 end

		damage = tickTotal * numTicks

		-- Small bonus for main target (tiebreaker when damage is similar)
		-- This prioritizes keeping Rend on your focus target
		if action.isMainTarget then
			damage = damage * 1.05  -- 5% bonus for main target
		end

		canCrit = false  -- DoTs don't crit in vanilla

	elseif action.name == "HeroicStrike" then
		-- HS is "on next swing" - NO immediate damage
		-- Damage is counted in EstimateAutoAttackDamage when swing lands
		-- Returning damage here would double-count it
		damage = 0
		canCrit = false

	elseif action.name == "Cleave" then
		-- Cleave is "on next swing" - NO immediate damage
		-- Damage is counted in EstimateAutoAttackDamage when swing lands
		-- Returning damage here would double-count it
		damage = 0
		canCrit = false

	elseif action.name == "Wait" then
		damage = 0
		canCrit = false

	---------------------------------------
	-- BUFF/UTILITY ABILITIES
	-- These don't deal direct damage but have strategic value
	---------------------------------------
	elseif action.name == "Bloodrage" then
		-- Bloodrage generates rage (20 total: 10 instant + 10 over time)
		-- TurtleWoW (Nov 2024): Can proc Enrage (+15% dmg for 8s) based on crit chance
		-- Value = rage generated * expected damage per rage
		local rageGen = 20
		local avgDmgPerRage = 25  -- Rough estimate

		-- Add expected value from Enrage proc (critChance * enrageBenefit)
		local enrageValue = 0
		if ATW.Talents and ATW.Talents.Enrage and ATW.Talents.Enrage > 0 then
			local critChance = Engine.GetCritChance(state) / 100
			-- Very rough estimate: 8s of +15% damage on ~4 abilities = ~1500 extra damage
			enrageValue = critChance * 1500
		end

		damage = (rageGen * avgDmgPerRage * 0.3) + (enrageValue * 0.5)  -- Discounted
		canCrit = false

	elseif action.name == "BerserkerRage" then
		-- Berserker Rage: fear immunity + extra rage from damage taken
		-- Strategic value but no direct damage
		damage = 50  -- Small value to not be ignored
		canCrit = false

	elseif action.name == "DeathWish" then
		-- Death Wish: +20% damage for 30s
		-- Value = expected damage increase over duration
		local horizonSec = Engine.GetHorizon() / 1000
		local avgDmgPerSec = 500  -- Rough estimate
		damage = avgDmgPerSec * horizonSec * 0.20 * 0.5  -- 20% increase, discounted
		canCrit = false

	elseif action.name == "Recklessness" then
		-- Recklessness: +100% crit for 15s
		-- Massive DPS increase - high value
		local horizonSec = math.min(15, Engine.GetHorizon() / 1000)
		local avgDmgPerSec = 500
		-- Estimate: doubles crit rate, crit does 2x damage, so ~50% more damage
		damage = avgDmgPerSec * horizonSec * 0.50 * 0.5  -- 50% increase, discounted
		canCrit = false

	elseif action.name == "SweepingStrikes" then
		-- Sweeping Strikes: next 5 attacks hit additional target
		-- Value depends on number of targets
		local numTargets = state.enemyCountMelee or 1
		if numTargets >= 2 then
			local avgWeaponDmg = (state.mhDmgMin + state.mhDmgMax) / 2
			-- 5 extra hits on secondary target
			damage = avgWeaponDmg * 5 * 0.5  -- Discounted
		else
			damage = 0
		end
		canCrit = false

	elseif action.name == "Pummel" then
		-- Pummel: interrupt + small damage (5% AP in TurtleWoW)
		damage = ap * 0.05
		-- Interrupt value is strategic, not damage-based
		-- Add bonus value when interrupt is needed
		if state.shouldInterrupt then
			damage = damage + 500  -- High priority when needed
		end

	---------------------------------------
	-- RACIAL ABILITIES (damage value estimation)
	---------------------------------------
	elseif action.name == "BloodFury" then
		-- Blood Fury: +AP = level*2 for 15s
		-- Value = estimated damage increase from extra AP over duration
		local apBonus = ATW.GetBloodFuryAP and ATW.GetBloodFuryAP() or 120
		local horizonSec = math.min(15, Engine.GetHorizon() / 1000)
		-- AP to DPS conversion: ~1 DPS per 14 AP (rough estimate)
		local dpsIncrease = apBonus / 14
		damage = dpsIncrease * horizonSec * 0.8  -- High priority - it's free (off GCD, no rage)
		canCrit = false

	elseif action.name == "Berserking" then
		-- Berserking: 10-15% haste for 10s
		-- Value = more auto attacks = more rage + more damage
		local hasteBonus = ATW.GetBerserkingHaste and ATW.GetBerserkingHaste() or 10
		local horizonSec = math.min(10, Engine.GetHorizon() / 1000)
		local avgDmgPerSec = 400
		-- Haste increases auto attack DPS by hasteBonus%
		damage = avgDmgPerSec * horizonSec * (hasteBonus / 100) * 0.7
		canCrit = false

	elseif action.name == "Perception" then
		-- Perception: +2% crit for 20s (TurtleWoW Human racial)
		-- Value = estimated damage increase from crit bonus
		local horizonSec = math.min(20, Engine.GetHorizon() / 1000)
		local avgDmgPerSec = 400
		-- 2% more crits, crits do 2x damage, so ~2% more damage
		damage = avgDmgPerSec * horizonSec * 0.02 * 0.9  -- High priority - free buff
		canCrit = false
	end

	-- Apply crit expected value (for abilities that can crit)
	if canCrit and damage > 0 then
		damage = damage * critExpectedMult
	end

	-- Apply damage modifiers (Enrage, Death Wish, Recklessness)
	local dmgMod = 1.0
	if state.buffs.Enrage or state.hasEnrage then dmgMod = dmgMod * 1.15 end
	if state.buffs.DeathWish or state.hasDeathWish then dmgMod = dmgMod * 1.20 end
	-- Recklessness doesn't increase damage directly, it increases crit

	-- Two-Handed Weapon Specialization: TurtleWoW 3 points, +2/4/6% with 2H
	if not state.hasOH then
		local twoHandSpec = ATW.Talents and ATW.Talents.TwoHandSpec or 0
		if twoHandSpec > 0 then
			dmgMod = dmgMod * (1 + twoHandSpec * 0.02)
		end
	end

	-- Defensive Stance: -10% damage dealt
	if state.stance == 2 then
		dmgMod = dmgMod * 0.90
	end

	-- Sweeping Strikes: add SS damage bonus for single-target melee abilities
	-- (Cleave and WW already handle multi-target, Rend doesn't trigger SS)
	if damage > 0 and state.sweepingCharges and state.sweepingCharges > 0 then
		local ssAbilities = {
			Bloodthirst = true,
			MortalStrike = true,
			Overpower = true,
			Execute = true,
			Slam = true,
			HeroicStrike = true,
		}
		if ssAbilities[action.name] and (state.enemyCountMelee or 1) >= 2 then
			-- SS duplicates damage to secondary target
			damage = damage * 2
		end
	end

	return damage * dmgMod
end

---------------------------------------
-- Apply action to state, returning new state
---------------------------------------
function Engine.ApplyAction(state, action)
	local newState = Engine.DeepCopyState(state)
	local gcd = Engine.DECISION_GCD

	---------------------------------------
	-- STANCE SWITCH ACTIONS (explicit actions now)
	---------------------------------------
	if action.isStanceSwitch then
		-- Tactical Mastery: rage retained on stance switch (0/5/10/15/20/25)
		local tm = newState.tacticalMastery or (ATW.Talents and ATW.Talents.TM) or 0
		-- TM cap: lose rage above TM when switching
		if newState.rage > tm then
			newState.rage = tm
		end
		-- Change stance
		newState.stance = action.targetStance
		-- Stance internal CD (1.5s)
		newState.stanceGcdEnd = 1500
		-- Stance switch does NOT consume ability GCD
		-- But it counts as a "decision" - advance time slightly to prevent infinite loops
		newState.time = (newState.time or 0) + 100  -- 0.1s token advance
		return newState
	end

	-- Pay rage cost
	newState.rage = newState.rage - action.rage

	-- Apply ability-specific effects
	-- NOTE: Most offensive abilities set inCombat = true to prevent Charge after use
	if action.name == "Execute" then
		-- Execute consumes ALL rage (base cost already paid above)
		-- The excess rage was converted to damage in GetActionDamage
		-- TurtleWoW current: no Execute cooldown; Improved Execute reduces cost
		newState.rage = 0
		newState.inCombat = true

	elseif action.name == "Bloodthirst" then
		newState.cooldowns.Bloodthirst = 6000  -- 6s CD
		newState.inCombat = true

	elseif action.name == "MortalStrike" then
		newState.cooldowns.MortalStrike = 6000
		newState.inCombat = true

	elseif action.name == "Whirlwind" then
		-- TurtleWoW 1.17.2: Improved Whirlwind reduces CD by 1/1.5/2s
		local wwCD = ATW.GetAbilityCooldown and ATW.GetAbilityCooldown("Whirlwind") or 10
		newState.cooldowns.Whirlwind = wwCD * 1000
		newState.inCombat = true

	elseif action.name == "Overpower" then
		newState.cooldowns.Overpower = 5000
		newState.overpowerReady = false
		newState.overpowerEnd = 0
		newState.inCombat = true

	elseif action.name == "Slam" then
		-- TurtleWoW Slam pauses the weapon swing timer instead of resetting it.
		-- This tactical model advances time by the GCD without wiping swing progress.
		newState.inCombat = true

	elseif action.name == "Charge" then
		-- Charge enters combat and generates rage
		newState.inCombat = true  -- Now in combat - Charge becomes unavailable
		newState.cooldowns.Charge = 15000  -- 15s CD
		-- Add rage gain (already calculated in action)
		local rageGain = action.rageGain or 9
		newState.rage = math.min(100, newState.rage + rageGain)

		-- TRAVEL TIME: Calculate time to reach melee range
		-- Charge speed = 28 yards/second (from TrinityCore research)
		-- Travel time = distance / speed (converted to milliseconds)
		local distance = newState.targetDistance or 15  -- Default to mid-range
		local travelTimeMs = (distance / Engine.CHARGE_SPEED) * 1000
		newState.timeToMelee = travelTimeMs
		newState.inMeleeRange = false  -- Not in melee yet, traveling

	elseif action.name == "BattleShout" then
		newState.hasBattleShout = true
		-- AP will be added in GetActionDamage for subsequent abilities

	elseif action.name == "Rend" then
		-- MULTI-TARGET REND: Update specific enemy's state if targetGUID provided
		local rendDur = (ATW.RendDuration and ATW.RendDuration > 0) and ATW.RendDuration or 22
		local rendDuration = rendDur * 1000
		newState.inCombat = true

		if action.targetGUID and newState.enemies then
			-- Find and update the specific enemy
			for _, enemy in ipairs(newState.enemies) do
				if enemy.guid == action.targetGUID then
					enemy.hasRend = true
					enemy.rendRemaining = rendDuration
					-- Also update main target state if this is the main target
					if enemy.isTarget then
						newState.rendOnTarget = true
						newState.rendRemaining = rendDuration
					end
					break
				end
			end
		else
			-- Fallback: Single target mode
			newState.rendOnTarget = true
			newState.rendRemaining = rendDuration
		end

	---------------------------------------
	-- BUFF/UTILITY ABILITY EFFECTS
	---------------------------------------
	elseif action.name == "Bloodrage" then
		newState.cooldowns.Bloodrage = 60000  -- 60s CD
		newState.hasBloodrageActive = true
		newState.inCombat = true  -- Bloodrage ENTERS COMBAT - blocks Charge!

		-- TurtleWoW (Nov 2024): Bloodrage self-damage can crit and proc Enrage
		-- Chance = player's physical crit chance
		if ATW.Talents and ATW.Talents.Enrage and ATW.Talents.Enrage > 0 then
			local critChance = Engine.GetCritChance(newState) / 100
			if math.random() < critChance then
				newState.hasEnrage = true
			end
		end

		-- Generate instant rage (10 instant, 10 over time handled by rage gen)
		newState.rage = math.min(100, newState.rage + 10)

	elseif action.name == "BerserkerRage" then
		newState.cooldowns.BerserkerRage = 30000  -- 30s CD
		newState.hasBerserkerRage = true

	elseif action.name == "DeathWish" then
		newState.cooldowns.DeathWish = 180000  -- 3 min CD
		newState.hasDeathWish = true

	elseif action.name == "Recklessness" then
		newState.cooldowns.Recklessness = 1800000  -- 30 min CD
		newState.hasRecklessness = true

	elseif action.name == "SweepingStrikes" then
		newState.cooldowns.SweepingStrikes = 30000  -- 30s CD
		newState.hasSweepingStrikes = true
		newState.sweepingCharges = 5  -- 5 charges
		newState.inCombat = true

	elseif action.name == "Pummel" then
		newState.cooldowns.Pummel = 10000  -- 10s CD
		newState.shouldInterrupt = false  -- Interrupt consumed
		newState.inCombat = true

	---------------------------------------
	-- RACIAL ABILITY EFFECTS
	---------------------------------------
	elseif action.name == "BloodFury" then
		newState.cooldowns.BloodFury = 120000  -- 2 min CD
		newState.hasBloodFury = true
		newState.buffs.BloodFury = {
			endTime = (newState.time or 0) + Engine.BUFF_DURATIONS.BloodFury,
			stacks = 1,
		}
		-- AP bonus will be applied through buff effects
		newState.inCombat = true

	elseif action.name == "Berserking" then
		newState.cooldowns.Berserking = 180000  -- 3 min CD
		newState.hasBerserking = true
		newState.buffs.Berserking = {
			endTime = (newState.time or 0) + Engine.BUFF_DURATIONS.Berserking,
			stacks = 1,
		}
		newState.inCombat = true

	elseif action.name == "Perception" then
		newState.cooldowns.Perception = 180000  -- 3 min CD
		newState.hasPerception = true
		newState.buffs.Perception = {
			endTime = (newState.time or 0) + Engine.BUFF_DURATIONS.Perception,
			stacks = 1,
		}
		-- Crit bonus applied through GetCritChance()

	---------------------------------------
	-- SWING QUEUE ABILITIES (HS/Cleave)
	-- These queue on next melee swing, not instant damage
	---------------------------------------
	elseif action.name == "HeroicStrike" then
		newState.swingQueued = "hs"
		-- Note: Rage is paid when queued (already subtracted above)
		-- Damage happens when swing lands (handled by ProcessAutoAttack)

	elseif action.name == "Cleave" then
		newState.swingQueued = "cleave"
		-- Note: Rage is paid when queued (already subtracted above)
	end

	-- Consume Sweeping Strikes charge for melee abilities (not WW/Cleave/Rend)
	if newState.sweepingCharges and newState.sweepingCharges > 0 then
		local ssAbilities = {
			Bloodthirst = true,
			MortalStrike = true,
			Overpower = true,
			Execute = true,
			Slam = true,
			HeroicStrike = true,
		}
		if ssAbilities[action.name] and (newState.enemyCountMelee or 1) >= 2 then
			newState.sweepingCharges = newState.sweepingCharges - 1
			if newState.sweepingCharges <= 0 then
				newState.hasSweepingStrikes = false
			end
		end
	end

	-- Advance time (except for off-GCD abilities)
	if not action.offGCD then
		newState.time = (newState.time or 0) + gcd

		-- Advance cooldowns
		for cd, remaining in pairs(newState.cooldowns) do
			if remaining > 0 then
				newState.cooldowns[cd] = math.max(0, remaining - gcd)
			end
		end

		-- Advance travel time (after Charge) - once we arrive, we're in melee
		if newState.timeToMelee and newState.timeToMelee > 0 then
			newState.timeToMelee = math.max(0, newState.timeToMelee - gcd)
			if newState.timeToMelee <= 0 then
				newState.inMeleeRange = true  -- Arrived at target!
				newState.targetDistance = 0   -- Now at melee range
			end
		end

		-- Decay Overpower window
		if newState.overpowerEnd > 0 then
			newState.overpowerEnd = math.max(0, newState.overpowerEnd - gcd)
			if newState.overpowerEnd <= 0 then
				newState.overpowerReady = false
			end
		end

		-- Decay Rend on MAIN target (backwards compatibility)
		if newState.rendRemaining > 0 then
			newState.rendRemaining = math.max(0, newState.rendRemaining - gcd)
			if newState.rendRemaining <= 0 then
				newState.rendOnTarget = false
			end
		end

		-- Decay Rend on ALL tracked enemies
		if newState.enemies then
			for _, enemy in ipairs(newState.enemies) do
				if enemy.rendRemaining > 0 then
					enemy.rendRemaining = math.max(0, enemy.rendRemaining - gcd)
					if enemy.rendRemaining <= 0 then
						enemy.hasRend = false
					end
				end
				-- Also decay enemy HP based on their individual TTD
				if enemy.ttd > 0 then
					local hpDecay = (gcd / enemy.ttd) * 100
					enemy.hpPercent = math.max(0, enemy.hpPercent - hpDecay)
					enemy.inExecute = enemy.hpPercent < 20
				end
			end
		end

		-- Generate rage from auto-attacks (rough estimate)
		-- ~15 rage per 1.5s GCD from dual wield auto-attacks
		-- NOTE: Only generate rage if actually in melee range
		if newState.inMeleeRange then
			local ragePerGCD = 15
			if not newState.hasOH then
				ragePerGCD = 10  -- Less rage with 2H
			end
			newState.rage = math.min(100, newState.rage + ragePerGCD)
		end

		-- Decay target HP (main target)
		if newState.targetTTD > 0 then
			local hpDecay = (gcd / newState.targetTTD) * 100
			newState.targetHPPercent = math.max(0, newState.targetHPPercent - hpDecay)
		end
	end

	return newState
end

---------------------------------------
-- Simulate N milliseconds with forced first action
-- Uses greedy selection for subsequent actions
-- Returns total damage dealt
---------------------------------------
function Engine.SimulateDecisionHorizon(state, firstAction, horizon)
	local simState = Engine.DeepCopyState(state)
	local totalDamage = 0
	local gcd = Engine.DECISION_GCD
	local timeElapsed = 0

	-- Execute first action
	local damage = Engine.GetActionDamage(simState, firstAction)
	totalDamage = totalDamage + damage
	simState = Engine.ApplyAction(simState, firstAction)

	---------------------------------------
	-- CRITICAL: Include auto-attack damage over horizon
	-- This is calculated AFTER applying the first action so that
	-- HeroicStrike/Cleave queueing is properly reflected in swingQueued
	--
	-- SPECIAL CASE: If we're not in melee after first action but Charge
	-- is available (in Battle Stance, at Charge range), we need to account
	-- for the fact that we'll Charge and then have auto-attacks.
	---------------------------------------
	local autoState = simState
	local chargeSimulated = false

	if not simState.inMeleeRange and (simState.timeToMelee or 0) == 0 then
		-- We're not in melee and haven't Charged yet
		-- Check if Charge is available in current state (after first action)
		if not simState.inCombat and simState.stance == 1 then
			local chargeReady = (simState.cooldowns.Charge or 0) <= 0

			-- Be lenient with Charge range check - if no distance data, assume we can Charge
			local canCharge = chargeReady
			if simState.targetDistance then
				-- If we have distance data, verify we're in range
				canCharge = chargeReady and
					simState.targetDistance >= Engine.CHARGE_MIN_RANGE and
					simState.targetDistance <= Engine.CHARGE_MAX_RANGE
			end

			if canCharge then
				-- Charge is available - create modified state for auto-attack estimation
				autoState = Engine.DeepCopyState(simState)
				-- After Charge GCD (1500ms), we arrive (travel < GCD always)
				autoState.inMeleeRange = true
				autoState.timeToMelee = 0
				autoState.inCombat = true
				chargeSimulated = true
			end
		end
	end

	local autoDamage = Engine.EstimateAutoAttackDamage(autoState, horizon)
	totalDamage = totalDamage + autoDamage

	if not firstAction.offGCD then
		timeElapsed = timeElapsed + gcd
	end

	-- Simulate remaining time with greedy best action
	while timeElapsed < horizon do
		-- Get valid actions for current state
		local actions = Engine.GetValidActions(simState)

		-- Find best action (greedy by immediate damage)
		local bestAction = nil
		local bestDamage = -1

		for _, action in ipairs(actions) do
			local dmg = Engine.GetActionDamage(simState, action)
			if dmg > bestDamage then
				bestDamage = dmg
				bestAction = action
			end
		end

		if not bestAction then
			break
		end

		-- Execute greedy action
		totalDamage = totalDamage + bestDamage
		simState = Engine.ApplyAction(simState, bestAction)

		if not bestAction.offGCD then
			timeElapsed = timeElapsed + gcd
		else
			-- Prevent infinite loop on off-GCD spam
			timeElapsed = timeElapsed + 100
		end
	end

	return totalDamage
end

---------------------------------------
-- Calculate auto-attack damage over a time horizon using REAL swing timers
-- Uses state.mhTimer/ohTimer (time until next swing) for precise calculations
-- Includes HS/Cleave bonus on first MH swing if queued
-- TRAVEL TIME: If not in melee, no auto-attacks until arrival
---------------------------------------
function Engine.EstimateAutoAttackDamage(state, horizon)
	local damage = 0
	local timeToMelee = state.timeToMelee or 0

	---------------------------------------
	-- MELEE RANGE CHECK: No auto-attacks if not in melee range
	-- Two scenarios:
	-- 1. At Charge range, haven't Charged yet (timeToMelee = 0) -> NO auto-attacks
	-- 2. Just Charged, traveling (timeToMelee > 0) -> reduce horizon by travel time
	---------------------------------------
	if not state.inMeleeRange then
		if timeToMelee > 0 then
			-- Traveling after Charge - reduce horizon by travel time
			horizon = horizon - timeToMelee
			if horizon <= 0 then
				return 0  -- Entire horizon is spent traveling
			end
			-- After travel time, we'll be in melee - continue calculation
		else
			-- NOT in melee and NOT traveling = can't auto-attack at all!
			-- This happens when we're at Charge range but haven't Charged yet
			return 0
		end
	end

	-- Safety checks for nil values
	local mhDmgMin = state.mhDmgMin or 100
	local mhDmgMax = state.mhDmgMax or 200
	local ohDmgMin = state.ohDmgMin or 50
	local ohDmgMax = state.ohDmgMax or 100
	local mhSpeedMs = state.mhSpeed or 2600
	local ohSpeedMs = state.ohSpeed or 2600

	-- Average weapon damage
	local mhAvg = (mhDmgMin + mhDmgMax) / 2
	local ohAvg = state.hasOH and ((ohDmgMin + ohDmgMax) / 2) or 0

	-- Haste modifier
	local hasteMod = Engine.GetHasteMod(state) or 1
	if hasteMod <= 0 then hasteMod = 1 end

	-- Effective weapon speeds with haste (in ms)
	local mhSpeed = mhSpeedMs / hasteMod
	local ohSpeed = state.hasOH and (ohSpeedMs / hasteMod) or 999999

	---------------------------------------
	-- REAL SWING TIMERS from game state
	-- mhTimer/ohTimer = time until next swing (in ms)
	-- If 0 or nil, swing just happened, next is at full speed
	-- NOTE: After arrival from Charge, swing timer starts fresh
	---------------------------------------
	local mhTimer = state.mhTimer or 0
	local ohTimer = state.ohTimer or 0

	-- If traveling, swing timers reset to full after arrival
	if timeToMelee > 0 then
		mhTimer = mhSpeed
		ohTimer = ohSpeed
	end

	-- If timer is 0 or very small, next swing is at full swing speed
	if mhTimer <= 0 then mhTimer = mhSpeed end
	if ohTimer <= 0 then ohTimer = ohSpeed end

	-- Damage modifiers
	local damageMod = Engine.GetDamageMod(state) or 1

	-- Crit calculation
	local critChance = (Engine.GetCritChance(state, nil) or 20) / 100
	local impale = ATW.Talents and ATW.Talents.Impale or 0
	local critMod = 2.0 + (impale / 100)
	local critMultiplier = 1 + (critChance * (critMod - 1))

	---------------------------------------
	-- MAIN HAND SWINGS using real timer
	-- First swing at mhTimer, subsequent at mhTimer + n*mhSpeed
	---------------------------------------
	local mhTime = mhTimer
	local firstMHSwing = true

	while mhTime <= horizon do
		local swingDamage = mhAvg * damageMod * critMultiplier

		-- FIRST MH swing gets HS/Cleave bonus if queued
		if firstMHSwing and state.swingQueued then
			if state.swingQueued == "hs" then
				local swingBonus = ATW.GetHeroicStrikeBonus and ATW.GetHeroicStrikeBonus() or Engine.HS_BONUS or 157
				local hsCritChance = (Engine.GetCritChance(state, "HeroicStrike") or 20) / 100
				local hsCritMult = 1 + (hsCritChance * (critMod - 1))
				swingDamage = (mhAvg + swingBonus) * damageMod * hsCritMult
			elseif state.swingQueued == "cleave" then
				local swingBonus = ATW.GetCleaveBonus and ATW.GetCleaveBonus() or Engine.CLEAVE_BONUS or 50
				local enemyCount = state.enemyCountMelee or state.enemyCount or 1
				local targets = math.min(enemyCount, 2)
				if targets < 1 then targets = 1 end
				local hsCritChance = (Engine.GetCritChance(state, "Cleave") or 20) / 100
				local hsCritMult = 1 + (hsCritChance * (critMod - 1))
				swingDamage = (mhAvg + swingBonus) * targets * damageMod * hsCritMult
			end
		end

		firstMHSwing = false
		damage = damage + swingDamage
		mhTime = mhTime + mhSpeed
	end

	---------------------------------------
	-- OFF HAND SWINGS using real timer (if dual-wield)
	-- OH does 50% damage, no HS/Cleave
	---------------------------------------
	if state.hasOH then
		local ohTime = ohTimer

		while ohTime <= horizon do
			local swingDamage = ohAvg * damageMod * critMultiplier * 0.5
			damage = damage + swingDamage
			ohTime = ohTime + ohSpeed
		end
	end

	return damage
end

---------------------------------------
-- Main decision function: Single-layer tactical simulation
-- 1. Check for interrupt priority
-- 2. Use cached result if state unchanged
-- 3. Simulate all valid actions over 9s horizon
-- 4. Pick highest damage action
---------------------------------------
function Engine.GetBestAction()
	local state = Engine.CaptureCurrentState()

	---------------------------------------
	-- INTERRUPT LAYER: Absolute priority for interrupts
	-- Pummel MUST happen immediately when enemy is casting
	-- No caching, no simulation - just do it
	---------------------------------------
	if state.shouldInterrupt then
		local actions = Engine.GetValidActions(state)
		for _, action in ipairs(actions) do
			if action.isInterrupt then
				-- Return immediately with max priority
				local results = {{
					name = action.name,
					damage = 999999,
					targetGUID = action.targetGUID,
					interrupt = true,
				}}
				Engine.lastDecisionResults = results
				Engine.lastBestAction = action
				return action, 999999, results
			end
		end
	end

	---------------------------------------
	-- CACHING: Return cached result if state hasn't changed significantly
	---------------------------------------
	if Engine.CacheValid(state) then
		local cached = Engine.GetCachedResult()
		if cached then
			return cached.bestAction, cached.bestDamage, cached.results
		end
	end

	---------------------------------------
	-- TACTICAL LAYER: Simulate valid actions
	-- Cooldowns are controlled via manual toggles (BurstEnabled/RecklessEnabled)
	-- CD sync handled in GetValidActions via shouldWaitForDWSync()
	---------------------------------------
	local actions = Engine.GetValidActions(state)
	local horizon = Engine.GetHorizon()

	local bestAction = nil
	local bestDamage = -1
	local results = {}

	for _, action in ipairs(actions) do
		local totalDamage = Engine.SimulateDecisionHorizon(state, action, horizon)

		-- Store result for debugging
		table.insert(results, {
			name = action.name,
			damage = totalDamage,
			isStanceSwitch = action.isStanceSwitch,
			targetGUID = action.targetGUID,
			targetHP = action.targetHP,
		})

		if totalDamage > bestDamage then
			bestDamage = totalDamage
			bestAction = action
		end
	end

	---------------------------------------
	-- Store results and update cache
	---------------------------------------
	Engine.lastDecisionResults = results
	Engine.lastBestAction = bestAction

	-- Update cache
	Engine.UpdateCache(state, {
		bestAction = bestAction,
		bestDamage = bestDamage,
		results = results,
	})

	return bestAction, bestDamage, results
end

---------------------------------------
-- NEW GetRecommendation using simulator
-- Returns: abilityName (internal), isOffGCD, pooling, timeToExecute, targetGUID, targetStance
---------------------------------------
function Engine.GetRecommendationSimBased()
	local bestAction, bestDamage, results = Engine.GetBestAction()

	if not bestAction or bestAction.name == "Wait" then
		return nil, false, false, 0, nil, nil, false
	end

	-- For multi-target Rend, return the specific targetGUID
	local targetGUID = bestAction.targetGUID or nil

	-- Stance switch actions have targetStance set
	local targetStance = bestAction.targetStance or nil

	-- Return INTERNAL name (e.g., "BattleShout" not "Battle Shout")
	-- isStanceSwitch tells Rotation.lua to use CastShapeshiftForm instead
	return bestAction.name, bestAction.offGCD or false, false, 0, targetGUID, targetStance, bestAction.isStanceSwitch or false
end

---------------------------------------
-- Debug: Print decision comparison
---------------------------------------
function Engine.PrintDecisionDebug()
	local bestAction, bestDamage, results = Engine.GetBestAction()

	ATW.Print("=== Decision Simulator ===")
	ATW.Print("Horizon: " .. (Engine.GetHorizon() / 1000) .. "s")
	ATW.Print("")

	-- Sort by damage descending
	table.sort(results, function(a, b) return a.damage > b.damage end)

	ATW.Print("Action comparison:")
	for _, r in ipairs(results) do
		local marker = ""
		if bestAction and r.name == bestAction.name then
			marker = " |cff00ff00<< BEST|r"
		end
		local stanceStr = r.isStanceSwitch and " (stance)" or ""
		local targetStr = r.targetGUID and " [GUID]" or ""
		ATW.Print("  " .. r.name .. stanceStr .. targetStr .. ": " ..
			string.format("%.0f", r.damage) .. " dmg" .. marker)
	end

	-- Show current state info
	local state = Engine.CaptureCurrentState()
	ATW.Print("")
	ATW.Print("Current state:")
	ATW.Print("  Rage: " .. state.rage)
	ATW.Print("  Stance: " .. state.stance .. " (" .. ({[1]="Battle",[2]="Def",[3]="Berserker"})[state.stance] .. ")")
	ATW.Print("  In Combat: " .. (state.inCombat and "YES" or "NO"))
	ATW.Print("  In Melee Range: " .. (state.inMeleeRange and "YES" or "NO"))
	ATW.Print("  Target Distance: " .. (state.targetDistance and string.format("%.1f", state.targetDistance) .. " yd" or "UNKNOWN"))
	ATW.Print("  Time To Melee: " .. (state.timeToMelee or 0) .. " ms")

	-- Charge availability
	local chargeReady = (state.cooldowns.Charge or 0) <= 0
	local inChargeRange = state.targetDistance and
		state.targetDistance >= Engine.CHARGE_MIN_RANGE and
		state.targetDistance <= Engine.CHARGE_MAX_RANGE
	ATW.Print("  Charge Ready: " .. (chargeReady and "YES" or "NO"))
	ATW.Print("  In Charge Range: " .. (inChargeRange and "YES" or (state.targetDistance and "NO" or "UNKNOWN")))

	ATW.Print("")
	ATW.Print("  Battle Shout: " .. (state.hasBattleShout and "YES" or "NO"))
	ATW.Print("  Rend (target): " .. (state.rendOnTarget and "YES" or "NO"))
	ATW.Print("  Overpower: " .. (state.overpowerReady and ("YES (" .. string.format("%.1f", state.overpowerEnd/1000) .. "s)") or "NO"))
	ATW.Print("  Target HP: " .. string.format("%.1f", state.targetHPPercent) .. "%")

	-- Multi-target info
	if state.enemies and table.getn(state.enemies) > 0 then
		ATW.Print("")
		ATW.Print("Multi-target (" .. state.enemyCount .. " enemies):")
		ATW.Print("  Melee range (5yd): " .. (state.enemyCountMelee or 0))
		ATW.Print("  WW range (8yd): " .. (state.enemyCountWW or 0))

		local rendedCount = 0
		local needsRendCount = 0
		for _, enemy in ipairs(state.enemies) do
			if enemy.hasRend then
				rendedCount = rendedCount + 1
			elseif not enemy.bleedImmune and not enemy.inExecute and enemy.hpPercent >= 30 then
				needsRendCount = needsRendCount + 1
			end
		end
		ATW.Print("  Rended: " .. rendedCount .. "/" .. state.enemyCount)
		ATW.Print("  Needs Rend: " .. needsRendCount)
	end
end

---------------------------------------
-- Get simulation timeline for UI display
-- Returns array of {name, time, damage, isStanceSwitch, isOffGCD, isAutoAttack, isMH, isOH}
-- Shows the predicted sequence of abilities AND auto-attacks over the horizon
---------------------------------------
function Engine.GetSimulationTimeline(maxSteps, timelineHorizon)
	maxSteps = maxSteps or 15
	timelineHorizon = timelineHorizon or 10000  -- 10 seconds default for UI

	local state = Engine.CaptureCurrentState()
	if not state then return {} end

	-- Get best first action (may be nil if pooling/waiting)
	local bestAction, bestDamage, results = Engine.GetBestAction()

	-- Even if no ability is available, we should still show auto-attacks
	-- This handles Execute phase when pooling rage, GCD lockout, etc.
	local hasFirstAction = bestAction ~= nil and bestAction.name ~= "Wait"

	-- Now simulate the best path and collect all actions + auto-attacks
	local timeline = {}
	local simState = Engine.DeepCopyState(state)
	local gcd = Engine.DECISION_GCD
	local timeElapsed = 0

	-- Track swing timers for auto-attack prediction
	local mhTimer = simState.mhTimer or 0
	local ohTimer = simState.ohTimer or 0
	local mhSpeed = simState.mhSpeed or 2500
	local ohSpeed = simState.ohSpeed or 2500
	local isDW = simState.isDualWield or false

	-- Helper to add auto-attacks up to a certain time
	local function addAutoAttacksUntil(endTime, startTime)
		-- Only add auto-attacks if in melee range
		if not simState.inMeleeRange then return end

		local t = startTime or 0

		-- MH swings
		local nextMH = mhTimer
		while nextMH <= endTime and nextMH <= timelineHorizon do
			if nextMH >= t then
				table.insert(timeline, {
					name = "AutoAttack",
					time = nextMH,
					isAutoAttack = true,
					isMH = true,
					isOH = false,
					swingQueued = simState.swingQueued,
				})
			end
			nextMH = nextMH + mhSpeed
		end
		mhTimer = nextMH

		-- OH swings (if dual wielding)
		if isDW then
			local nextOH = ohTimer
			while nextOH <= endTime and nextOH <= timelineHorizon do
				if nextOH >= t then
					table.insert(timeline, {
						name = "AutoAttackOH",
						time = nextOH,
						isAutoAttack = true,
						isMH = false,
						isOH = true,
					})
				end
				nextOH = nextOH + ohSpeed
			end
			ohTimer = nextOH
		end
	end

	-- Add first action (only if we have one)
	if hasFirstAction then
		table.insert(timeline, {
			name = bestAction.name,
			time = 0,
			damage = Engine.GetActionDamage(simState, bestAction),
			rage = simState.rage,  -- Current rage before action
			isStanceSwitch = bestAction.isStanceSwitch or false,
			isOffGCD = bestAction.offGCD or false,
			targetStance = bestAction.targetStance,
			isAutoAttack = false,
		})

		-- Apply first action
		simState = Engine.ApplyAction(simState, bestAction)

		local actionTime = 0
		if not bestAction.offGCD then
			actionTime = gcd
		else
			actionTime = 100
		end
		timeElapsed = timeElapsed + actionTime
	end

	-- Continue with greedy simulation
	-- KEY: When no ability available (pooling rage), still advance time and let rage accumulate
	local steps = 1
	local consecutiveWaits = 0  -- Prevent infinite loop if stuck
	local MAX_CONSECUTIVE_WAITS = 10

	while timeElapsed < timelineHorizon and steps < maxSteps do
		local actions = Engine.GetValidActions(simState)

		-- Find best action (greedy by immediate damage)
		local nextBest = nil
		local nextBestDamage = -1

		if actions and table.getn(actions) > 0 then
			for _, action in ipairs(actions) do
				if action.name ~= "Wait" then
					local dmg = Engine.GetActionDamage(simState, action)
					if dmg > nextBestDamage then
						nextBestDamage = dmg
						nextBest = action
					end
				end
			end
		end

		if nextBest then
			-- Found a valid ability - add to timeline
			consecutiveWaits = 0

			table.insert(timeline, {
				name = nextBest.name,
				time = timeElapsed,
				damage = nextBestDamage,
				rage = simState.rage,  -- Rage before this action
				isStanceSwitch = nextBest.isStanceSwitch or false,
				isOffGCD = nextBest.offGCD or false,
				targetStance = nextBest.targetStance,
				isAutoAttack = false,
			})

			-- Apply action
			simState = Engine.ApplyAction(simState, nextBest)

			if not nextBest.offGCD then
				timeElapsed = timeElapsed + gcd
			else
				timeElapsed = timeElapsed + 100
			end
		else
			-- No ability available - POOL: advance time and let rage accumulate
			consecutiveWaits = consecutiveWaits + 1
			if consecutiveWaits > MAX_CONSECUTIVE_WAITS then
				break  -- Prevent infinite loop
			end

			-- Manually advance state by one GCD (simulating waiting/pooling)
			-- This generates rage from auto-attacks
			simState.time = (simState.time or 0) + gcd
			timeElapsed = timeElapsed + gcd

			-- Generate rage from auto-attacks while waiting
			if simState.inMeleeRange then
				local ragePerGCD = 15
				if not simState.hasOH then
					ragePerGCD = 10  -- Less rage with 2H
				end
				simState.rage = math.min(100, simState.rage + ragePerGCD)
			end

			-- Advance cooldowns while waiting
			for cd, remaining in pairs(simState.cooldowns) do
				if remaining > 0 then
					simState.cooldowns[cd] = math.max(0, remaining - gcd)
				end
			end
		end

		steps = steps + 1
	end

	-- Now add auto-attacks throughout the timeline
	-- Reset timers and recalculate
	mhTimer = state.mhTimer or 0
	ohTimer = state.ohTimer or 0

	-- Only add if we'll be in melee (either already there or after Charge)
	local willBeInMelee = state.inMeleeRange
	local meleeStartTime = 0

	if not willBeInMelee then
		-- Check if Charge is in timeline
		for _, entry in ipairs(timeline) do
			if entry.name == "Charge" then
				willBeInMelee = true
				-- Melee starts after Charge travel time
				local travelTime = 500  -- Default
				if state.targetDistance then
					travelTime = (state.targetDistance / Engine.CHARGE_SPEED) * 1000
				end
				meleeStartTime = entry.time + travelTime
				-- Swing timers reset on arrival
				mhTimer = meleeStartTime
				ohTimer = meleeStartTime + (ohSpeed / 2)  -- OH slightly offset
				break
			end
		end
	end

	if willBeInMelee then
		-- Add MH auto-attacks
		local nextMH = mhTimer
		while nextMH <= timelineHorizon do
			if nextMH >= meleeStartTime then
				table.insert(timeline, {
					name = "AutoAttack",
					time = nextMH,
					isAutoAttack = true,
					isMH = true,
					isOH = false,
				})
			end
			nextMH = nextMH + mhSpeed
		end

		-- Add OH auto-attacks if dual wielding
		if isDW then
			local nextOH = ohTimer
			while nextOH <= timelineHorizon do
				if nextOH >= meleeStartTime then
					table.insert(timeline, {
						name = "AutoAttackOH",
						time = nextOH,
						isAutoAttack = true,
						isMH = false,
						isOH = true,
					})
				end
				nextOH = nextOH + ohSpeed
			end
		end
	end

	-- Sort timeline by time
	table.sort(timeline, function(a, b) return a.time < b.time end)

	return timeline
end

-- Cache for timeline (updated less frequently than main recommendation)
Engine.timelineCache = nil
Engine.timelineCacheTime = 0
Engine.TIMELINE_CACHE_DURATION = 500  -- 500ms cache

---------------------------------------
-- Get cached simulation timeline
---------------------------------------
function Engine.GetCachedTimeline(maxSteps)
	local now = GetTime() * 1000

	-- Check cache validity
	if Engine.timelineCache and (now - Engine.timelineCacheTime) < Engine.TIMELINE_CACHE_DURATION then
		return Engine.timelineCache
	end

	-- Regenerate timeline
	Engine.timelineCache = Engine.GetSimulationTimeline(maxSteps)
	Engine.timelineCacheTime = now

	return Engine.timelineCache
end
