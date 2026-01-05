--[[
	Auto Turtle Warrior - Rotation/Rotation
	DPR-based combat rotation using simulator
]]--

function ATW.Rotation()
	local cfg = AutoTurtleWarrior_Config
	local state = ATW.State

	-- Basic checks
	if not cfg.Enabled then return end
	if UnitClass("player") ~= "Warrior" then return end
	if not UnitExists("target") or UnitIsDead("target") then return end
	if not UnitCanAttack("player", "target") then return end

	-- Combat state
	local st = ATW.Stance()
	local rage = UnitMana("player")

	-- Auto attack
	if not state.Attacking then
		AttackTarget()
	end

	-- Clear expired states
	if state.Overpower and GetTime() - state.Overpower > 4 then
		state.Overpower = nil
	end
	if state.Interrupt and GetTime() - state.Interrupt > 2 then
		state.Interrupt = nil
	end

	---------------------------------------
	-- HS/Cleave Cancel Logic
	-- Check if we should cancel queued HS/Cleave
	-- (e.g., Execute target appeared, need rage for BT)
	---------------------------------------
	if ATW.ShouldCancelSwingAbility then
		local shouldCancel, reason = ATW.ShouldCancelSwingAbility()
		if shouldCancel then
			ATW.CancelSwingAbility()
			ATW.Debug("Canceled HS/Cleave: " .. reason)
		end
	end

	---------------------------------------
	-- Simulator-Based Priority
	---------------------------------------

	local abilityName, needsDance, targetStance, targetGUID = ATW.GetNextAbility()

	if not abilityName then
		ATW.Debug("No ability available")
		return
	end

	local ability = ATW.Abilities[abilityName]
	if not ability then
		ATW.Debug("Unknown ability: " .. abilityName)
		return
	end

	-- Handle stance dancing
	if needsDance and targetStance then
		if ATW.CanDance(rage) then
			return ATW.GoStance(targetStance, abilityName)
		else
			ATW.Debug("Need more rage to dance for " .. abilityName)
			return
		end
	end

	-- Check stance requirement
	if ability.stance and ability.stance[1] ~= 0 then
		local validStance = false
		for _, s in ipairs(ability.stance) do
			if s == st then
				validStance = true
				break
			end
		end
		if not validStance then
			if ATW.CanDance(rage) then
				return ATW.GoStance(ability.stance[1], abilityName)
			else
				ATW.Debug("Wrong stance for " .. abilityName)
				return
			end
		end
	end

	-- Execute the ability
	ATW.Debug(abilityName .. (targetGUID and " (GUID)" or ""))

	-- Determine cast method
	local isSelfBuff = (abilityName == "Bloodrage" or
	                    abilityName == "BattleShout" or
	                    abilityName == "DeathWish" or
	                    abilityName == "BerserkerRage" or
	                    abilityName == "Recklessness")

	if isSelfBuff then
		ATW.CastSelf(ability.name)

	-- GUID-based Execute (targets any mob in execute range)
	elseif abilityName == "Execute" then
		if targetGUID and ATW.Engine and ATW.Engine.CastExecuteOnGUID then
			-- Use GUID targeting to Execute specific mob
			ATW.Engine.CastExecuteOnGUID(targetGUID)
		else
			-- Fallback: cast on current target
			ATW.Cast(ability.name, true)
		end

	-- GUID-based Rend (for spreading to specific targets)
	-- NOTE: We do NOT track Rend here immediately because:
	-- 1. The cast might be resisted/immune
	-- 2. Combat log parsing will confirm when Rend actually ticks
	-- 3. ATW.HasRend() uses SuperWoW UnitDebuff as primary check
	elseif abilityName == "Rend" then
		if targetGUID and ATW.Engine and ATW.Engine.CastRendOnGUID then
			-- Use GUID targeting to Rend specific mob
			-- Store pending target WITH NAME for combat log verification
			-- This handles multiple mobs with same name correctly
			ATW.State.PendingRendGUID = targetGUID
			ATW.State.PendingRendTime = GetTime()
			-- Get name via SuperWoW for exact matching
			local ok, name = pcall(function() return UnitName(targetGUID) end)
			ATW.State.PendingRendName = ok and name or nil
			ATW.Engine.CastRendOnGUID(targetGUID)
		else
			-- Fallback: cast on current target
			ATW.Cast(ability.name, true)
			-- Store pending target WITH NAME for combat log verification
			if ATW.HasSuperWoW and ATW.HasSuperWoW() then
				local _, guid = UnitExists("target")
				if guid then
					ATW.State.PendingRendGUID = guid
					ATW.State.PendingRendTime = GetTime()
					ATW.State.PendingRendName = UnitName("target")
				end
			end
		end
		state.Dancing = true

	elseif abilityName == "Charge" then
		ATW.Cast(ability.name, true)
	elseif abilityName == "SweepingStrikes" then
		ATW.Cast(ability.name)
		state.Dancing = true
	elseif abilityName == "Whirlwind" then
		ATW.Cast(ability.name, true)
		state.Dancing = true
	elseif abilityName == "Overpower" then
		ATW.Cast(ability.name, true)
		state.Overpower = nil
		state.Dancing = true
	elseif abilityName == "HeroicStrike" or abilityName == "Cleave" then
		-- Swing queue ability
		ATW.Cast(ability.name, true)
		ATW.OnSwingAbilityQueued(ability.name)
	else
		-- Standard targeted ability
		ATW.Cast(ability.name, true)
	end

	-- Return to primary stance after dancing (if not in middle of combo)
	if state.Dancing and cfg.PrimaryStance ~= 0 then
		local btReady = ATW.Talents.HasBT and ATW.Ready("Bloodthirst")
		local wwReady = ATW.Ready("Whirlwind")
		-- Only return if main abilities are on CD
		if not btReady and not wwReady and st ~= cfg.PrimaryStance then
			if state.LastStance + 1.5 <= GetTime() and ATW.CanDance(rage) then
				ATW.GoStance(cfg.PrimaryStance, "Return")
				state.Dancing = nil
			end
		end
	end
