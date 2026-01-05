--[[
	Auto Turtle Warrior - Sim/Abilities
	Ability database with TurtleWoW-specific formulas
]]--

ATW.Abilities = {}

---------------------------------------
-- Ability Definitions
-- Each ability contains:
--   rage: base rage cost
--   cd: cooldown in seconds
--   stance: required stances (1=Battle, 2=Def, 3=Berserker, 0=any)
--   gcd: triggers GCD (false for off-GCD)
--   damage: function(stats) returns expected damage
--   condition: function(state) returns if usable
---------------------------------------

local Abilities = ATW.Abilities

---------------------------------------
-- Main Rotation Abilities
---------------------------------------

Abilities.Bloodthirst = {
	name = "Bloodthirst",
	rage = 30,
	cd = 6,
	stance = {3},  -- Berserker only
	gcd = true,
	isCooldown = false,
	damage = function(stats)
		-- TurtleWoW: AP * 0.45
		return stats.AP * 0.45
	end,
	condition = function(state)
		-- Need Berserker Stance and the talent
		if not ATW.AvailableStances[3] then
			return false
		end
		return ATW.Talents.HasBT
	end,
}

Abilities.Whirlwind = {
	name = "Whirlwind",
	rage = 25,  -- TurtleWoW reduced from 60
	cd = 10,    -- Base, reduced by Improved Whirlwind
	stance = {3},  -- Berserker only
	gcd = true,
	isCooldown = false,
	damage = function(stats)
		-- Normalized: WeaponDmg + (AP * weaponSpeed / 14)
		-- For dual wield, uses MH
		local weaponDmg = stats.MHDmg or 100
		local weaponSpeed = stats.MainHandSpeed or 2.6
		local apBonus = stats.AP * (weaponSpeed / 14)
		local baseDmg = weaponDmg + apBonus
		-- Multiply by targets hit (up to 4)
		local targets = math.min(ATW.EnemyCount() or 1, 4)
		return baseDmg * targets
	end,
	condition = function(state)
		-- Need Berserker Stance learned
		if not ATW.AvailableStances[3] then
			return false
		end
		return ATW.TargetInRange and ATW.TargetInRange()
	end,
}

Abilities.Execute = {
	name = "Execute",
	rage = 15,  -- Base, reduced by talents
	cd = 0,
	stance = {1, 3},  -- Battle or Berserker
	gcd = true,
	isCooldown = false,
	damage = function(stats, rageAvailable)
		-- TurtleWoW: 600 + (excessRage * 15)
		local cost = ATW.Talents.ExecCost or 15
		local excess = (rageAvailable or 30) - cost
		if excess < 0 then excess = 0 end
		return 600 + (excess * 15)
	end,
	condition = function(state)
		-- Only in execute phase (<20% HP)
		return ATW.InExecutePhase and ATW.InExecutePhase()
	end,
}

Abilities.MortalStrike = {
	name = "Mortal Strike",
	rage = 30,
	cd = 6,
	stance = {1, 3},  -- Battle or Berserker (with stance dance)
	gcd = true,
	isCooldown = false,
	damage = function(stats)
		-- Weapon damage + 160 (rank 4)
		local weaponDmg = stats.MHDmg or 100
		return weaponDmg + 160
	end,
	condition = function(state)
		return ATW.Talents.HasMS and ATW.HasWeapon and ATW.HasWeapon()
	end,
}

Abilities.Overpower = {
	name = "Overpower",
	rage = 5,
	cd = 5,
	stance = {1},  -- Battle only
	gcd = true,
	isCooldown = false,
	damage = function(stats)
		-- Weapon damage + 35, cannot be blocked/dodged/parried, +50% crit from talents
		local weaponDmg = stats.MHDmg or 100
		-- Higher effective damage due to guaranteed hit and crit bonus
		local critBonus = 1 + ((stats.Crit + 50) / 100)
		return (weaponDmg + 35) * critBonus * 0.6  -- Weighted for expected value
	end,
	condition = function(state)
		return ATW.State.Overpower and ATW.HasWeapon and ATW.HasWeapon()
	end,
}

