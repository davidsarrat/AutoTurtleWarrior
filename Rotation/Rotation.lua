--[[
	Auto Turtle Warrior - Rotation/Rotation
	100% Simulation-based combat rotation

	SIMULATION-BASED STANCE SYSTEM:
	The simulator treats stance switches as explicit actions.
	When a stance switch is recommended, we execute CastShapeshiftForm.
	The next keypress will then get the actual ability.

	This is the most simulation-based approach possible:
	- Simulator decides EVERYTHING based on DPS calculations
	- Berserker stance valued for +3% crit
	- Battle stance valued for enabling Overpower, Charge, Rend
	- No hardcoded "if wrong stance then switch" logic

	OFF-GCD CHAINING:
	After casting an off-GCD ability (Perception, Blood Fury, etc.), the rotation
	immediately re-evaluates and casts the next action without requiring another
	keypress. This allows sequences like Perception -> Charge in one keypress.
]]--

-- Chain depth tracker to prevent infinite loops
local MAX_OFF_GCD_CHAINS = 3

function ATW.Rotation(chainDepth)
	-- Initialize chain depth (prevents infinite recursion)
	chainDepth = chainDepth or 0
	if chainDepth > MAX_OFF_GCD_CHAINS then
		ATW.Debug("Max off-GCD chain depth reached")
		return
	end

	local cfg = AutoTurtleWarrior_Config
	local state = ATW.State

	-- Basic checks
	if not cfg.Enabled then return end
	if UnitClass("player") ~= "Warrior" then return end

	local rage = UnitMana("player")

	---------------------------------------
	-- Self-buffs that don't need a target (Battle Shout, etc.)
	-- Check BEFORE target requirement
	---------------------------------------
	local hasTarget = UnitExists("target") and not UnitIsDead("target") and UnitCanAttack("player", "target")

	if not hasTarget then
		-- No target - only allow self-buffs
		if not ATW.Buff("player", "Ability_Warrior_BattleShout") and rage >= 10 and ATW.Ready("Battle Shout") then
			ATW.CastSelf("Battle Shout")
			ATW.Debug("Battle Shout (no target)")
			return
		end
		-- No target and no buffs to cast
		return
	end

	-- From here on, we have a valid target

	---------------------------------------
	-- AA Target Restore (after GUID cast to nameplate)
	-- If we cast on a nameplate last frame, restore AA to main target
	-- This is done here (next frame) to avoid conflicts with same-frame cast
	---------------------------------------
	if state.NeedsAARestore then
		local restoreGUID = state.NeedsAARestore
		state.NeedsAARestore = nil  -- Clear flag first to prevent loops

		-- Only restore if we're still targeting the same unit
		local _, currentTargetGUID = UnitExists("target")
		if currentTargetGUID and currentTargetGUID == restoreGUID then
			AttackTarget()  -- Force AA back to current target
			ATW.Debug("AA restored to main target")
		end
	end

	-- Combat state
	local st = ATW.Stance()

	-- Check for Charge BEFORE starting auto-attack (Charge requires out of combat)
	-- Only if not in combat and target is in Charge range (8-25 yards)
	if not UnitAffectingCombat("player") then
		local dist = ATW.GetDistance and ATW.GetDistance("target") or nil
		if dist and dist >= 8 and dist <= 25 and ATW.Ready("Charge") then
			-- Charge available! Don't auto-attack yet, let simulator recommend Charge
			ATW.Debug("Charge range: " .. string.format("%.1f", dist) .. "yd")
		else
			-- Not in Charge range or Charge not ready, start auto-attack
			if not state.Attacking then
				AttackTarget()
			end
		end
	else
		-- Already in combat, just auto-attack
		if not state.Attacking then
			AttackTarget()
		end
	end

	-- Clear expired states
	-- Overpower proc window: 4 seconds (vanilla mechanic)
	if state.Overpower and GetTime() - state.Overpower > 4 then
		state.Overpower = nil
	end
	-- Interrupt window: depends on cast time, but clear old legacy state
	if state.Interrupt and GetTime() - state.Interrupt > 10 then
		-- 10 second safety timeout (most casts are shorter)
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
	-- The simulator returns either:
	-- 1. A stance switch action (isStanceSwitch=true) -> CastShapeshiftForm
	-- 2. An ability to cast -> execute normally
	---------------------------------------

	local abilityName, isStanceSwitch, targetStance, targetGUID, isOffGCD = ATW.GetNextAbility()

	if not abilityName then
		ATW.Debug("No ability available")
		return
	end

	---------------------------------------
	-- STANCE SWITCH ACTIONS
	-- The simulator decided a stance switch is the best action
	-- This is a first-class action, not a side effect
	---------------------------------------
	if isStanceSwitch and targetStance then
		ATW.Debug("Stance -> " .. targetStance)
		CastShapeshiftForm(targetStance)
		return
	end

	---------------------------------------
	-- ABILITY EXECUTION
	-- Simulator decided this ability is best
	-- We're already in the correct stance (simulator wouldn't pick otherwise)
	---------------------------------------
	local ability = ATW.Abilities[abilityName]
	if not ability then
		ATW.Debug("Unknown ability: " .. abilityName)
		return
	end

	-- Execute the ability
	ATW.Debug(abilityName .. (targetGUID and " (GUID)" or ""))

	-- Determine cast method
	local isSelfBuff = (abilityName == "Bloodrage" or
	                    abilityName == "BattleShout" or
	                    abilityName == "DeathWish" or
	                    abilityName == "BerserkerRage" or
	                    abilityName == "Recklessness" or
	                    -- Racial abilities (self-buffs)
	                    abilityName == "BloodFury" or
	                    abilityName == "Berserking" or
	                    abilityName == "Perception")

	-- TRUE off-GCD abilities that don't trigger GCD in vanilla WoW
	-- These can chain into the next action immediately
	local isTrueOffGCD = (abilityName == "Bloodrage" or
	                      abilityName == "BerserkerRage" or
	                      abilityName == "BloodFury" or
	                      abilityName == "Berserking" or
	                      abilityName == "Perception")

	if isSelfBuff then
		-- BLOODRAGE CHARGE BLOCK: Don't cast Bloodrage if Charge is available
		-- (Bloodrage puts us in combat, preventing Charge)
		-- The simulator still computes it for timeline, but we block execution here
		if abilityName == "Bloodrage" and not UnitAffectingCombat("player") then
			local dist = ATW.GetDistance and ATW.GetDistance("target") or nil
			if dist and dist >= 8 and dist <= 25 and ATW.Ready("Charge") then
				ATW.Debug("Bloodrage blocked: Charge available")
				-- Instead of chaining (simulator would return Bloodrage again),
				-- directly handle Charge or stance switch
				local currentStance = ATW.Stance()
				if currentStance == 1 then
					-- Already in Battle Stance, cast Charge directly
					ATW.Cast("Charge", true)
				else
					-- Need stance switch first
					ATW.Debug("Stance -> Battle for Charge")
					CastShapeshiftForm(1)
				end
				return
			end
		end

		-- ability.name contains the actual spell name (from Abilities.lua)
		ATW.CastSelf(ability.name)

		-- OFF-GCD CHAINING: After casting a true off-GCD ability,
		-- immediately evaluate and cast the next action
		if isTrueOffGCD then
			ATW.Debug("Off-GCD chain: " .. abilityName .. " -> evaluating next")
			-- Recursively call Rotation to get and cast the next action
			ATW.Rotation(chainDepth + 1)
		end
		return

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
	-- ROBUST: UNIT_CASTEVENT confirms successful casts automatically
	elseif abilityName == "Rend" then
		if targetGUID and ATW.Engine and ATW.Engine.CastRendOnGUID then
			-- Use GUID targeting to Rend specific mob
			-- CastRendOnGUID verifies GCD and range before casting
			ATW.Engine.CastRendOnGUID(targetGUID)
		else
			-- Fallback: cast on current target
			ATW.Cast(ability.name, true)
		end

	elseif abilityName == "Charge" then
		-- Verify distance (8-25 yards) and out of combat before executing
		local dist = ATW.GetDistance and ATW.GetDistance("target") or nil
		if dist and dist >= 8 and dist <= 25 and not UnitAffectingCombat("player") then
			ATW.Cast(ability.name, true)
		else
			ATW.Debug("Charge: not in range or in combat")
			return
		end

	-- PUMMEL (Interrupt) - GUID targeting for nameplates
	elseif abilityName == "Pummel" then
		if targetGUID and ATW.ExecuteInterrupt then
			-- Use interrupt system with GUID targeting
			ATW.ExecuteInterrupt(targetGUID)
			-- NOTE: Do NOT clear state.Interrupt here!
			-- Guardrail will detect when Pummel goes on cooldown and clear it automatically
		else
			-- Fallback: cast on current target
			ATW.Cast(ability.name, true)
			-- NOTE: Do NOT clear state.Interrupt!
			-- Guardrail will handle clearing when Pummel goes on CD
		end

	elseif abilityName == "SweepingStrikes" then
		-- Self-buff: use CastSelf to avoid inheriting spell target from nameplate
		ATW.CastSelf(ability.name)

	elseif abilityName == "Whirlwind" then
		ATW.Cast(ability.name, true)

	elseif abilityName == "Overpower" then
		-- Use multi-target iteration: tries each nameplate until OP lands
		-- Current target is tried first, then nameplates in melee range
		if ATW.TryNextOverpower then
			ATW.TryNextOverpower()
		else
			-- Fallback if iteration function not available
			ATW.Cast(ability.name, true)
		end
		-- NOTE: Do NOT clear state.Overpower here!
		-- Guardrail will detect when Overpower goes on cooldown and clear it automatically

	elseif abilityName == "HeroicStrike" or abilityName == "Cleave" then
		-- CRITICAL: Check if already queued - calling again would TOGGLE (cancel) it!
		-- This is a failsafe in case the simulator cache didn't update fast enough
		local currentlyQueued = ATW.GetQueuedSwing and ATW.GetQueuedSwing()
		if currentlyQueued then
			-- Already queued, don't call again or it will cancel
			ATW.Debug("HS/Cleave already queued, skipping")
			return
		end

		-- Swing queue ability - but MUST specify target GUID to reset spell target!
		-- After casting Rend/OP on nameplate, SuperWoW keeps that as "spell target"
		-- We need to explicitly set target GUID to ensure HS/Cleave go to current target
		local _, targetGUID = UnitExists("target")
		if targetGUID and targetGUID ~= "" then
			CastSpellByName(ability.name, targetGUID)
		else
			CastSpellByName(ability.name)
		end
		ATW.OnSwingAbilityQueued(ability.name)

	elseif abilityName == "Slam" then
		-- Slam has cast time, use standard cast
		ATW.Cast(ability.name, true)

	else
		-- Standard targeted ability
		ATW.Cast(ability.name, true)
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

	-- Death Wish (controlled by Burst toggle)
	if ATW.IsCooldownAllowed("DeathWish") and talents.HasDW and rage >= 10 and ATW.Ready("Death Wish") then
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
			ATW.CastSelf("Sweeping Strikes")
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