end

---------------------------------------
-- Legacy Rotation (fallback)
-- Use this if simulator not working
---------------------------------------
function ATW.LegacyRotation()
	local cfg = AutoTurtleWarrior_Config
	local state = ATW.State
	local talents = ATW.Talents

	if not cfg.Enabled then return end
	if UnitClass("player") ~= "Warrior" then return end
	if not UnitExists("target") or UnitIsDead("target") then return end
	if not UnitCanAttack("player", "target") then return end

	local st = ATW.Stance()
	local rage = UnitMana("player")
	local thp = UnitHealth("target") / UnitHealthMax("target") * 100
	local exec = thp < 20
	local aoe = ATW.InAoE()

	if not state.Attacking then
		AttackTarget()
	end

	if state.Overpower and GetTime() - state.Overpower > 4 then
		state.Overpower = nil
	end
	if state.Interrupt and GetTime() - state.Interrupt > 2 then
		state.Interrupt = nil
	end

	-- Battle Shout
	if not ATW.Buff("player", "Ability_Warrior_BattleShout") and rage >= 10 and ATW.Ready("Battle Shout") then
		ATW.CastSelf("Battle Shout")
		return
	end

	-- Charge
	if not UnitAffectingCombat("player") and ATW.Ready("Charge") then
		local dist = ATW.GetDistance("target")
		if dist and dist >= 8 and dist <= 25 then
			if st == 1 then
				ATW.Cast("Charge", true)
				return
			elseif ATW.CanDance(rage) then
				return ATW.GoStance(1, "Charge")
			end
		end
	end

	-- Bloodrage
	if UnitAffectingCombat("player") and rage <= cfg.MaxRage and ATW.Ready("Bloodrage") then
		local hp = UnitHealth("player") / UnitHealthMax("player") * 100
		if hp >= 50 then
			ATW.CastSelf("Bloodrage")
			return
		end
	end

	-- Execute
	if exec and ATW.HasWeapon() and rage >= talents.ExecCost and ATW.Ready("Execute") then
		if st == 1 or st == 3 then
			ATW.Cast("Execute", true)
			return
		elseif ATW.CanDance(rage) then
			return ATW.GoStance(3, "Execute")
		end
	end

	-- Death Wish
	if talents.HasDW and rage >= 10 and ATW.Ready("Death Wish") and AutoTurtleWarrior_Config.UseCooldowns then
		ATW.CastSelf("Death Wish")
		return
	end

	-- Interrupt
	if state.Interrupt and rage >= 10 and ATW.Ready("Pummel") then
		if st == 3 or st == 1 then  -- TurtleWoW: Pummel in Battle too
			ATW.Cast("Pummel", true)
			return
		elseif ATW.CanDance(rage) then
			return ATW.GoStance(3, "Pummel")
		end
	end

	-- Sweeping Strikes
	if aoe and not ATW.Buff("player", "Ability_Rogue_SliceDice") and rage >= 30 and ATW.Ready("Sweeping Strikes") then
		if st == 1 then
			ATW.Cast("Sweeping Strikes")
			state.Dancing = true
			return
		elseif ATW.CanDance(rage) then
			return ATW.GoStance(1, "Sweeping Strikes")
		end
	end

	-- Whirlwind (AoE)
	if aoe and rage >= 25 and ATW.TargetInRange() and ATW.Ready("Whirlwind") then
		if st == 3 then
			ATW.Cast("Whirlwind", true)
			state.Dancing = true
			return
		elseif ATW.CanDance(rage) then
			return ATW.GoStance(3, "Whirlwind")
		end
	end

	-- Bloodthirst
	if talents.HasBT and rage >= 30 and ATW.Ready("Bloodthirst") then
		ATW.Cast("Bloodthirst", true)
		return
	end

	-- Mortal Strike
	if talents.HasMS and ATW.HasWeapon() and rage >= 30 and ATW.Ready("Mortal Strike") then
		ATW.Cast("Mortal Strike", true)
		return
	end

	-- Whirlwind (single target)
	if not aoe and rage >= 25 and ATW.TargetInRange() and ATW.Ready("Whirlwind") then
		if st == 3 then
			ATW.Cast("Whirlwind", true)
			state.Dancing = true
			return
		elseif ATW.CanDance(rage) then
			return ATW.GoStance(3, "Whirlwind")
		end
	end

	-- Overpower
	if state.Overpower and ATW.HasWeapon() and rage >= 5 and ATW.Ready("Overpower") then
		local btOK = talents.HasBT and ATW.Ready("Bloodthirst")
		local wwOK = ATW.Ready("Whirlwind")
		if not btOK and not wwOK then
			if st == 1 then
				ATW.Cast("Overpower", true)
				state.Overpower = nil
				state.Dancing = true
				return
			elseif ATW.CanDance(rage) then
				return ATW.GoStance(1, "Overpower")
			end
		end
	end

	-- Berserker Rage
	if talents.HasIBR and rage <= cfg.MaxRage and ATW.Ready("Berserker Rage") then
		if st == 3 then
			ATW.CastSelf("Berserker Rage")
			return
		elseif ATW.CanDance(rage) then
			return ATW.GoStance(3, "Berserker Rage")
		end
	end

	-- Return to stance
	if state.Dancing and state.OldStance and cfg.PrimaryStance ~= 0 and ATW.CanDance(rage) then
		if st ~= cfg.PrimaryStance and state.LastStance + 1.5 <= GetTime() then
			ATW.GoStance(cfg.PrimaryStance, "Return")
		end
		state.OldStance = nil
		state.Dancing = nil
		return
	end

	-- Rage dump
	local btCD = not talents.HasBT or not ATW.Ready("Bloodthirst")
	local msCD = not talents.HasMS or not ATW.Ready("Mortal Strike")
	local wwCD = not ATW.Ready("Whirlwind")

	if btCD and msCD and wwCD and rage >= cfg.HSRage then
		if aoe and rage >= 20 and ATW.Ready("Cleave") then
			ATW.Cast("Cleave", true)
			return
		end
		if ATW.HasWeapon() and rage >= talents.HSCost and ATW.Ready("Heroic Strike") then
			ATW.Cast("Heroic Strike", true)
			return
		end
	end
end
