--[[
	Auto Turtle Warrior - Detection/CreatureType
	Creature type detection and bleed immunity checks

	Uses multiple detection methods:
	1. SuperWoW UnitCreatureType(guid) - direct GUID query
	2. Cache from target/mouseover events - learned over time
	3. Name-based cache - for units we've seen before
]]--

---------------------------------------
-- Types immune to bleed effects (Rend, Deep Wounds, etc)
-- These creature types do not have blood to bleed
---------------------------------------
ATW.BleedImmuneTypes = {
	-- English
	["Mechanical"] = true,
	["Elemental"] = true,
	["Undead"] = true,
	-- Spanish
	["Mecánico"] = true,
	["No-muerto"] = true,
	-- German
	["Mechanisch"] = true,
	["Elementar"] = true,
	["Untot"] = true,
	-- French
	["Mécanique"] = true,
	["Élémentaire"] = true,
	["Mort-vivant"] = true,
	-- Note: "Elemental" is same in Spanish/English
}

---------------------------------------
-- Cache for creature types
-- Stored by both GUID and name for redundancy
---------------------------------------
ATW.CreatureTypeCache = {
	byGUID = {},        -- {[guid] = {type, classification, time}}
	byName = {},        -- {[name] = {type, classification}}
	CACHE_DURATION = 300,  -- 5 minutes for GUID cache
}

---------------------------------------
-- Store creature type in cache
-- Called when we learn a creature's type (target, mouseover)
---------------------------------------
function ATW.CacheCreatureType(guid, name, creatureType, classification)
	if not creatureType then return end

	local now = GetTime()

	-- Cache by GUID
	if guid and guid ~= "" then
		ATW.CreatureTypeCache.byGUID[guid] = {
			type = creatureType,
			classification = classification,
			time = now,
		}
	end

	-- Cache by name (permanent, for fallback)
	if name and name ~= "" then
		ATW.CreatureTypeCache.byName[name] = {
			type = creatureType,
			classification = classification,
		}
	end

	-- Debug output
	if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
		local shortGUID = guid and string.sub(guid, 1, 8) or "nil"
		ATW.Debug("CreatureCache: " .. (name or "?") .. " = " .. creatureType ..
			" (" .. (classification or "normal") .. ") [" .. shortGUID .. "]")
	end
end

---------------------------------------
-- Get cached creature type by GUID
-- Returns: creatureType, classification or nil, nil
---------------------------------------
function ATW.GetCachedCreatureType(guid)
	if not guid then return nil, nil end

	local data = ATW.CreatureTypeCache.byGUID[guid]
	if data then
		-- Check if cache is still valid
		local now = GetTime()
		if now - data.time < ATW.CreatureTypeCache.CACHE_DURATION then
			return data.type, data.classification
		else
			-- Expired, remove
			ATW.CreatureTypeCache.byGUID[guid] = nil
		end
	end

	return nil, nil
end

---------------------------------------
-- Get cached creature type by name (fallback)
-- Returns: creatureType, classification or nil, nil
---------------------------------------
function ATW.GetCachedCreatureTypeByName(name)
	if not name then return nil, nil end

	local data = ATW.CreatureTypeCache.byName[name]
	if data then
		return data.type, data.classification
	end

	return nil, nil
end

---------------------------------------
-- Learn creature type from current target
-- Call this on PLAYER_TARGET_CHANGED
---------------------------------------
function ATW.LearnTargetCreatureType()
	if not UnitExists("target") then return end
	if UnitIsPlayer("target") then return end

	local name = UnitName("target")
	local creatureType = UnitCreatureType("target")
	local classification = UnitClassification("target")

	if creatureType then
		local guid = nil
		if ATW.HasSuperWoW and ATW.HasSuperWoW() then
			local _, g = UnitExists("target")
			guid = g
		end

		ATW.CacheCreatureType(guid, name, creatureType, classification)
	end
end

---------------------------------------
-- Check if a unit is immune to bleed effects
-- Returns: isImmune, creatureType
---------------------------------------
function ATW.IsBleedImmune(unit)
	if not unit then return false, nil end

	-- Get creature type
	local creatureType = UnitCreatureType(unit)
	local classification = UnitClassification(unit)

	-- Cache it if we have SuperWoW
	if creatureType and ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local name = UnitName(unit)
		local _, guid = UnitExists(unit)
		if guid then
			ATW.CacheCreatureType(guid, name, creatureType, classification)
		end
	end

	if not creatureType then
		return false, nil
	end

	-- Check if it's a boss (bosses can bleed even if elemental/undead)
	-- This follows vanilla/TurtleWoW mechanics where raid bosses
	-- are not immune to bleeds regardless of creature type
	if classification == "worldboss" or classification == "rareelite" then
		return false, creatureType
	end

	-- Check if type is immune
	if ATW.BleedImmuneTypes[creatureType] then
		return true, creatureType
	end

	return false, creatureType
end

