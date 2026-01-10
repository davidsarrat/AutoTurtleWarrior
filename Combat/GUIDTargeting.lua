--[[
	Auto Turtle Warrior - Combat/GUIDTargeting
	GUID-based targeting for multi-target abilities
	Uses SuperWoW for nameplate GUID access

	Features:
	- Execute targeting: Find ANY mob in execute range (<20% HP)
	- Rend spreading: Target specific mobs without Rend (non-immune only)
]]--

ATW.GUIDTargeting = {}

---------------------------------------
-- Get best Execute target (GUID-based)
-- Returns: guid, targetId, hpPercent
-- Finds ANY mob in execute range (<20% HP)
---------------------------------------
function ATW.GUIDTargeting.GetExecuteTarget()
	-- First check current target
	if UnitExists("target") and not UnitIsDead("target") then
		local hp = UnitHealth("target")
		local maxHp = UnitHealthMax("target")
		if maxHp > 0 and (hp / maxHp) < 0.20 then
			local guid = nil
			if ATW.HasSuperWoW and ATW.HasSuperWoW() then
				local _, g = UnitExists("target")
				guid = g
			end
			return guid, "target", (hp / maxHp) * 100
		end
	end

	-- Check all tracked enemies via nameplates (SuperWoW)
	if not ATW.HasSuperWoW or not ATW.HasSuperWoW() then
		return nil, nil, 100
	end

	local bestTarget = nil
	local bestGUID = nil
	local lowestHP = 100

	-- Scan nameplates for execute targets
	for i = 1, 40 do
		local nameplate = _G["NamePlate" .. i]
		if nameplate and nameplate:IsVisible() then
			local guid = nameplate:GetName(1)
			if guid and guid ~= "" then
				local hp = nameplate.hp
				local maxHp = nameplate.hpMax

				if hp and maxHp and maxHp > 0 then
					local hpPercent = (hp / maxHp) * 100
					-- In execute range and lower HP than current best
					if hpPercent < 20 and hpPercent < lowestHP then
						-- Check if in melee range (using distance if available)
						local distance = nameplate.distance
						if not distance or distance <= 5 then
							lowestHP = hpPercent
							bestGUID = guid
							bestTarget = "nameplate" .. i
						end
					end
				end
			end
		end
	end

	return bestGUID, bestTarget, lowestHP
end

---------------------------------------
-- Cast Execute on GUID (SuperWoW feature)
-- Targets any mob in execute range
--
-- NOTE: Stance is handled by the simulator as a first-class action.
-- This function assumes we're already in the correct stance.
---------------------------------------
function ATW.GUIDTargeting.CastExecuteOnGUID(guid)
	-- Always get current target GUID for explicit targeting
	local _, targetGuid = UnitExists("target")

	if not guid then
		-- No GUID specified, use current target with explicit GUID
		if targetGuid and targetGuid ~= "" then
			CastSpellByName("Execute", targetGuid)
		else
			CastSpellByName("Execute")
		end
		return true
	end

	if not ATW.HasSuperWoW or not ATW.HasSuperWoW() then
		-- No SuperWoW, cast on current target with explicit GUID
		if targetGuid and targetGuid ~= "" then
			CastSpellByName("Execute", targetGuid)
		else
			CastSpellByName("Execute")
		end
		return true
	end

	-- Check if guid is current target - still use explicit GUID!
	if targetGuid == guid then
		CastSpellByName("Execute", targetGuid)
		return true
	end

	-- Casting on a different target than current (nameplate in execute range)
	-- SuperWoW GUID targeting: CastSpellByName(spell, unit) works with GUIDs
	local ok, err = pcall(function()
		CastSpellByName("Execute", guid)
	end)

	-- Flag that we need to restore AA to main target (will be handled next frame)
	-- This avoids calling AttackTarget() in the same frame as the cast
	if ok and targetGuid then
		ATW.State.NeedsAARestore = targetGuid
	end

	return ok
end

