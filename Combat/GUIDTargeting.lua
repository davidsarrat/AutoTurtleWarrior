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
---------------------------------------
function ATW.GUIDTargeting.CastExecuteOnGUID(guid)
	if not guid then
		-- No GUID specified, try current target
		CastSpellByName("Execute")
		return true
	end

	if not ATW.HasSuperWoW or not ATW.HasSuperWoW() then
		-- No SuperWoW, just cast on current target
		CastSpellByName("Execute")
		return true
	end

	local currentStance = ATW.Stance and ATW.Stance() or 3

	-- Need Battle or Berserker stance for Execute
	if currentStance ~= 1 and currentStance ~= 3 then
		CastShapeshiftForm(3)  -- Go to Berserker
		return false  -- Will cast next frame
	end

	-- Check if guid is current target
	local _, targetGuid = UnitExists("target")
	if targetGuid == guid then
		CastSpellByName("Execute")
		return true
	end

	-- SuperWoW GUID targeting
	local ok, err = pcall(function()
		if CastSpellByNameAtUnit then
			CastSpellByNameAtUnit("Execute", guid)
		else
			-- Fallback: target swap
			local oldTarget = UnitGUID and UnitGUID("target") or targetGuid
			TargetUnit(guid)
			CastSpellByName("Execute")
			if oldTarget then
				TargetUnit(oldTarget)
			end
		end
	end)

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
-- Returns: guid, needsStanceDance
-- For real-time rotation use (not simulation)
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

		if not isImmune and enemy.ttd >= 15 then
			-- Check if already has Rend (would need debuff tracking per GUID)
			-- For now, prioritize by TTD
			if enemy.ttd > bestTTD then
				bestTTD = enemy.ttd
				bestTarget = enemy
			end
		end
	end

	if bestTarget then
		local currentStance = ATW.Stance and ATW.Stance() or 3
		local needsStance = (currentStance ~= 1 and currentStance ~= 2)
		return bestTarget.guid, needsStance
	end

	return nil, false
end

---------------------------------------
-- Cast Rend on GUID (SuperWoW feature)
-- Uses CastSpellByName with GUID targeting
---------------------------------------
function ATW.GUIDTargeting.CastRendOnGUID(guid)
	if not guid then return false end
	if not ATW.HasSuperWoW or not ATW.HasSuperWoW() then return false end

	local currentStance = ATW.Stance and ATW.Stance() or 3

	-- Need Battle or Defensive stance for Rend
	if currentStance ~= 1 and currentStance ~= 2 then
		-- Switch to Battle Stance first
		CastShapeshiftForm(1)
		return false  -- Will cast next frame after stance switch
	end

	-- SuperWoW allows targeting by GUID
	local ok, err = pcall(function()
		-- Method 1: Direct GUID targeting (if supported)
		if CastSpellByNameAtUnit then
			CastSpellByNameAtUnit("Rend", guid)
		else
			-- Method 2: Target, cast, target back
			local _, oldTarget = UnitExists("target")
			TargetUnit(guid)
			CastSpellByName("Rend")
			if oldTarget then
				TargetUnit(oldTarget)
			end
		end
	end)

	return ok
end

-- Note: Engine.lua creates aliases to these functions
-- Call via ATW.Engine.GetExecuteTarget() or ATW.GUIDTargeting.GetExecuteTarget()
