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

-- Execute formula (TurtleWoW rank 5): 600 + (15 * excessRage)
Engine.EXECUTE_BASE = 600
Engine.EXECUTE_RAGE_MULT = 15

-- Bloodthirst (TurtleWoW): 200 + AP * 0.35
Engine.BT_BASE = 200
Engine.BT_AP_COEFF = 0.35

-- Whirlwind normalized speed
Engine.WW_NORM_SPEED = 2.4  -- Normalized for 1H

-- Mortal Strike bonus damage (rank 4)
Engine.MS_BONUS = 160

-- Heroic Strike bonus damage (rank 9)
Engine.HS_BONUS = 157

-- Cleave bonus damage
Engine.CLEAVE_BONUS = 50

-- Overpower bonus damage
Engine.OP_BONUS = 35

-- Hamstring damage (rank 3)
Engine.HAMSTRING_DMG = 45

-- Slam bonus (TurtleWoW)
Engine.SLAM_BONUS = 87

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

		-- Cooldowns (time when available, 0 = ready)
		cooldowns = {
			Bloodthirst = 0,
			Whirlwind = 0,
			Execute = 0,
			Overpower = 0,
			DeathWish = 0,
			Recklessness = 0,
			Bloodrage = 0,
			BerserkerRage = 0,
			SweepingStrikes = 0,
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

	-- Count rendable targets (not bleed immune, TTD > 15s)
	state.rendableTargets = 0
	for id, target in pairs(state.targets) do
		if not target.bleedImmune and target.ttd >= 15000 then
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
		damage = Engine.EXECUTE_BASE + (usedRage * Engine.EXECUTE_RAGE_MULT)

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
			damage = Engine.RollWeaponDamage(state, false, true, Engine.WW_NORM_SPEED) + Engine.MS_BONUS

		elseif name == "Slam" then
			-- Weapon + bonus + (ap/14) * weaponSpeed
			damage = Engine.RollWeaponDamage(state, false, false) + Engine.SLAM_BONUS

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
			damage = Engine.RollWeaponDamage(state, false, false) + Engine.OP_BONUS
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
			damage = damage + Engine.HS_BONUS
			state.swingQueued = nil

			table.insert(state.sequence, {
				time = state.time,
				ability = "HeroicStrike",
				damage = damage,
				rage = state.rage,
			})

		elseif state.swingQueued == "cleave" then
			-- Cleave: weapon + bonus, hits 2 targets
			damage = damage + Engine.CLEAVE_BONUS
			state.swingQueued = nil

			-- First target damage
			local firstTargetDmg = damage

			-- Second target (if available) - Zebouski calls attackmh recursively
			if aliveTargets >= 2 then
				local secondTargetDmg = Engine.RollWeaponDamage(state, false, false) + Engine.CLEAVE_BONUS
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
-- Choose best ability to use
---------------------------------------
function Engine.ChooseAbility(state)
	local inExecute = Engine.AnyTargetInExecute(state)
	local aliveTargets = Engine.CountAliveTargets(state)

	-- Priority list
	local priorities = {
		-- Off-GCD abilities first
		{name = "Bloodrage", offGCD = true, condition = function()
			return state.rage < 50 and (state.health or 100) >= 50
		end},
		{name = "BerserkerRage", offGCD = true, condition = function()
			return state.stance == 3 and ATW.Talents and ATW.Talents.HasIBR
		end},
		{name = "DeathWish", offGCD = true, condition = function()
			return ATW.Talents and ATW.Talents.HasDW
		end},
		{name = "Recklessness", offGCD = true, condition = function()
			return state.stance == 3
		end},

		-- Execute phase
		{name = "Execute", condition = function() return inExecute end},

		-- Core rotation
		{name = "Bloodthirst"},
		{name = "MortalStrike", condition = function()
			return ATW.Talents and ATW.Talents.HasMS and not ATW.Talents.HasBT
		end},
		{name = "Whirlwind"},

		-- React abilities
		{name = "Overpower", condition = function()
			return state.overpowerReady
		end},

		-- Rage dumps
		{name = "Cleave", condition = function()
			return aliveTargets >= 2 and state.rage >= 60
		end},
		{name = "HeroicStrike", condition = function()
			return state.rage >= 70 and not state.swingQueued
		end},
	}

	for _, prio in ipairs(priorities) do
		-- Check custom condition (skip if condition returns false)
		local conditionMet = true
		if prio.condition then
			conditionMet = prio.condition()
		end

		-- Check if ability can be used
		if conditionMet and Engine.CanUseAbility(state, prio.name) then
			return prio.name, prio.offGCD
		end
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
	local hsDamage = Engine.HS_BONUS + ((state.mhDmgMin + state.mhDmgMax) / 2)
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
		-- Execute = 600 + (rage * 15)
		local execDmg = Engine.EXECUTE_BASE + (state.rage * Engine.EXECUTE_RAGE_MULT)

		-- If we wait for HS, we get HS damage but Execute later with less rage
		-- (rage spent on HS is rage not spent on Execute)
		local rageCost = state.swingQueued == "hs" and 15 or 20
		local execWithHS = Engine.EXECUTE_BASE + ((state.rage - rageCost) * Engine.EXECUTE_RAGE_MULT)

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
-- Should pool rage for Execute?
---------------------------------------
function Engine.ShouldPoolForExecute(state)
	-- Find closest target to execute phase
	local closestToExecute = nil
	local minTimeToExecute = 999999

	for id, target in pairs(state.targets) do
		if target.hp > Engine.EXECUTE_THRESHOLD then
			-- Time until this target hits 20% HP
			local hpToLose = target.hp - Engine.EXECUTE_THRESHOLD
			local timeToExecute = hpToLose / target.hpDecayRate
			if timeToExecute < minTimeToExecute then
				minTimeToExecute = timeToExecute
				closestToExecute = target
			end
		end
	end

	-- Pool rage if execute phase coming within 5 seconds
	if minTimeToExecute < 5000 and state.rage < 80 then
		return true, minTimeToExecute
	end

	return false, 0
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

		-- Check for execute rage pooling
		local shouldPool, timeToExecute = Engine.ShouldPoolForExecute(state)

		-- Check if we should cancel HS/Cleave
		local shouldCancel, cancelReason = Engine.ShouldCancelSwing(state)
		if shouldCancel then
			Engine.CancelSwingQueue(state)
		end

		-- Choose and use ability
		local abilityName, isOffGCD = Engine.ChooseAbility(state)

		if abilityName then
			-- Skip low-priority abilities when pooling for execute
			if shouldPool and state.rage < 90 then
				-- Only use high-priority abilities
				if abilityName ~= "Bloodthirst" and abilityName ~= "Whirlwind" and
				   abilityName ~= "Execute" and abilityName ~= "Bloodrage" then
					abilityName = nil
				end
			end

			if abilityName then
				Engine.UseAbility(state, abilityName)
			end
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
-- Simulate with Rend Spreading Strategy
-- Applies Rend to multiple targets in melee range
-- Uses proper Tactical Mastery and bleed immunity checks
---------------------------------------
function Engine.SimulateRendSpread(duration)
	duration = duration or 30  -- 30 second simulation window

	local state = Engine.CreateState()
	state.maxTime = duration * 1000
	state.strategy = "rend_spread"

	Engine.InitTargets(state)
	Engine.InitPlayer(state)

	-- Get targets that can be Rended:
	-- 1. NOT bleed immune (Mechanical, Elemental, Undead)
	-- 2. TTD > 15s (worth the rage investment)
	-- 3. In melee range (5yd for Rend)
	local rendTargets = {}
	for id, target in pairs(state.targets) do
		if not target.bleedImmune and target.ttd > 15000 then
			-- Sort by TTD descending (Rend highest TTD first for max value)
			table.insert(rendTargets, {id = id, ttd = target.ttd, guid = target.guid})
		end
	end

	-- Sort by TTD descending
	table.sort(rendTargets, function(a, b) return a.ttd > b.ttd end)

	-- Track which targets have Rend
	local rendedTargets = {}
	local rendIndex = 1

	-- Track Anger Management
	local lastAngerManagementTick = 0

	-- Simulation loop
	while state.time < state.maxTime do
		local deltaTime = Engine.GetNextEvent(state)
		state.time = state.time + deltaTime
		if state.time > state.maxTime then break end

		-- Anger Management
		if ATW.Talents and ATW.Talents.AngerManagement then
			while state.time >= lastAngerManagementTick + 3000 do
				lastAngerManagementTick = lastAngerManagementTick + 3000
				state.rage = math.min(state.rage + 1, 100)
			end
		end

		Engine.UpdateTargetHP(state, deltaTime)
		state.mhTimer = state.mhTimer - deltaTime
		if state.hasOH then state.ohTimer = state.ohTimer - deltaTime end

		Engine.ProcessDoTs(state)

		-- Auto-attacks
		if state.mhTimer <= 0 then
			Engine.ProcessAutoAttack(state, false)
			local haste = Engine.GetHasteMod(state)
			state.mhTimer = state.mhSpeed / haste
		end
		if state.hasOH and state.ohTimer <= 0 then
			Engine.ProcessAutoAttack(state, true)
			local haste = Engine.GetHasteMod(state)
			state.ohTimer = state.ohSpeed / haste
		end

		-- Rend spreading priority
		local usedAbility = false

		-- First: Apply Rend to all viable targets (non-immune only)
		if rendIndex <= table.getn(rendTargets) and state.gcdEnd <= state.time then
			local targetInfo = rendTargets[rendIndex]
			local targetId = targetInfo.id
			local target = state.targets[targetId]

			-- Double-check bleed immunity (in case state changed)
			if target and not target.bleedImmune and not rendedTargets[targetId] then
				-- Calculate rage needed (10 for Rend + potential stance switch loss)
				local rendCost = 10
				local needsStance = (state.stance ~= 1 and state.stance ~= 2)
				local effectiveCost = rendCost

				if needsStance then
					-- Factor in rage loss from stance switch (Tactical Mastery)
					local rageLost = math.max(0, state.rage - state.tacticalMastery)
					effectiveCost = rendCost + rageLost
				end

				if state.rage >= effectiveCost then
					-- Switch stance if needed (using Tactical Mastery)
					if needsStance then
						Engine.SwitchStance(state, 1)  -- Go to Battle Stance
					end

					-- Apply Rend (if we still have enough rage after switch)
					if state.rage >= rendCost then
						Engine.ApplyRend(state, targetId)
						state.rage = state.rage - rendCost
						state.gcdEnd = state.time + Engine.GCD
						rendedTargets[targetId] = true
						rendIndex = rendIndex + 1
						usedAbility = true

						table.insert(state.sequence, {
							time = state.time,
							ability = "Rend",
							damage = 0,
							rage = state.rage,
							target = targetId,
							guid = targetInfo.guid,  -- Store GUID for real casting
						})
					end
				end
			else
				-- Skip this target (immune or already has Rend)
				rendIndex = rendIndex + 1
			end
		end

		-- Then: Normal rotation (switch back to Berserker for BT/WW)
		if not usedAbility then
			-- Check if we should go back to Berserker
			if state.stance ~= 3 and state.stanceGcdEnd <= state.time then
				local btReady = state.cooldowns.Bloodthirst <= state.time
				local wwReady = state.cooldowns.Whirlwind <= state.time
				if (btReady or wwReady) and state.rage >= 25 then
					Engine.SwitchStance(state, 3)
				end
			end

			local abilityName, isOffGCD = Engine.ChooseAbility(state)
			if abilityName and abilityName ~= "Rend" then
				Engine.UseAbility(state, abilityName)
			end
		end

		-- Expire buffs
		for buffName, buff in pairs(state.buffs) do
			if buff.endTime and buff.endTime <= state.time then
				state.buffs[buffName] = nil
			end
		end

		if deltaTime == 0 then state.time = state.time + 1 end
	end

	return {
		totalDamage = state.totalDamage,
		abilityDamage = state.abilityDamage,
		autoDamage = state.autoDamage,
		dotDamage = state.dotDamage,
		duration = state.maxTime / 1000,
		dps = state.totalDamage / (state.maxTime / 1000),
		sequence = state.sequence,
		rendTargets = table.getn(rendTargets),
		bleedImmuneSkipped = state.rendableTargets - table.getn(rendTargets),
	}
end

---------------------------------------
-- Rend Priority Logic (Rule-Based, not Simulation)
-- Uses HP% as primary signal since TTD is unstable at combat start
-- This ensures Rend is applied EARLY when it should be
---------------------------------------

-- Constants for Rend decision-making
Engine.REND_DURATION = 21       -- 21 seconds (7 ticks × 3s)
Engine.REND_MIN_TICKS = 3       -- Need at least 3 ticks to be worth it (9s)
Engine.REND_FULL_VALUE_HP = 70  -- Above 70% HP = assume full duration
Engine.REND_MIN_HP = 30         -- Below 30% HP = don't Rend (dying)

--[[
Mathematical basis for Rend decision:

Rend total damage (TurtleWoW): 147 + (AP × 0.35) over 21s
Rend DPR at full duration: (147 + 0.35×AP) / 10 rage

With 1500 AP: (147 + 525) / 10 = 67.2 DPR
Compare to BT: ~725 / 30 = 24.2 DPR
Compare to HS: ~300 / 15 = 20 DPR

Even at 50% ticks (3-4 ticks), Rend DPR is still ~33.6, beating everything.
Therefore: Apply Rend if target will get AT LEAST 3 ticks (9 seconds).

HP% heuristic:
- HP > 70%: Very likely to live 21s+ → Apply Rend
- HP 30-70%: Check TTD if available, else use HP/damage heuristic
- HP < 30%: Likely dying soon → Don't Rend

This is how Hekili and similar addons handle DoT decisions.
]]

---------------------------------------
-- Should apply Rend to current target?
-- Uses HP% as primary signal (stable, instant)
-- Returns: shouldApply, reason
---------------------------------------
function Engine.ShouldApplyRend()
	-- Check if target exists
	if not UnitExists("target") or UnitIsDead("target") then
		return false, "no target"
	end

	-- Check for bleed immunity
	if ATW.IsBleedImmune and ATW.IsBleedImmune("target") then
		return false, "bleed immune"
	end

	-- Check if Rend already applied (uses RendTracker + UnitDebuff)
	-- ATW.HasRend handles both tracking and actual debuff check
	if ATW.HasRend and ATW.HasRend("target") then
		return false, "already applied"
	end

	-- Get HP percentage (instantly available, stable)
	local hp = UnitHealth("target")
	local maxHp = UnitHealthMax("target")
	if maxHp == 0 then return false, "invalid hp" end

	local hpPercent = (hp / maxHp) * 100

	-- HIGH HP (>70%): Apply Rend without hesitation
	-- At 70%+ HP, target almost certainly lives for full Rend duration
	if hpPercent >= Engine.REND_FULL_VALUE_HP then
		return true, "high HP (" .. string.format("%.0f", hpPercent) .. "%)"
	end

	-- LOW HP (<30%): Don't Rend, target dying soon
	if hpPercent < Engine.REND_MIN_HP then
		return false, "low HP (" .. string.format("%.0f", hpPercent) .. "%)"
	end

	-- MEDIUM HP (30-70%): Check TTD if available
	local ttd = 999
	if ATW.GetTargetTTD then
		ttd = ATW.GetTargetTTD()
	end

	-- TTD available and reliable
	if ttd < 999 then
		-- Need at least 9s for 3 ticks (minimum value)
		if ttd >= 9 then
			return true, "TTD " .. string.format("%.0f", ttd) .. "s"
		else
			return false, "TTD too low (" .. string.format("%.0f", ttd) .. "s)"
		end
	end

	-- TTD not available: Use HP% heuristic
	-- At 50% HP, assume ~15s remaining (reasonable for most fights)
	-- Linear interpolation: TTD ≈ HP% × 0.3 seconds
	local estimatedTTD = hpPercent * 0.3

	if estimatedTTD >= 9 then
		return true, "HP heuristic (" .. string.format("%.0f", hpPercent) .. "%)"
	end

	return false, "HP heuristic too low"
end

---------------------------------------
-- Should apply Rend to a specific GUID?
-- For multi-target Rend spreading
-- Uses SuperWoW UnitDebuff(guid) to verify Rend isn't already applied
-- Returns: shouldApply, reason
---------------------------------------
function Engine.ShouldApplyRendToGUID(guid, hpPercent, ttd)
	if not guid then return false, "no guid" end

	-- Check if Rend already applied (using SuperWoW's GUID-based UnitDebuff)
	-- This is the REAL check - verifies actual debuff state on the mob
	-- Reference: https://github.com/balakethelock/SuperWoW/wiki/Features
	if ATW.HasRend and ATW.HasRend(guid) then
		return false, "already has Rend"
	end

	-- Check bleed immunity by GUID
	if ATW.IsBleedImmuneGUID and ATW.IsBleedImmuneGUID(guid) then
		return false, "bleed immune"
	end

	hpPercent = hpPercent or 100
	ttd = ttd or 999

	-- Same logic as main target
	if hpPercent >= Engine.REND_FULL_VALUE_HP then
		return true, "high HP"
	end

	if hpPercent < Engine.REND_MIN_HP then
		return false, "low HP"
	end

	-- Medium HP: use TTD or heuristic
	if ttd < 999 then
		return ttd >= 9, "TTD check"
	end

	local estimatedTTD = hpPercent * 0.3
	return estimatedTTD >= 9, "HP heuristic"
end

---------------------------------------
-- Get Rend priority score
-- Higher = more urgent to apply Rend
-- Returns: score (0-100), where 100 = must Rend NOW
---------------------------------------
function Engine.GetRendPriority()
	local shouldRend, reason = Engine.ShouldApplyRend()

	if not shouldRend then
		return 0, reason
	end

	-- Calculate priority based on HP%
	-- Higher HP = Higher priority (apply earlier = more value)
	local hp = UnitHealth("target")
	local maxHp = UnitHealthMax("target")
	if maxHp == 0 then return 0, "invalid hp" end

	local hpPercent = (hp / maxHp) * 100

	-- Priority formula:
	-- 100% HP = priority 100 (MUST apply now)
	-- 70% HP = priority 70
	-- 50% HP = priority 50
	-- 30% HP = priority 30 (borderline)

	local priority = hpPercent

	-- Boost priority if target has high HP and we have rage
	local rage = UnitMana("player") or 0
	if hpPercent >= 90 and rage >= 10 then
		priority = 100  -- Maximum priority at pull
	end

	return priority, reason
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
-- Compare strategies and find optimal
-- Returns: bestStrategy, damageGain%, results
---------------------------------------
function Engine.CompareStrategies(duration)
	duration = duration or 30  -- 30 second comparison window

	-- Get enemy count first
	local enemies = {}
	if ATW.GetEnemiesWithTTD then
		enemies = ATW.GetEnemiesWithTTD(5)
	end
	local numEnemies = table.getn(enemies)

	-- Normal rotation
	local normalResult = Engine.Simulate(duration, "normal")

	-- Only compare Rend spread if 2+ enemies
	if numEnemies >= 2 then
		local rendResult = Engine.SimulateRendSpread(duration)

		local gain = rendResult.totalDamage - normalResult.totalDamage
		local gainPercent = 0
		if normalResult.totalDamage > 0 then
			gainPercent = (gain / normalResult.totalDamage) * 100
		end

		if gain > 0 then
			return "rend_spread", gainPercent, {
				normal = normalResult,
				rend_spread = rendResult,
			}
		end
	end

	return "normal", 0, {
		normal = normalResult,
	}
end

---------------------------------------
-- Check if Rend spreading is optimal right now
-- Used by GetRecommendation() to adjust priority
---------------------------------------
function Engine.ShouldSpreadRend()
	local enemies = {}
	if ATW.GetEnemiesWithTTD then
		enemies = ATW.GetEnemiesWithTTD(5)
	end

	if table.getn(enemies) < 2 then
		return false, 0, 0
	end

	-- Count viable Rend targets
	local viableTargets = 0
	for _, enemy in ipairs(enemies) do
		if not enemy.bleedImmune and enemy.ttd >= 15 then
			viableTargets = viableTargets + 1
		end
	end

	if viableTargets < 2 then
		return false, 0, 0
	end

	-- Full 30s comparison for accurate strategy decision
	local strategy, gainPercent = Engine.CompareStrategies(30)

	if strategy == "rend_spread" and gainPercent > 1 then
		return true, viableTargets, gainPercent
	end

	return false, viableTargets, 0
end

---------------------------------------
-- Get next recommended ability (for display)
-- Considers: Execute pooling, Rend (rule-based), normal rotation
-- Returns: abilityName, isOffGCD, pooling, timeToExecute, targetGUID, targetStance
--
-- IMPORTANT: Rend uses RULE-BASED logic (HP%), not simulation.
-- This ensures Rend is recommended EARLY at pull when TTD is unknown.
---------------------------------------
function Engine.GetRecommendation()
	local state = Engine.CreateState()
	state.maxTime = 10000  -- Only need short sim for next ability

	Engine.InitTargets(state)
	Engine.InitPlayer(state)

	local rage = UnitMana("player") or 0
	local currentStance = ATW.Stance and ATW.Stance() or 3

	-- Check for execute pooling
	local shouldPool, timeToExecute = Engine.ShouldPoolForExecute(state)

	---------------------------------------
	-- PRIORITY 1: Execute (any mob in execute range)
	---------------------------------------
	local executeGUID, executeUnit, executeHP = Engine.GetExecuteTarget()
	if executeGUID or executeUnit then
		local execCost = ATW.Talents and ATW.Talents.ExecCost or 15

		if rage >= execCost then
			local needsStance = (currentStance ~= 1 and currentStance ~= 3)

			if needsStance then
				return "Execute", false, false, 0, executeGUID, 3
			else
				return "Execute", false, false, 0, executeGUID, nil
			end
		end
	end

	---------------------------------------
	-- PRIORITY 2: Rend (RULE-BASED, not simulation)
	-- Uses HP% as primary signal - stable at combat start
	-- This ensures Rend is applied EARLY when it matters most
	---------------------------------------
	local rendPriority, rendReason = Engine.GetRendPriority()

	-- Apply Rend if priority > 50 (HP% > 50% or at pull)
	-- Only if we're not in execute phase and have rage
	if rendPriority >= 50 and not (executeGUID or executeUnit) then
		local rendCost = 10
		local danceRage = AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.DanceRage or 10

		-- In correct stance?
		local inRendStance = (currentStance == 1 or currentStance == 2)

		if inRendStance and rage >= rendCost then
			-- Can Rend immediately
			return "Rend", false, false, 0, nil, nil
		elseif not inRendStance and rage >= rendCost + danceRage then
			-- Need stance dance - recommend Rend, rotation handles dance
			return "Rend", true, false, 0, nil, 1  -- targetStance = 1 (Battle)
		end
		-- Not enough rage for Rend + dance, fall through to normal rotation
	end

	---------------------------------------
	-- PRIORITY 3: Rend on other enemies (via nameplates)
	-- No arbitrary threshold - let damage calculation decide
	-- Uses rule-based logic + per-GUID Rend tracking
	---------------------------------------
	local enemies = {}
	if ATW.GetEnemiesWithTTD then
		enemies = ATW.GetEnemiesWithTTD(5)  -- 5yd = Rend range
	end

	-- Process ANY enemies we find (no >= 2 threshold)
	if table.getn(enemies) >= 1 then
		-- Sort by HP% descending (prioritize high HP targets for Rend)
		table.sort(enemies, function(a, b)
			local aHP = (a.hp and a.maxHp and a.maxHp > 0) and (a.hp / a.maxHp) or 1
			local bHP = (b.hp and b.maxHp and b.maxHp > 0) and (b.hp / b.maxHp) or 1
			return aHP > bHP
		end)

		-- Find best Rend target that doesn't have Rend
		for _, enemy in ipairs(enemies) do
			if enemy.guid then
				-- Skip if already has Rend
				if enemy.hasRend then
					-- Skip this target
				else
					-- Get HP% for this target from nameplate
					local hpPercent = 100
					if enemy.hp and enemy.maxHp and enemy.maxHp > 0 then
						hpPercent = (enemy.hp / enemy.maxHp) * 100
					end

					-- ShouldApplyRendToGUID checks: has Rend, bleed immune, HP%
					local shouldRend, _ = Engine.ShouldApplyRendToGUID(enemy.guid, hpPercent, enemy.ttd)

					if shouldRend then
						local inRendStance = (currentStance == 1 or currentStance == 2)
						local rendCost = 10
						local danceRage = AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.DanceRage or 10

						if inRendStance and rage >= rendCost then
							return "Rend", false, false, 0, enemy.guid, nil
						elseif not inRendStance and rage >= rendCost + danceRage then
							return "Rend", true, false, 0, enemy.guid, 1
						end
					end
				end
			end
		end
	end

	---------------------------------------
	-- PRIORITY 4: Normal rotation (simulation-based)
	---------------------------------------
	local abilityName, isOffGCD = Engine.ChooseAbility(state)

	-- If pooling and ability isn't high priority, might want to wait
	local pooling = false
	if shouldPool and abilityName then
		if abilityName ~= "Bloodthirst" and abilityName ~= "Whirlwind" and
		   abilityName ~= "Execute" and abilityName ~= "Bloodrage" then
			pooling = true
		end
	end

	return abilityName, isOffGCD, pooling, timeToExecute / 1000, nil, nil
end

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
-- Debug: Print Rend decision info
---------------------------------------
function Engine.PrintRendDecision()
	ATW.Print("=== Rend Decision (Rule-Based) ===")

	-- Get current target info
	if not UnitExists("target") then
		ATW.Print("No target")
		return
	end

	local hp = UnitHealth("target")
	local maxHp = UnitHealthMax("target")
	local hpPercent = maxHp > 0 and (hp / maxHp) * 100 or 0

	ATW.Print("Target HP: " .. string.format("%.1f", hpPercent) .. "%")

	-- TTD status
	local ttd = ATW.GetTargetTTD and ATW.GetTargetTTD() or 999
	if ttd < 999 then
		ATW.Print("TTD: " .. string.format("%.1f", ttd) .. "s (available)")
	else
		ATW.Print("TTD: Unknown (using HP heuristic)")
	end

	-- Bleed immunity
	local isImmune = ATW.IsBleedImmune and ATW.IsBleedImmune("target")
	if isImmune then
		ATW.Print("|cffff0000BLEED IMMUNE|r")
	end

	-- Has Rend? (uses RendTracker + UnitDebuff)
	local hasRend = ATW.HasRend and ATW.HasRend("target")
	if hasRend then
		ATW.Print("Rend: |cff00ff00ACTIVE|r (tracked)")
	else
		ATW.Print("Rend: Not applied")
	end

	-- Decision
	local shouldRend, reason = Engine.ShouldApplyRend()
	local priority, _ = Engine.GetRendPriority()

	ATW.Print("")
	if shouldRend then
		ATW.Print("|cff00ff00SHOULD REND|r: " .. reason)
		ATW.Print("Priority: " .. string.format("%.0f", priority) .. "/100")
	else
		ATW.Print("|cffff0000DON'T REND|r: " .. reason)
	end

	-- Thresholds
	ATW.Print("")
	ATW.Print("Thresholds:")
	ATW.Print("  Full value: HP >= " .. Engine.REND_FULL_VALUE_HP .. "%")
	ATW.Print("  Minimum: HP >= " .. Engine.REND_MIN_HP .. "%")
	ATW.Print("  Min TTD: 9s (3 ticks)")
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