---------------------------------------
-- Get all enemies in execute range
-- Returns array of {guid, hpPercent, distance}
---------------------------------------
function ATW.GUIDTargeting.GetExecuteTargets()
	local targets = {}

	-- Check current target
	if UnitExists("target") and not UnitIsDead("target") then
		local hp = UnitHealth("target")
		local maxHp = UnitHealthMax("target")
		if maxHp > 0 and (hp / maxHp) < 0.20 then
			local guid = nil
			if ATW.HasSuperWoW and ATW.HasSuperWoW() then
				local _, g = UnitExists("target")
				guid = g
			end
			table.insert(targets, {
				guid = guid,
				unit = "target",
				hpPercent = (hp / maxHp) * 100,
				distance = 0,
			})
		end
	end

	-- Scan nameplates (SuperWoW)
	if ATW.HasSuperWoW and ATW.HasSuperWoW() then
		for i = 1, 40 do
			local nameplate = _G["NamePlate" .. i]
			if nameplate and nameplate:IsVisible() then
				local guid = nameplate:GetName(1)
				if guid and guid ~= "" then
					local hp = nameplate.hp
					local maxHp = nameplate.hpMax

					if hp and maxHp and maxHp > 0 then
						local hpPercent = (hp / maxHp) * 100
						if hpPercent < 20 then
							local distance = nameplate.distance or 0
							if distance <= 5 then
								table.insert(targets, {
									guid = guid,
									unit = "nameplate" .. i,
									hpPercent = hpPercent,
									distance = distance,
								})
							end
						end
					end
				end
			end
		end
	end

	-- Sort by HP (lowest first - prioritize finishing kills)
	table.sort(targets, function(a, b) return a.hpPercent < b.hpPercent end)

	return targets
end

---------------------------------------
-- Get next Rend target (GUID-based)
-- Returns: guid
-- For real-time rotation use (not simulation)
--
-- NOTE: Stance is handled by the simulator as a first-class action.
---------------------------------------
function ATW.GUIDTargeting.GetNextRendTarget()
	-- Get enemies in range
	local enemies = {}
	if ATW.GetEnemiesWithTTD then
		enemies = ATW.GetEnemiesWithTTD(5)  -- Rend is 5yd melee range
	end

	-- Find best target to Rend
	local bestTarget = nil
	local bestTTD = 0

	for _, enemy in ipairs(enemies) do
		-- Skip bleed immune targets
		local isImmune = false
		if enemy.guid and ATW.IsBleedImmuneGUID then
			isImmune = ATW.IsBleedImmuneGUID(enemy.guid)
		end

		if not isImmune and enemy.ttd >= 6 then  -- 6s minimum for 2+ ticks
			-- Check if already has Rend (would need debuff tracking per GUID)
			-- For now, prioritize by TTD
			if enemy.ttd > bestTTD then
				bestTTD = enemy.ttd
				bestTarget = enemy
			end
		end
	end

	if bestTarget then
		return bestTarget.guid
	end

	return nil
end

---------------------------------------
-- Cast Rend on GUID (SuperWoW feature)
-- Uses CastSpellByName with GUID targeting
-- IMPORTANT: Verifies range (5yd) AND GCD before casting
--
-- NOTE: Stance is handled by the simulator as a first-class action.
-- This function assumes we're already in the correct stance.
--
-- ROBUST DESIGN: SuperWoW's UNIT_CASTEVENT will confirm the cast
-- automatically if it succeeds.
---------------------------------------
function ATW.GUIDTargeting.CastRendOnGUID(guid)
	if not guid then return false end
	if not ATW.HasSuperWoW or not ATW.HasSuperWoW() then return false end

	-- CRITICAL: Verify GCD is ready before casting
	if ATW.Ready and not ATW.Ready("Rend") then
		if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
			ATW.Debug("Rend BLOCKED: GCD or spell CD active")
		end
		return false  -- GCD active, don't attempt
	end

	-- CRITICAL: Verify distance BEFORE casting (Rend is 5yd range)
	local rendRange = ATW.REND_RANGE or 5
	if ATW.GetDistance then
		local distance = ATW.GetDistance(guid)
		if distance and distance > rendRange then
			if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
				ATW.Debug("Rend BLOCKED: " .. string.format("%.1f", distance) .. "yd > " .. rendRange .. "yd")
			end
			return false  -- Out of range, don't attempt cast
		end
	end

	-- Check if casting on a different target than current
	local _, currentTargetGUID = UnitExists("target")
	local castingOnDifferentTarget = (currentTargetGUID and guid ~= currentTargetGUID)

	-- SuperWoW GUID targeting: CastSpellByName(spell, unit) works with GUIDs
	local castOk, err = pcall(function()
		CastSpellByName("Rend", guid)
	end)

	-- Flag that we need to restore AA to main target (will be handled next frame)
	-- This avoids calling AttackTarget() in the same frame as the cast
	if castOk and castingOnDifferentTarget and currentTargetGUID then
		ATW.State.NeedsAARestore = currentTargetGUID
	end

	return castOk
end

-- Note: Engine.lua creates aliases to these functions
-- Call via ATW.Engine.GetExecuteTarget() or ATW.GUIDTargeting.GetExecuteTarget()