Abilities.Slam = {
	name = "Slam",
	rage = 15,
	cd = 0,
	stance = {0},  -- Any stance
	gcd = true,  -- Has cast time, not instant
	isCooldown = false,
	damage = function(stats)
		-- TurtleWoW: Weapon + normalized AP + 87, pauses swing timer
		local weaponDmg = stats.MHDmg or 100
		local weaponSpeed = stats.MainHandSpeed or 2.6
		local apBonus = stats.AP * (weaponSpeed / 14)
		return weaponDmg + apBonus + 87
	end,
	condition = function(state)
		-- Only worth using with 2H (check for no offhand)
		return not ATW.Stats.HasOffHand
	end,
}

---------------------------------------
-- Rage Dumps
---------------------------------------

Abilities.HeroicStrike = {
	name = "Heroic Strike",
	rage = 15,  -- Base, reduced by talents
	cd = 0,
	stance = {0},  -- Any stance
	gcd = false,  -- On next swing, not instant
	isCooldown = false,
	damage = function(stats)
		-- Weapon damage + 157 (rank 9), replaces white hit
		-- NOT normalized, uses actual weapon speed
		local weaponDmg = stats.MHDmg or 100
		local weaponSpeed = stats.MainHandSpeed or 2.6
		local apBonus = stats.AP * (weaponSpeed / 14)
		return weaponDmg + apBonus + 157
	end,
	condition = function(state)
		return ATW.HasWeapon and ATW.HasWeapon()
	end,
	-- Special: replaces white hit, so effective cost includes lost rage gen
	effectiveRage = function(stats)
		local cost = ATW.Talents.HSCost or 15
		-- Lost rage from white hit (~10-15 rage typically)
		local lostRage = 10
		return cost + lostRage
	end,
}

Abilities.Cleave = {
	name = "Cleave",
	rage = 20,
	cd = 0,
	stance = {0},  -- Any stance
	gcd = false,  -- On next swing
	isCooldown = false,
	damage = function(stats)
		-- Cleave hits main target + 1 additional (max 2 total)
		-- Uses actual enemy count - no arbitrary threshold
		-- DPR will naturally favor HS over Cleave when only 1 target
		local weaponDmg = stats.MHDmg or 100
		local weaponSpeed = stats.MainHandSpeed or 2.6
		local apBonus = stats.AP * (weaponSpeed / 14)
		local singleDmg = weaponDmg + apBonus + 50

		-- Actual targets hit (max 2 for Cleave) at 8yd range
		local targets = 1
		if ATW.EnemyCount then
			targets = math.min(ATW.EnemyCount(8) or 1, 2)
		end

		return singleDmg * targets
	end,
	-- No condition - let DPR comparison decide
	-- With 1 target: Cleave DPR = HS DPR * (15/20) = 75% of HS
	-- With 2 targets: Cleave DPR = 2 * HS DPR * (15/20) = 150% of HS
	condition = nil,
	effectiveRage = function(stats)
		return 20 + 10  -- Cost + lost white rage
	end,
}

---------------------------------------
-- Cooldowns (isCooldown = true)
---------------------------------------

Abilities.DeathWish = {
	name = "Death Wish",
	rage = 10,
	cd = 180,  -- 3 minutes
	stance = {0},  -- Any stance
	gcd = false,  -- Off-GCD
	isCooldown = true,
	duration = 30,
	effect = "20% damage increase",
	damage = function(stats)
		return 0  -- Buff, no direct damage
	end,
	condition = function(state)
		return ATW.Talents.HasDW
	end,
}