---------------------------------------
-- Check creature type for a GUID (SuperWoW nameplate)
-- Uses multiple fallback methods:
-- 1. SuperWoW UnitCreatureType(guid) - direct query
-- 2. GUID cache - from previous detections
-- 3. Name cache - if we can get the unit's name
-- Returns: isImmune, creatureType
---------------------------------------
function ATW.IsBleedImmuneGUID(guid)
	if not guid then return false, nil end

	local creatureType = nil
	local classification = nil

	-- Method 1: Try SuperWoW direct GUID query
	if ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local ok, cType = pcall(function()
			return UnitCreatureType(guid)
		end)

		if ok and cType then
			creatureType = cType

			-- Also get classification
			local classOk, cClass = pcall(function()
				return UnitClassification(guid)
			end)
			if classOk then
				classification = cClass
			end

			-- Cache it for future use
			local nameOk, name = pcall(function()
				return UnitName(guid)
			end)
			if nameOk and name then
				ATW.CacheCreatureType(guid, name, creatureType, classification)
			else
				ATW.CacheCreatureType(guid, nil, creatureType, classification)
			end
		end
	end

	-- Method 2: Check GUID cache
	if not creatureType then
		creatureType, classification = ATW.GetCachedCreatureType(guid)

		if creatureType and AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
			ATW.Debug("CreatureType from GUID cache: " .. creatureType)
		end
	end

	-- Method 3: Try to get name and use name cache
	if not creatureType and ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local ok, name = pcall(function()
			return UnitName(guid)
		end)

		if ok and name then
			creatureType, classification = ATW.GetCachedCreatureTypeByName(name)

			if creatureType and AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
				ATW.Debug("CreatureType from name cache (" .. name .. "): " .. creatureType)
			end
		end
	end

	-- If still no type, assume not immune (can't determine)
	if not creatureType then
		return false, nil
	end

	-- Check if it's a boss (bosses can bleed even if elemental/undead)
	if classification == "worldboss" or classification == "rareelite" then
		return false, creatureType
	end

	-- Check if type is immune
	if ATW.BleedImmuneTypes[creatureType] then
		return true, creatureType
	end

	return false, creatureType
end

---------------------------------------
-- Get creature type for display
-- Returns: creatureType string or "Unknown"
---------------------------------------
function ATW.GetCreatureType(unit)
	if not unit then return "Unknown" end
	return UnitCreatureType(unit) or "Unknown"
end

---------------------------------------
-- Get creature type for GUID (SuperWoW)
-- Uses cache as fallback
---------------------------------------
function ATW.GetCreatureTypeGUID(guid)
	if not guid then return "Unknown" end

	-- Try SuperWoW direct query
	if ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local ok, creatureType = pcall(function()
			return UnitCreatureType(guid)
		end)

		if ok and creatureType then
			return creatureType
		end
	end

	-- Try GUID cache
	local cached, _ = ATW.GetCachedCreatureType(guid)
	if cached then
		return cached
	end

	-- Try name cache via GUID lookup
	if ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local ok, name = pcall(function()
			return UnitName(guid)
		end)
		if ok and name then
			local nameCached, _ = ATW.GetCachedCreatureTypeByName(name)
			if nameCached then
				return nameCached
			end
		end
	end

	return "Unknown"
end

---------------------------------------
-- Get classification for GUID
-- Returns: "normal", "elite", "rare", "rareelite", "worldboss"
---------------------------------------
function ATW.GetClassificationGUID(guid)
	if not guid then return "normal" end

	-- Try SuperWoW direct query
	if ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local ok, classification = pcall(function()
			return UnitClassification(guid)
		end)

		if ok and classification then
			return classification
		end
	end

	-- Try GUID cache
	local _, classification = ATW.GetCachedCreatureType(guid)
	if classification then
		return classification
	end

	return "normal"
end

---------------------------------------
-- Debug: Print creature type cache status
---------------------------------------
function ATW.PrintCreatureTypeCache()
	ATW.Print("=== Creature Type Cache ===")

	-- Count GUID cache entries
	local guidCount = 0
	local now = GetTime()
	for guid, data in pairs(ATW.CreatureTypeCache.byGUID) do
		guidCount = guidCount + 1
		if guidCount <= 5 then
			local remaining = ATW.CreatureTypeCache.CACHE_DURATION - (now - data.time)
			local shortGUID = string.sub(guid, 1, 12)
			ATW.Print("  " .. shortGUID .. ": " .. data.type ..
				" (" .. (data.classification or "normal") .. ") " ..
				string.format("%.0f", remaining) .. "s")
		end
	end
	if guidCount > 5 then
		ATW.Print("  ... and " .. (guidCount - 5) .. " more")
	end
	ATW.Print("GUID cache: " .. guidCount .. " entries")

	-- Count name cache entries
	local nameCount = 0
	for name, data in pairs(ATW.CreatureTypeCache.byName) do
		nameCount = nameCount + 1
		if nameCount <= 5 then
			ATW.Print("  " .. name .. ": " .. data.type ..
				" (" .. (data.classification or "normal") .. ")")
		end
	end
	if nameCount > 5 then
		ATW.Print("  ... and " .. (nameCount - 5) .. " more")
	end
	ATW.Print("Name cache: " .. nameCount .. " entries")
end
