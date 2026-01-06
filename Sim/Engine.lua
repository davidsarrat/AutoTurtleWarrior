--[[
	Auto Turtle Warrior - Sim/Engine
	Complete combat simulation engine
	Based on Zebouski/WarriorSim-TurtleWoW patterns

	Features:
	- Time-step simulation (milliseconds precision)
	- HP tracking per target with execute phase detection
	- Complete buff/aura system with durations
	- Rage generation model (hits, Bloodrage, talents)
	- Cooldown and GCD management
	- Off-GCD ability handling
	- Swing timer tracking with Flurry haste
	- Deep Wounds DoT simulation
	- Execute rage dump optimization
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

-- Unbridled Wrath: 8/16/24/32/40% chance per hit for 1 rage (2 if 2H in Turtle)
-- This is loaded from talents, default is 0 (no talent)
Engine.UNBRIDLED_WRATH_CHANCE = 40  -- Fallback if not loaded from talents

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

-- Whirlwind: normalized speed (constant across ranks)
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

-- Deep Wounds: 60% weapon damage over 12s (4 ticks = 15% per tick)
Engine.DW_PERCENT = 0.60
Engine.DW_TICKS = 4

-- Buff durations (milliseconds)
Engine.BUFF_DURATIONS = {
	Enrage = 12000,         -- 12s (from Bloodrage or taking crits with talent)
	DeathWish = 30000,      -- 30s
	Recklessness = 15000,   -- 15s
	Flurry = 0,             -- 3 charges, not time-based
	BattleShout = 120000,   -- 2 min
	BerserkerRage = 10000,  -- 10s
	Bloodrage = 10000,      -- 10s (generates rage over time)
	SweepingStrikes = 0,    -- 5 charges
	DeepWounds = 12000,     -- 12s DoT
	Rend = 21000,           -- Default 21s DoT (actual duration from ATW.GetRendDuration())
}

-- Buff effects (damage multipliers, etc)
Engine.BUFF_EFFECTS = {
	Enrage = { dmgmod = 1.15 },           -- +15% damage (TurtleWoW)
	DeathWish = { dmgmod = 1.20 },        -- +20% damage
	Recklessness = { critbonus = 100 },   -- +100% crit
	Flurry = { haste = 1.30 },            -- +30% attack speed
	BattleShout = { ap = 232 },           -- +232 AP (Rank 7)
}

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

	return mod
end

---------------------------------------
-- Calculate crit chance with buffs and talents
---------------------------------------
function Engine.GetCritChance(state, isAbility)
	local crit = state.crit or 20

	-- Cruelty talent: +1/2/3/4/5% crit (if not already in base stats)
	-- Note: This may already be included in state.crit from Stats module
	-- Uncomment if not included:
	-- if ATW.Talents and ATW.Talents.Cruelty then
	-- 	crit = crit + ATW.Talents.Cruelty
	-- end

	-- Recklessness
	if state.buffs.Recklessness and state.buffs.Recklessness.endTime > state.time then
		crit = crit + 100
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

	return ap
end

---------------------------------------
-- Calculate haste modifier from Flurry
-- Flurry talent: +10/15/20/25/30% attack speed for 3 swings after crit
---------------------------------------
function Engine.GetHasteMod(state)
	if state.flurryCharges > 0 then
		-- Use talent-loaded Flurry value if available
		local flurryPoints = (ATW.Talents and ATW.Talents.Flurry) or 5
		local hastePercent = flurryPoints * 6  -- 6% per point: 6/12/18/24/30%
		-- TurtleWoW might use different values, adjust as needed
		-- Using 1.30 as the standard 5-point value
		if flurryPoints >= 5 then
			return 1.30
		else
			return 1 + (hastePercent / 100)
		end
	end
	return 1.0
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

	-- Apply damage modifiers from buffs
	finalDamage = finalDamage * Engine.GetDamageMod(state)

	return finalDamage, isCrit
end

---------------------------------------
-- Apply Deep Wounds DoT
---------------------------------------
function Engine.ApplyDeepWounds(state, weaponDamage)
	-- Deep Wounds: 60% of weapon damage over 12 seconds (4 ticks)
	local totalDmg = weaponDamage * 0.60
	local tickDamage = totalDmg / 4

	-- Apply to main target
	if not state.dots.deepwounds then
		state.dots.deepwounds = {}
	end

	state.dots.deepwounds["target"] = {
		endTime = state.time + Engine.BUFF_DURATIONS.DeepWounds,
		nextTick = state.time + 3000,
		tickDamage = tickDamage,
		tickInterval = 3000,
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
			rage = rage + 1
			-- TurtleWoW: 2H weapons get +2 instead of +1
			if not state.hasOH then
				rage = rage + 1
			end
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
			local weaponDmg = Engine.RollWeaponDamage(state, false, true, Engine.WW_NORM_SPEED)
			local targets = math.min(Engine.CountAliveTargets(state), 4)
			damage = weaponDmg * targets

			-- Wrath 5-set bonus: +8% Whirlwind damage
			if state.setEffects and state.setEffects.wrath5 then
				damage = damage * 1.08
			end

		elseif name == "MortalStrike" then
			-- Weapon + bonus + (ap/14) * normSpeed
			local msBonus = ATW.GetMortalStrikeBonus and ATW.GetMortalStrikeBonus() or Engine.MS_BONUS
			damage = Engine.RollWeaponDamage(state, false, true, Engine.WW_NORM_SPEED) + msBonus

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
		-- Enrage effect from Bloodrage
		state.buffs.Enrage = {
			endTime = state.time + Engine.BUFF_DURATIONS.Enrage,
			stacks = 1,
		}
	end

	-- Apply cooldown
	if ability.cd and ability.cd > 0 then
		state.cooldowns[name] = state.time + (ability.cd * 1000)
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

	-- Duration from spell rank (9/12/15/18/21 seconds)
	local duration = ATW.GetRendDuration and ATW.GetRendDuration() or 21
	local durationMs = duration * 1000

	state.dots.rend[targetId] = {
		endTime = state.time + durationMs,
		nextTick = state.time + 3000,
		tickDamage = tickDamage,
		tickInterval = 3000,
	}
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

	state.autoDamage = state.autoDamage + finalDamage
	state.totalDamage = state.totalDamage + finalDamage

	-- Check for Hand of Justice proc (2% chance for extra attack)
	local hojDamage = Engine.CheckTrinketProcs(state, not isOH)
	if hojDamage > 0 then
		state.autoDamage = state.autoDamage + hojDamage
		state.totalDamage = state.totalDamage + hojDamage
		finalDamage = finalDamage + hojDamage
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
	CastSpellByName("Execute")
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
-- True simulation-based decision making
-- Instead of hardcoded priorities, we simulate
-- each possible action and pick the one that
-- maximizes damage over a short horizon
---------------------------------------

-- Configuration
Engine.DECISION_HORIZON = 60000  -- 60 seconds (1 minute lookahead)
Engine.DECISION_GCD = 1500       -- 1.5s GCD

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

	-- Battle Shout status
	state.hasBattleShout = ATW.Buff and ATW.Buff("player", "Ability_Warrior_BattleShout")

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

	-- Enrage buff (from Bloodrage or crits with talent)
	state.hasEnrage = ATW.Buff and ATW.Buff("player", "Spell_Shadow_UnholyFrenzy")

	-- Bloodrage active (DoT on self = generating rage)
	state.hasBloodrageActive = ATW.Buff and ATW.Buff("player", "Ability_Racial_BloodRage")

	---------------------------------------
	-- INTERRUPT STATE (for Pummel)
	---------------------------------------
	state.shouldInterrupt = ATW.State and ATW.State.Interrupt or false

	---------------------------------------
	-- COMBAT STATE (for Charge - only works out of combat)
	---------------------------------------
	state.inCombat = UnitAffectingCombat("player") or false

	---------------------------------------
	-- TARGET DISTANCE (for Charge range check: 8-25 yards)
	---------------------------------------
	state.targetDistance = nil
	if ATW.GetDistance then
		state.targetDistance = ATW.GetDistance("target")
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
				state.rendRemaining = (ATW.GetRendDuration and ATW.GetRendDuration() or 22) * 1000
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
	---------------------------------------
	state.enemies = {}
	state.enemyCount = 0
	state.enemyCountMelee = 0
	state.enemyCountWW = 0

	local targetFoundInList = false

	if ATW.GetEnemiesWithTTD then
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

	return state
end

---------------------------------------
-- Get all valid actions from current state
-- Properly accounts for stance requirements and TM rage cap
-- ONLY includes abilities the player has actually learned
-- Respects GCD - only returns off-GCD abilities when GCD is active
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

	-- Helper: calculate available rage after potential stance switch
	local function rageAfterSwitch(targetStance)
		if targetStance == stance then
			return rage  -- No switch needed
		end
		return math.min(rage, tm)  -- Capped by TM
	end

	-- Helper: check if ability is usable (rage after switch >= cost)
	local function canUse(targetStance, cost)
		return rageAfterSwitch(targetStance) >= cost
	end

	-- Helper: check if in valid stance for ability
	local function inStance(validStances)
		for _, s in ipairs(validStances) do
			if s == 0 or s == stance then return true end
		end
		return false
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
	-- CHARGE (Battle Stance, OUT OF COMBAT ONLY)
	-- Must be used FIRST before any combat ability
	-- Bloodrage triggers combat and blocks Charge!
	-- Battle Shout does NOT trigger combat
	---------------------------------------
	if hasSpell("Charge") and not state.inCombat then
		-- Charge range: 8-25 yards
		local inChargeRange = state.targetDistance and state.targetDistance >= 8 and state.targetDistance <= 25
		local chargeReady = (state.cooldowns.Charge or 0) <= 0
		if chargeReady and inChargeRange then
			-- Charge generates rage: 9 base + Improved Charge talent (0/3/6)
			-- ATW.Talents.ChargeRage stores the total (9 + talent bonus)
			local chargeRage = 9
			if ATW.Talents and ATW.Talents.ChargeRage then
				chargeRage = ATW.Talents.ChargeRage
			end
			-- Charge requires Battle Stance
			if stance == 1 then
				table.insert(actions, {name = "Charge", stance = 1, rage = 0, needsDance = false, rageGain = chargeRage})
			elseif canUse(1, 0) then
				table.insert(actions, {name = "Charge", stance = 1, rage = 0, needsDance = true, rageGain = chargeRage})
			end
		end
	end

	---------------------------------------
	-- Execute (stance: Battle/Berserker, target < 20%)
	---------------------------------------
	if inExecute and hasSpell("Execute") then
		local execCost = ATW.Talents and ATW.Talents.ExecCost or 15
		-- In Battle or Berserker: can execute directly
		if (stance == 1 or stance == 3) and rage >= execCost then
			table.insert(actions, {name = "Execute", stance = stance, rage = execCost, needsDance = false})
		-- In Defensive: need to dance to Berserker
		elseif stance == 2 and canUse(3, execCost) then
			table.insert(actions, {name = "Execute", stance = 3, rage = execCost, needsDance = true})
		end
	end

	---------------------------------------
	-- Bloodthirst (stance: Berserker only, 30 rage, 6s CD)
	---------------------------------------
	if ATW.Talents and ATW.Talents.HasBT then
		local btCost = 30
		local btReady = (state.cooldowns.Bloodthirst or 0) <= 0
		if btReady then
			if stance == 3 and rage >= btCost then
				table.insert(actions, {name = "Bloodthirst", stance = 3, rage = btCost, needsDance = false})
			elseif stance ~= 3 and canUse(3, btCost) then
				table.insert(actions, {name = "Bloodthirst", stance = 3, rage = btCost, needsDance = true})
			end
		end
	end

	---------------------------------------
	-- Mortal Strike (stance: Battle/Berserker, 30 rage, 6s CD)
	-- Note: MS works in Berserker in TurtleWoW (verify this)
	---------------------------------------
	if ATW.Talents and ATW.Talents.HasMS then
		local msCost = 30
		local msReady = (state.cooldowns.MortalStrike or 0) <= 0
		if msReady then
			-- MS traditionally Battle stance only, but check Abilities.lua
			if stance == 1 and rage >= msCost then
				table.insert(actions, {name = "MortalStrike", stance = 1, rage = msCost, needsDance = false})
			elseif stance == 3 and rage >= msCost then
				-- Check if MS works in Berserker (TurtleWoW may allow this)
				table.insert(actions, {name = "MortalStrike", stance = 3, rage = msCost, needsDance = false})
			elseif stance == 2 and canUse(1, msCost) then
				table.insert(actions, {name = "MortalStrike", stance = 1, rage = msCost, needsDance = true})
			end
		end
	end

	---------------------------------------
	-- Whirlwind (stance: Berserker only, 25 rage, 10s CD)
	---------------------------------------
	if hasSpell("Whirlwind") then
		local wwCost = 25
		local wwReady = (state.cooldowns.Whirlwind or 0) <= 0
		if wwReady then
			if stance == 3 and rage >= wwCost then
				table.insert(actions, {name = "Whirlwind", stance = 3, rage = wwCost, needsDance = false})
			elseif stance ~= 3 and canUse(3, wwCost) then
				table.insert(actions, {name = "Whirlwind", stance = 3, rage = wwCost, needsDance = true})
			end
		end
	end

	---------------------------------------
	-- Overpower (stance: Battle only, 5 rage, requires dodge proc)
	---------------------------------------
	if hasSpell("Overpower") and state.overpowerReady and state.overpowerEnd > 0 then
		local opCost = 5
		local opReady = (state.cooldowns.Overpower or 0) <= 0
		if opReady then
			if stance == 1 and rage >= opCost then
				table.insert(actions, {name = "Overpower", stance = 1, rage = opCost, needsDance = false})
			elseif stance ~= 1 and canUse(1, opCost) then
				table.insert(actions, {name = "Overpower", stance = 1, rage = opCost, needsDance = true})
			end
		end
	end

	---------------------------------------
	-- Battle Shout (any stance, 10 rage)
	---------------------------------------
	if hasSpell("BattleShout") and not state.hasBattleShout then
		local bsCost = 10
		if rage >= bsCost then
			table.insert(actions, {name = "BattleShout", stance = stance, rage = bsCost, needsDance = false})
		end
	end

	---------------------------------------
	-- MULTI-TARGET REND (stance: Battle/Defensive, 10 rage)
	-- Generate Rend action for EACH enemy that needs it
	-- SKIP if GCD is active (Rend is a GCD ability)
	---------------------------------------
	local rendCost = 10
	local rendActionsAdded = {}  -- Track which targets we added Rend for

	if not gcdActive and hasSpell("Rend") and state.enemies and table.getn(state.enemies) > 0 then
		for _, enemy in ipairs(state.enemies) do
			-- Skip bleed immune targets
			if not enemy.bleedImmune and not enemy.inExecute then
				-- Only if Rend not active or about to expire (< 3s)
				if not enemy.hasRend or enemy.rendRemaining < 3000 then
					-- NO HARDCODED THRESHOLDS - Let simulation decide if Rend is worth it
					-- The GetActionDamage() function calculates actual damage based on TTD
					-- and the simulation compares vs other abilities
					-- Only filter: target must survive at least 1 tick (3s) to do any damage
					local minTTDForAnyDamage = 3000  -- 1 tick minimum
					if enemy.ttd >= minTTDForAnyDamage then
						-- Check melee range (5yd for Rend)
						if enemy.distance <= 5 then
							-- Add Rend action for this specific target
							if (stance == 1 or stance == 2) and rage >= rendCost then
								table.insert(actions, {
									name = "Rend",
									stance = stance,
									rage = rendCost,
									needsDance = false,
									targetGUID = enemy.guid,
									targetTTD = enemy.ttd,
									targetHP = enemy.hpPercent,
									isMainTarget = enemy.isTarget,
								})
								rendActionsAdded[enemy.guid] = true
							elseif stance == 3 and canUse(1, rendCost) then
								table.insert(actions, {
									name = "Rend",
									stance = 1,
									rage = rendCost,
									needsDance = true,
									targetGUID = enemy.guid,
									targetTTD = enemy.ttd,
									targetHP = enemy.hpPercent,
									isMainTarget = enemy.isTarget,
								})
								rendActionsAdded[enemy.guid] = true
							end
						end
					end
				end
			end
		end
	elseif not gcdActive and hasSpell("Rend") then
		-- Fallback: Single target mode (no enemy list available)
		-- SKIP if GCD is active (Rend is a GCD ability)
		if not state.targetBleedImmune and not inExecute then
			if not state.rendOnTarget or state.rendRemaining < 3000 then
				-- NO HARDCODED THRESHOLDS - only require 1 tick minimum (3s TTD)
				local minTTDForAnyDamage = 3000
				if state.targetTTD >= minTTDForAnyDamage then
					if (stance == 1 or stance == 2) and rage >= rendCost then
						table.insert(actions, {name = "Rend", stance = stance, rage = rendCost, needsDance = false})
					elseif stance == 3 and canUse(1, rendCost) then
						table.insert(actions, {name = "Rend", stance = 1, rage = rendCost, needsDance = true})
					end
				end
			end
		end
	end

	---------------------------------------
	-- Slam (any stance, 15 rage, resets swing timer)
	-- ONLY with 2H weapon (no offhand)
	-- CRITICAL: Only use right after auto-attack (swing timer near full)
	-- Using Slam mid-swing wastes swing progress (Zebouski approach)
	---------------------------------------
	if hasSpell("Slam") and not state.hasOH then
		local slamCost = 15
		local slamReady = (state.cooldowns.Slam or 0) <= 0
		if slamReady and rage >= slamCost then
			-- Check swing timer - only Slam if we just landed an auto-attack
			-- mhTimer is time REMAINING, mhSpeed is full swing duration
			-- Slam is optimal when mhTimer >= mhSpeed * 0.9 (just after swing)
			local mhTimer = state.mhTimer or 0
			local mhSpeed = state.mhSpeed or 2500
			local swingJustLanded = mhTimer >= (mhSpeed * 0.85)  -- Within 15% of full timer

			if swingJustLanded then
				table.insert(actions, {name = "Slam", stance = stance, rage = slamCost, needsDance = false})
			end
		end
	end

	---------------------------------------
	-- Heroic Strike (any stance, off-GCD)
	-- NO THRESHOLD - let the simulation decide optimal rage management
	-- The 6s lookahead naturally handles "save rage for BT" decisions
	---------------------------------------
	if hasSpell("HeroicStrike") then
		local hsCost = ATW.GetHeroicStrikeCost and ATW.GetHeroicStrikeCost() or 15
		-- Simple check: have rage and not already queued
		-- The simulation compares HS damage vs saving rage for other abilities
		if rage >= hsCost and not state.swingQueued then
			table.insert(actions, {name = "HeroicStrike", stance = stance, rage = hsCost, needsDance = false, offGCD = true})
		end
	end

	---------------------------------------
	-- Cleave (any stance, off-GCD, 2+ targets)
	-- NO THRESHOLD - let the simulation decide optimal rage management
	---------------------------------------
	if hasSpell("Cleave") then
		local numMeleeTargets = state.enemyCountMelee or 1
		local cleaveCost = 20
		-- Simple check: 2+ targets, have rage, not already queued
		if numMeleeTargets >= 2 and rage >= cleaveCost and not state.swingQueued then
			table.insert(actions, {name = "Cleave", stance = stance, rage = cleaveCost, needsDance = false, offGCD = true})
		end
	end

	---------------------------------------
	-- Bloodrage (any stance, OFF-GCD, generates rage)
	-- Critical for rage generation at pull and during combat
	-- IMPORTANT: Bloodrage ENTERS COMBAT - do NOT use if Charge is available!
	---------------------------------------
	if hasSpell("Bloodrage") then
		local bloodrageReady = (state.cooldowns.Bloodrage or 0) <= 0
		if bloodrageReady and not state.hasBloodrageActive then
			-- Check if Charge is available - if so, DON'T use Bloodrage (it blocks Charge)
			local chargeBlocked = false
			if hasSpell("Charge") and not state.inCombat then
				local chargeReady = (state.cooldowns.Charge or 0) <= 0
				local inChargeRange = state.targetDistance and state.targetDistance >= 8 and state.targetDistance <= 25
				if chargeReady and inChargeRange then
					chargeBlocked = true  -- Don't use Bloodrage, Charge is better!
				end
			end
			if not chargeBlocked then
				table.insert(actions, {name = "Bloodrage", stance = stance, rage = 0, needsDance = false, offGCD = true})
			end
		end
	end

	---------------------------------------
	-- Berserker Rage (Berserker only, OFF-GCD)
	-- Fear break + rage from damage with Improved BR talent
	---------------------------------------
	if hasSpell("BerserkerRage") and ATW.Talents and ATW.Talents.HasIBR then
		local brReady = (state.cooldowns.BerserkerRage or 0) <= 0
		if brReady and not state.hasBerserkerRage then
			if stance == 3 then
				table.insert(actions, {name = "BerserkerRage", stance = 3, rage = 0, needsDance = false, offGCD = true})
			elseif canUse(3, 0) then
				-- Can dance to Berserker for this
				table.insert(actions, {name = "BerserkerRage", stance = 3, rage = 0, needsDance = true, offGCD = true})
			end
		end
	end

	---------------------------------------
	-- Death Wish (any stance, OFF-GCD, +20% damage)
	-- Major DPS cooldown - use when available
	---------------------------------------
	if ATW.Talents and ATW.Talents.HasDW then
		local dwReady = (state.cooldowns.DeathWish or 0) <= 0
		local dwCost = 10
		if dwReady and not state.hasDeathWish and rage >= dwCost then
			table.insert(actions, {name = "DeathWish", stance = stance, rage = dwCost, needsDance = false, offGCD = true})
		end
	end

	---------------------------------------
	-- Recklessness (Berserker only, OFF-GCD, +100% crit)
	-- Major cooldown - use carefully
	---------------------------------------
	if hasSpell("Recklessness") and ATW.AvailableStances and ATW.AvailableStances[3] then
		local reckReady = (state.cooldowns.Recklessness or 0) <= 0
		if reckReady and not state.hasRecklessness then
			if stance == 3 then
				table.insert(actions, {name = "Recklessness", stance = 3, rage = 0, needsDance = false, offGCD = true})
			-- Don't dance just for Recklessness - it's a long CD
			end
		end
	end

	---------------------------------------
	-- Sweeping Strikes (Battle only, 2+ targets)
	-- AoE damage buff - next 5 attacks hit additional target
	---------------------------------------
	local numMeleeTargets = state.enemyCountMelee or 1
	if hasSpell("SweepingStrikes") and numMeleeTargets >= 2 then
		local ssReady = (state.cooldowns.SweepingStrikes or 0) <= 0
		local ssCost = 30
		if ssReady and not state.hasSweepingStrikes then
			if stance == 1 and rage >= ssCost then
				table.insert(actions, {name = "SweepingStrikes", stance = 1, rage = ssCost, needsDance = false})
			elseif stance ~= 1 and canUse(1, ssCost) then
				table.insert(actions, {name = "SweepingStrikes", stance = 1, rage = ssCost, needsDance = true})
			end
		end
	end

	---------------------------------------
	-- Pummel (Battle/Berserker, OFF-GCD interrupt)
	-- Only when interrupt is needed
	---------------------------------------
	if hasSpell("Pummel") and state.shouldInterrupt then
		local pummelReady = (state.cooldowns.Pummel or 0) <= 0
		local pummelCost = 10
		if pummelReady and rage >= pummelCost then
			if stance == 1 or stance == 3 then
				table.insert(actions, {name = "Pummel", stance = stance, rage = pummelCost, needsDance = false, offGCD = true})
			elseif canUse(3, pummelCost) then
				table.insert(actions, {name = "Pummel", stance = 3, rage = pummelCost, needsDance = true, offGCD = true})
			end
		end
	end

	---------------------------------------
	-- Wait (always valid - for rage pooling)
	---------------------------------------
	table.insert(actions, {name = "Wait", stance = stance, rage = 0, needsDance = false})

	return actions
end

---------------------------------------
-- Calculate damage for an action
-- Returns expected damage (includes crit expectation)
---------------------------------------
function Engine.GetActionDamage(state, action)
	local ap = state.ap or 1000

	-- If Battle Shout is active, add its AP
	if state.hasBattleShout then
		ap = ap + (ATW.GetBattleShoutAP and ATW.GetBattleShoutAP() or 232)
	end

	-- Calculate effective crit chance based on RESULTING stance
	-- Berserker Stance: +3% crit
	-- Battle/Defensive: no modifier
	local baseCrit = state.crit or 20
	local stanceAfterAction = action.needsDance and action.stance or state.stance
	local stanceCritBonus = 0
	if stanceAfterAction == 3 then  -- Berserker
		stanceCritBonus = 3
	end
	local effectiveCrit = baseCrit + stanceCritBonus

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
		-- Execute uses rage BEFORE TM cap if dancing
		local availableRage = state.rage
		if action.needsDance then
			local tm = state.tacticalMastery or 0
			availableRage = math.min(state.rage, tm)
		end
		local execCost = ATW.Talents and ATW.Talents.ExecCost or 15
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
		local opCritBonus = ATW.Talents and ATW.Talents.OPCrit or 0
		-- Overpower uses Battle Stance (no stance crit bonus)
		local opCrit = baseCrit + opCritBonus  -- No berserker bonus since it's Battle stance
		critExpectedMult = 1 + (opCrit / 100) * (critMultiplier - 1)

	elseif action.name == "Slam" then
		-- Slam: weapon damage + bonus, resets swing timer
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
		local horizonSec = Engine.DECISION_HORIZON / 1000
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
		local tickInterval = 3000  -- 3 seconds per tick
		local ticksFromTTD = math.floor(targetTTD / tickInterval)
		local numTicks = math.min(maxTicks, ticksFromTTD)
		if numTicks < 1 then numTicks = 1 end

		damage = tickTotal * numTicks

		-- Small bonus for main target (tiebreaker when damage is similar)
		-- This prioritizes keeping Rend on your focus target
		if action.isMainTarget then
			damage = damage * 1.05  -- 5% bonus for main target
		end

		canCrit = false  -- DoTs don't crit in vanilla

	elseif action.name == "HeroicStrike" then
		local bonus = ATW.GetHeroicStrikeBonus and ATW.GetHeroicStrikeBonus() or 157
		local weaponDmg = (state.mhDmgMin + state.mhDmgMax) / 2
		damage = weaponDmg + bonus

	elseif action.name == "Cleave" then
		local bonus = ATW.GetCleaveBonus and ATW.GetCleaveBonus() or 50
		local weaponDmg = (state.mhDmgMin + state.mhDmgMax) / 2
		-- Use state.enemyCountMelee (5yd range) from CaptureCurrentState
		local targetsHit = math.min(2, state.enemyCountMelee or 1)
		if targetsHit < 1 then targetsHit = 1 end
		damage = (weaponDmg + bonus) * targetsHit

	elseif action.name == "Wait" then
		damage = 0
		canCrit = false

	---------------------------------------
	-- BUFF/UTILITY ABILITIES
	-- These don't deal direct damage but have strategic value
	---------------------------------------
	elseif action.name == "Bloodrage" then
		-- Bloodrage generates rage (20 total: 10 instant + 10 over time)
		-- In TurtleWoW it also triggers Enrage talent
		-- Value = rage generated * expected damage per rage
		local rageGen = 20
		local avgDmgPerRage = 25  -- Rough estimate
		damage = rageGen * avgDmgPerRage * 0.3  -- Discounted value
		canCrit = false

	elseif action.name == "BerserkerRage" then
		-- Berserker Rage: fear immunity + extra rage from damage taken
		-- Strategic value but no direct damage
		damage = 50  -- Small value to not be ignored
		canCrit = false

	elseif action.name == "DeathWish" then
		-- Death Wish: +20% damage for 30s
		-- Value = expected damage increase over duration
		local horizonSec = Engine.DECISION_HORIZON / 1000
		local avgDmgPerSec = 500  -- Rough estimate
		damage = avgDmgPerSec * horizonSec * 0.20 * 0.5  -- 20% increase, discounted
		canCrit = false

	elseif action.name == "Recklessness" then
		-- Recklessness: +100% crit for 15s
		-- Massive DPS increase - high value
		local horizonSec = math.min(15, Engine.DECISION_HORIZON / 1000)
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

	-- Defensive Stance: -10% damage dealt
	if stanceAfterAction == 2 then
		dmgMod = dmgMod * 0.90
	end

	return damage * dmgMod
end

---------------------------------------
-- Apply action to state, returning new state
---------------------------------------
function Engine.ApplyAction(state, action)
	local newState = Engine.DeepCopyState(state)
	local gcd = Engine.DECISION_GCD

	-- STANCE SWITCH FIRST (if needed)
	-- In vanilla, stance switch happens BEFORE ability cast
	-- Rage is capped by Tactical Mastery on switch
	if action.needsDance then
		local tm = newState.tacticalMastery or 0
		-- Cap rage at TM value
		if newState.rage > tm then
			newState.rage = tm
		end
		newState.stance = action.stance
	end

	-- THEN pay rage cost (after potential TM cap)
	newState.rage = newState.rage - action.rage

	-- Apply ability-specific effects
	-- NOTE: Most offensive abilities set inCombat = true to prevent Charge after use
	if action.name == "Execute" then
		-- Execute consumes ALL rage (base cost already paid above)
		-- The excess rage was converted to damage in GetActionDamage
		newState.rage = 0
		newState.inCombat = true

	elseif action.name == "Bloodthirst" then
		newState.cooldowns.Bloodthirst = 6000  -- 6s CD
		newState.inCombat = true

	elseif action.name == "MortalStrike" then
		newState.cooldowns.MortalStrike = 6000
		newState.inCombat = true

	elseif action.name == "Whirlwind" then
		newState.cooldowns.Whirlwind = 10000  -- 10s CD
		newState.inCombat = true

	elseif action.name == "Overpower" then
		newState.cooldowns.Overpower = 5000
		newState.overpowerReady = false
		newState.overpowerEnd = 0
		newState.inCombat = true

	elseif action.name == "Slam" then
		-- Slam resets swing timer (penalty for using it)
		-- No cooldown, but costs a GCD and delays next auto
		newState.mhTimer = newState.mhSpeed  -- Reset MH swing timer
		newState.inCombat = true

	elseif action.name == "Charge" then
		-- Charge enters combat and generates rage
		newState.inCombat = true  -- Now in combat - Charge becomes unavailable
		newState.cooldowns.Charge = 15000  -- 15s CD
		-- Add rage gain (already calculated in action)
		local rageGain = action.rageGain or 9
		newState.rage = math.min(100, newState.rage + rageGain)

	elseif action.name == "BattleShout" then
		newState.hasBattleShout = true
		-- AP will be added in GetActionDamage for subsequent abilities

	elseif action.name == "Rend" then
		-- MULTI-TARGET REND: Update specific enemy's state if targetGUID provided
		local rendDuration = (ATW.GetRendDuration and ATW.GetRendDuration() or 22) * 1000
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
		newState.hasEnrage = true  -- Bloodrage triggers Enrage in TurtleWoW
		newState.inCombat = true  -- Bloodrage ENTERS COMBAT - blocks Charge!
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

	elseif action.name == "Pummel" then
		newState.cooldowns.Pummel = 10000  -- 10s CD
		newState.shouldInterrupt = false  -- Interrupt consumed
		newState.inCombat = true
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
		local ragePerGCD = 15
		if not newState.hasOH then
			ragePerGCD = 10  -- Less rage with 2H
		end
		newState.rage = math.min(100, newState.rage + ragePerGCD)

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
-- Main decision function: Simulate all
-- valid actions and return the best one
---------------------------------------
function Engine.GetBestAction()
	local state = Engine.CaptureCurrentState()
	local actions = Engine.GetValidActions(state)
	local horizon = Engine.DECISION_HORIZON

	local bestAction = nil
	local bestDamage = -1
	local results = {}  -- For debugging

	for _, action in ipairs(actions) do
		local totalDamage = Engine.SimulateDecisionHorizon(state, action, horizon)

		-- Store result for debugging
		table.insert(results, {
			name = action.name,
			damage = totalDamage,
			needsDance = action.needsDance,
			targetGUID = action.targetGUID,
			targetHP = action.targetHP,
		})

		if totalDamage > bestDamage then
			bestDamage = totalDamage
			bestAction = action
		end
	end

	-- Store last decision results for debugging
	Engine.lastDecisionResults = results
	Engine.lastBestAction = bestAction

	return bestAction, bestDamage, results
end

---------------------------------------
-- NEW GetRecommendation using simulator
-- Returns: abilityName (internal), isOffGCD, pooling, timeToExecute, targetGUID, targetStance
---------------------------------------
function Engine.GetRecommendationSimBased()
	local bestAction, bestDamage, results = Engine.GetBestAction()

	if not bestAction or bestAction.name == "Wait" then
		return nil, false, false, 0, nil, nil
	end

	local targetStance = nil
	if bestAction.needsDance then
		targetStance = bestAction.stance
	end

	-- For multi-target Rend, return the specific targetGUID
	local targetGUID = bestAction.targetGUID or nil

	-- Return INTERNAL name (e.g., "BattleShout" not "Battle Shout")
	-- The Rotation.lua looks up ATW.Abilities[abilityName] which uses internal names
	return bestAction.name, bestAction.offGCD or false, false, 0, targetGUID, targetStance
end

---------------------------------------
-- Debug: Print decision comparison
---------------------------------------
function Engine.PrintDecisionDebug()
	local bestAction, bestDamage, results = Engine.GetBestAction()

	ATW.Print("=== Decision Simulator ===")
	ATW.Print("Horizon: " .. (Engine.DECISION_HORIZON / 1000) .. "s")
	ATW.Print("")

	-- Sort by damage descending
	table.sort(results, function(a, b) return a.damage > b.damage end)

	ATW.Print("Action comparison:")
	for _, r in ipairs(results) do
		local marker = ""
		if bestAction and r.name == bestAction.name then
			marker = " |cff00ff00<< BEST|r"
		end
		local danceStr = r.needsDance and " (dance)" or ""
		local targetStr = r.targetGUID and " [GUID]" or ""
		ATW.Print("  " .. r.name .. danceStr .. targetStr .. ": " ..
			string.format("%.0f", r.damage) .. " dmg" .. marker)
	end

	-- Show current state info
	local state = Engine.CaptureCurrentState()
	ATW.Print("")
	ATW.Print("Current state:")
	ATW.Print("  Rage: " .. state.rage)
	ATW.Print("  Stance: " .. state.stance)
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