Abilities.Recklessness = {
	name = "Recklessness",
	rage = 0,
	cd = 1800,  -- 30 minutes
	stance = {3},  -- Berserker only
	gcd = false,  -- Off-GCD
	isCooldown = true,
	duration = 15,
	effect = "100% crit chance, +20% damage taken",
	damage = function(stats)
		return 0
	end,
	condition = function(state)
		-- Need Berserker Stance
		return ATW.AvailableStances[3]
	end,
}

Abilities.BerserkerRage = {
	name = "Berserker Rage",
	rage = 0,
	cd = 30,
	stance = {3},  -- Berserker only
	gcd = false,  -- Off-GCD
	isCooldown = false,  -- Short CD, use on rotation
	duration = 10,
	effect = "Immune to fear, generates rage when hit",
	damage = function(stats)
		return 0
	end,
	condition = function(state)
		-- Need Berserker Stance and the talent
		if not ATW.AvailableStances[3] then
			return false
		end
		return ATW.Talents.HasIBR
	end,
}

---------------------------------------
-- Utility
---------------------------------------

Abilities.Bloodrage = {
	name = "Bloodrage",
	rage = 0,  -- Generates rage
	cd = 60,
	stance = {0},  -- Any stance
	gcd = false,  -- Off-GCD
	isCooldown = false,
	rageGen = 20,  -- 10 instant + 10 over time (TurtleWoW also procs Enrage)
	damage = function(stats)
		return 0
	end,
	condition = function(state)
		local hp = ATW.GetHealthPercent and ATW.GetHealthPercent() or 100
		return hp >= 50
	end,
}

Abilities.BattleShout = {
	name = "Battle Shout",
	rage = 10,
	cd = 0,
	stance = {0},
	gcd = true,
	isCooldown = false,
	duration = 120,  -- 2 minutes
	effect = "Increases AP",
	damage = function(stats)
		return 0
	end,
	condition = function(state)
		return not ATW.Buff("player", "Ability_Warrior_BattleShout")
	end,
}

Abilities.SweepingStrikes = {
	name = "Sweeping Strikes",
	rage = 30,
	cd = 30,
	stance = {1},  -- Battle only
	gcd = true,
	isCooldown = false,
	duration = 10,  -- Or 5 swings
	effect = "Next 5 attacks hit additional target",
	damage = function(stats)
		return 0  -- Buff effect
	end,
	condition = function(state)
		return ATW.EnemyCount and ATW.EnemyCount() >= 2 and
		       not ATW.Buff("player", "Ability_Rogue_SliceDice")
	end,
}

Abilities.Pummel = {
	name = "Pummel",
	rage = 10,
	cd = 10,
	stance = {1, 3},  -- TurtleWoW: Battle and Berserker
	gcd = false,  -- Off-GCD interrupt
	isCooldown = false,
	damage = function(stats)
		-- TurtleWoW: 5% of AP
		return stats.AP * 0.05
	end,
	condition = function(state)
		return ATW.State.Interrupt
	end,
}

Abilities.Hamstring = {
	name = "Hamstring",
	rage = 10,
	cd = 0,
	stance = {1, 3},
	gcd = true,
	isCooldown = false,
	damage = function(stats)
		return 45  -- Rank 3
	end,
	condition = function(state)
		return true
	end,
}

