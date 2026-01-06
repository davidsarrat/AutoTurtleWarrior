--[[
	Auto Turtle Warrior - Combat/Casting
	Spell casting functions (SuperWoW integration)
]]--

---------------------------------------
-- Cast with Target (SuperWoW GUID)
---------------------------------------
function ATW.Cast(spell, useTarget)
	if not spell then return end

	if useTarget then
		local _, guid = UnitExists("target")
		if guid and guid ~= "" then
			CastSpellByName(spell, guid)
		else
			CastSpellByName(spell)
		end
	else
		CastSpellByName(spell)
	end
end

---------------------------------------
-- Cast Self-Buff (no target needed)
---------------------------------------
function ATW.CastSelf(spell)
	local id = ATW.SpellID(spell)
	if id then
		CastSpell(id, BOOKTYPE_SPELL)
	end
end

---------------------------------------
-- Overpower Multi-Target Iteration
-- When a dodge happens, we don't know WHICH mob dodged
-- Each keypress tries the next nameplate target until Overpower lands
-- Returns: true if attempted cast, false if exhausted all targets
---------------------------------------
function ATW.TryNextOverpower()
	local state = ATW.State
	local iter = ATW.OverpowerIteration

	-- No Overpower proc active
	if not state.Overpower then
		iter.targets = {}
		iter.index = 0
		return false
	end

	-- Check if Overpower window expired (5 seconds)
	if GetTime() - state.Overpower > 5 then
		state.Overpower = nil
		iter.targets = {}
		iter.index = 0
		return false
	end

	-- Build target list if empty or stale (rebuild every new Overpower proc)
	if table.getn(iter.targets) == 0 or iter.lastBuild < state.Overpower then
		iter.targets = {}
		iter.index = 0
		iter.lastBuild = GetTime()

		-- Add current target FIRST (most likely to be the one that dodged)
		if UnitExists("target") and not UnitIsDead("target") then
			local _, targetGUID = UnitExists("target")
			if targetGUID and targetGUID ~= "" then
				table.insert(iter.targets, targetGUID)
			end
		end

		-- Add all nameplate enemies in melee range
		if ATW.GetEnemiesWithTTD then
			local enemies = ATW.GetEnemiesWithTTD(5)  -- 5yd melee range
			for _, enemy in ipairs(enemies) do
				-- Skip if already added (current target)
				local isDuplicate = false
				for _, existing in ipairs(iter.targets) do
					if existing == enemy.guid then
						isDuplicate = true
						break
					end
				end
				if not isDuplicate and enemy.guid then
					table.insert(iter.targets, enemy.guid)
				end
			end
		end

		ATW.Debug("Overpower: Built target list with " .. table.getn(iter.targets) .. " targets")
	end

	-- No targets to try
	if table.getn(iter.targets) == 0 then
		state.Overpower = nil
		return false
	end

	-- Move to next target
	iter.index = iter.index + 1

	-- Exhausted all targets? Reset and clear proc
	if iter.index > table.getn(iter.targets) then
		ATW.Debug("Overpower: Exhausted all " .. table.getn(iter.targets) .. " targets, clearing proc")
		state.Overpower = nil
		iter.targets = {}
		iter.index = 0
		return false
	end

	local guid = iter.targets[iter.index]
	ATW.Debug("Overpower: Trying target " .. iter.index .. "/" .. table.getn(iter.targets))

	-- Need Battle Stance for Overpower
	local stance = ATW.Stance and ATW.Stance() or 1
	if stance ~= 1 then
		-- Switch to Battle Stance first, will try cast on next keypress
		CastShapeshiftForm(1)
		-- Don't advance index - try same target after stance switch
		iter.index = iter.index - 1
		return true
	end

	-- Check if casting on a different target than current
	local _, currentTargetGUID = UnitExists("target")
	local castingOnDifferentTarget = (currentTargetGUID and guid ~= currentTargetGUID)

	-- SuperWoW GUID targeting: CastSpellByName(spell, unit) works with GUIDs
	-- The 2nd parameter accepts GUIDs in place of unit tokens ("target", "player")
	local ok = pcall(function()
		CastSpellByName("Overpower", guid)
	end)

	-- CRITICAL: After casting on nameplate, force auto-attack back to real target
	-- SuperWoW changes attack target when using CastSpellByName with GUID
	-- Must pass explicit GUID to avoid inheriting the nameplate as attack target
	if ok and castingOnDifferentTarget and currentTargetGUID then
		AttackTarget(currentTargetGUID)  -- Resume attacking the player's actual target
	end

	return true
end

---------------------------------------
-- Clear Overpower state (call when OP lands)
-- This is called from combat log parsing when we see Overpower hit
---------------------------------------
function ATW.OnOverpowerSuccess()
	ATW.State.Overpower = nil
	ATW.OverpowerIteration.targets = {}
	ATW.OverpowerIteration.index = 0
	ATW.Debug("Overpower: SUCCESS - cleared proc")
end