Abilities.Rend = {
	name = "Rend",
	rage = 10,
	cd = 0,
	stance = {1, 2},  -- Battle and Defensive
	gcd = true,
	isCooldown = false,
	-- TurtleWoW: Rend scales with AP (5% AP per tick)
	-- Base damage and ticks are dynamic based on spell rank
	damage = function(stats)
		-- Base damage from rank (includes Improved Rend talent)
		local baseDmg = ATW.GetRendDamage and ATW.GetRendDamage() or 147
		-- AP scaling: 5% per tick * number of ticks
		local ticks = ATW.GetRendTicks and ATW.GetRendTicks() or 7
		local apScaling = stats.AP * 0.05 * ticks
		local singleTargetDmg = baseDmg + apScaling

		-- Check optimal strategy using time-based simulation
		if ATW.FindOptimalStrategy then
			local strategy, gain = ATW.FindOptimalStrategy()
			if strategy == "rend_spread" and gain > 0 then
				-- Boost damage value to increase priority
				return singleTargetDmg * (1 + gain/100)
			end
		end

		return singleTargetDmg
	end,
	condition = function(state)
		-- Check if Rend is learned
		if ATW.Spells and not ATW.Spells.HasRend then
			return false
		end

		-- Check if target is immune to bleeds (Mechanical, Elemental, Undead)
		if ATW.IsBleedImmune then
			local immune, creatureType = ATW.IsBleedImmune("target")
			if immune then
				return false
			end
		end

		-- Check if Rend spreading is optimal using time-based simulation
		if ATW.FindOptimalStrategy then
			local strategy, gain = ATW.FindOptimalStrategy()
			if strategy == "rend_spread" and gain > 0 then
				-- Rend spreading mode: allow usage
				return true
			end
		end

		-- Single target mode: don't use on targets that will die soon
		local ttd = ATW.GetTargetTTD and ATW.GetTargetTTD() or 30
		if ttd < 15 then return false end

		-- Don't use if already applied (uses RendTracker + UnitDebuff)
		if ATW.HasRend and ATW.HasRend("target") then
			return false
		end

		return true
	end,
	-- Priority modifier: dynamic based on strategy simulation
	priorityMod = function()
		if ATW.FindOptimalStrategy then
			local strategy, gain = ATW.FindOptimalStrategy()
			if strategy == "rend_spread" then
				-- Scale priority based on damage gain
				if gain >= 5 then
					return 1.3  -- Very high priority (5%+ gain)
				elseif gain >= 2 then
					return 1.1  -- High priority (2-5% gain)
				elseif gain > 0 then
					return 0.9  -- Medium priority (0-2% gain)
				end
			end
		end
		return 0.5  -- Lower priority single target
	end,
}

Abilities.SunderArmor = {
	name = "Sunder Armor",
	rage = 15,
	cd = 0,
	stance = {1, 2},  -- Battle and Defensive
	gcd = true,
	isCooldown = false,
	damage = function(stats)
		-- No direct damage, but increases subsequent damage
		-- Each stack reduces armor by 450 (up to 5 stacks = 2250 armor)
		-- Effective DPS increase ~5-15% depending on target armor
		return 0
	end,
	condition = function(state)
		-- Only if not at 5 stacks already
		-- Check debuff count (hard to do in vanilla API)
		local ttd = ATW.GetTargetTTD and ATW.GetTargetTTD() or 30
		if ttd < 20 then return false end  -- Not worth on short fights
		-- Usually the tank handles this, skip for DPS rotation
		return false  -- Disabled by default for Fury
	end,
	priorityMod = 0.3,
}

Abilities.Charge = {
	name = "Charge",
	rage = 0,  -- Generates rage
	cd = 15,
	stance = {1},  -- Battle only
	gcd = true,
	isCooldown = false,
	rageGen = 15,  -- Generates 9-15 rage
	damage = function(stats)
		return 0
	end,
	condition = function(state)
		if UnitAffectingCombat("player") then return false end
		local dist = ATW.GetDistance and ATW.GetDistance("target")
		return dist and dist >= 8 and dist <= 25
	end,
}

---------------------------------------
-- Helper to get ability by name
---------------------------------------
function ATW.GetAbility(name)
	return Abilities[name]
end

---------------------------------------
-- Get rage cost accounting for talents
---------------------------------------
function ATW.GetRageCost(abilityName)
	local ability = Abilities[abilityName]
	if not ability then return 0 end

	if abilityName == "HeroicStrike" then
		return ATW.Talents.HSCost or 15
	elseif abilityName == "Execute" then
		return ATW.Talents.ExecCost or 15
	end

	return ability.rage
end
