--[[
	Auto Turtle Warrior - Core/Helpers
	Utility functions
]]--

---------------------------------------
-- Print / Debug
---------------------------------------
function ATW.Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[ATW]|r " .. msg)
end

function ATW.Debug(msg)
	if AutoTurtleWarrior_Config.Debug then
		ATW.Print(msg)
	end
end

---------------------------------------
-- Spell Helpers
---------------------------------------
function ATW.SpellID(name)
	local id = 1
	for t = 1, GetNumSpellTabs() do
		local _, _, _, n = GetSpellTabInfo(t)
		for s = 1, n do
			if GetSpellName(id, BOOKTYPE_SPELL) == name then
				return id
			end
			id = id + 1
		end
	end
	return nil
end

function ATW.Ready(spell)
	local id = ATW.SpellID(spell)
	if not id then return nil end
	local start, dur = GetSpellCooldown(id, 0)
	return start == 0 and dur == 0
end

---------------------------------------
-- Buff / Debuff Detection
---------------------------------------
function ATW.Buff(unit, texture)
	local i = 1
	while UnitBuff(unit, i) do
		if strfind(UnitBuff(unit, i), texture) then
			return true
		end
		i = i + 1
	end
	return false
end

function ATW.Debuff(unit, texture)
	local i = 1
	while UnitDebuff(unit, i) do
		if strfind(UnitDebuff(unit, i), texture) then
			return true
		end
		i = i + 1
	end
	return false
end

---------------------------------------
-- Check if GUID has a debuff by texture
-- SuperWoW: UnitDebuff accepts GUIDs directly!
-- Priority 1: Direct UnitDebuff(guid, i) - most reliable
-- Priority 2: RendTracker for Rend (combat log verified)
---------------------------------------
function ATW.DebuffOnGUID(guid, texture)
	if not guid or guid == "" then return false end

	-- Priority 1: Try direct UnitDebuff with GUID (SuperWoW feature)
	if ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local ok, found = pcall(function()
			local i = 1
			while true do
				local debuffTexture = UnitDebuff(guid, i)
				if not debuffTexture then break end
				if strfind(debuffTexture, texture) then
					return true
				end
				i = i + 1
			end
			return false
		end)
		if ok and found then
			return true
		end
	end

	-- Priority 2: For Rend, check our tracking system
	-- (fallback in case UnitDebuff(guid) doesn't work)
	if texture == "Ability_Gouge" and ATW.RendTracker then
		if ATW.RendTracker.HasRend(guid) then
			return true
		end
	end

	-- Priority 3: Try checking via target if this GUID matches our target
	if ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local _, targetGUID = UnitExists("target")
		if targetGUID and targetGUID == guid then
			return ATW.Debuff("target", texture)
		end
	end

	return false
end

---------------------------------------
-- Check if unit/GUID has Rend specifically
-- Priority: SuperWoW UnitDebuff > RendTracker
-- This ensures we detect real debuffs even if tracking failed
---------------------------------------
function ATW.HasRend(unitOrGUID)
	if not unitOrGUID then return false end

	-- Check if it's a standard unit ID
	if unitOrGUID == "target" or unitOrGUID == "player" or
	   unitOrGUID == "focus" or unitOrGUID == "mouseover" then
		-- Standard debuff check first (most reliable)
		if ATW.Debuff(unitOrGUID, "Ability_Gouge") then
			return true
		end
		-- Fallback to tracker for target
		if unitOrGUID == "target" and ATW.HasSuperWoW and ATW.HasSuperWoW() then
			local _, guid = UnitExists("target")
			if guid and ATW.RendTracker and ATW.RendTracker.HasRend(guid) then
				return true
			end
		end
		return false
	end

	-- Assume it's a GUID
	-- Priority 1: SuperWoW UnitDebuff(guid) - most reliable
	if ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local ok, hasDebuff = pcall(function()
			return ATW.DebuffOnGUID(unitOrGUID, "Ability_Gouge")
		end)
		if ok and hasDebuff then
			return true
		end
	end

	-- Priority 2: RendTracker (fallback, may have slight delay)
	if ATW.RendTracker then
		return ATW.RendTracker.HasRend(unitOrGUID)
	end

	return false
end

---------------------------------------
-- Get Rend remaining duration on GUID
-- Returns: seconds remaining, or 0 if no Rend
-- Note: SuperWoW UnitDebuff doesn't return duration, so we use tracking
---------------------------------------
function ATW.GetRendRemaining(guid)
	if not guid then return 0 end

	-- Use tracking system (duration comes from our own tracking)
	if ATW.RendTracker then
		return ATW.RendTracker.GetRendRemaining(guid)
	end

	return 0
end

---------------------------------------
-- Health Helpers
-- TurtleWoW/SuperWoW can return inconsistent values:
-- Sometimes UnitHealth returns percentage but UnitHealthMax returns real HP
-- We need to detect and handle this
---------------------------------------
function ATW.GetHealthPercent(unit)
	unit = unit or "player"

	local hp = UnitHealth(unit)
	local max = UnitHealthMax(unit)

	-- Safety check
	if not hp or not max or max == 0 then
		return 100
	end

	-- For player: always real values
	if unit == "player" then
		return (hp / max) * 100
	end

	-- For non-player units, detect the format:
	-- Case 1: Both are percentages (vanilla style) - max is around 100
	-- Case 2: Both are real values - max is much larger than 100
	-- Case 3: hp is percentage (0-100) but max is real - BROKEN, need to detect

	-- If hp > max, something is wrong - hp might be percentage, max might be real
	-- This happens when hp=75 (%) and max=50 (real low-hp mob)
	-- But also could be hp=7500 (real) and max=100 (broken)

	-- Simple heuristic: if max <= 100, assume vanilla percentage mode
	if max <= 100 then
		-- hp should be in range 0-100 (percentage)
		-- Just return hp as the percentage
		return hp
	end

	-- max > 100, so it's likely real HP values
	-- Check if hp looks like a percentage (0-100) or real value
	if hp <= 100 and max > 1000 then
		-- hp looks like percentage but max is real - BROKEN
		-- Just return hp as percentage directly
		return hp
	end

	-- Both seem to be real values
	return (hp / max) * 100
end

function ATW.InExecutePhase(unit)
	unit = unit or "target"
	if not UnitExists(unit) then return false end
	return ATW.GetHealthPercent(unit) < 20
end

---------------------------------------
-- Overpower Proc Tracking
-- Tracks which mob dodged to enable smarter target selection
-- In vanilla, Overpower can be used on ANY target after a dodge,
-- but it's optimal to use it on the mob that dodged (or switch to it)
---------------------------------------
function ATW.SetOverpowerProc(mobName)
	local state = ATW.State
	local now = GetTime()

	state.Overpower = now
	state.OverpowerTarget = mobName
	state.OverpowerGUID = nil

	-- Try to find GUID for the mob that dodged
	if mobName and ATW.HasSuperWoW and ATW.HasSuperWoW() then
		-- Priority 1: Check if current target matches
		if UnitExists("target") and UnitName("target") == mobName then
			local _, guid = UnitExists("target")
			if guid then
				state.OverpowerGUID = guid
			end
		else
			-- Priority 2: Scan nameplates for this mob name
			local children = { WorldFrame:GetChildren() }
			for i, frame in ipairs(children) do
				if frame:IsVisible() and not frame:GetName() then
					-- Try to get GUID from nameplate
					local ok, guid = pcall(function()
						return frame:GetName(1)  -- SuperWoW nameplate GUID
					end)
					if ok and guid and guid ~= "" then
						-- Check if this GUID matches our mob name
						local unitName = UnitName(guid)
						if unitName == mobName then
							state.OverpowerGUID = guid
							break
						end
					end
				end
			end
		end
	end

	if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
		local guidInfo = state.OverpowerGUID and (" GUID:" .. string.sub(state.OverpowerGUID, 1, 12)) or ""
		ATW.Debug("Overpower proc: " .. (mobName or "unknown") .. guidInfo)
	end
end

---------------------------------------
-- Get Overpower target info
-- Returns: isAvailable, mobName, guid, isCurrentTarget, windowRemaining
---------------------------------------
function ATW.GetOverpowerInfo()
	local state = ATW.State

	if not state.Overpower then
		return false, nil, nil, false, 0
	end

	local windowRemaining = 4 - (GetTime() - state.Overpower)
	if windowRemaining <= 0 then
		-- Window expired, clear state
		state.Overpower = nil
		state.OverpowerTarget = nil
		state.OverpowerGUID = nil
		return false, nil, nil, false, 0
	end

	-- Check if the mob that dodged is our current target
	local isCurrentTarget = false
	if state.OverpowerGUID and ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local _, targetGUID = UnitExists("target")
		isCurrentTarget = (targetGUID and targetGUID == state.OverpowerGUID)
	elseif state.OverpowerTarget then
		isCurrentTarget = (UnitName("target") == state.OverpowerTarget)
	end

	return true, state.OverpowerTarget, state.OverpowerGUID, isCurrentTarget, windowRemaining
end

---------------------------------------
-- Should switch target for Overpower?
-- Returns: shouldSwitch, guid, reason
---------------------------------------
function ATW.ShouldSwitchForOverpower()
	local isAvailable, mobName, guid, isCurrentTarget, windowRemaining = ATW.GetOverpowerInfo()

	if not isAvailable then
		return false, nil, "no proc"
	end

	-- Already targeting the mob that dodged
	if isCurrentTarget then
		return false, nil, "already targeting"
	end

	-- Don't switch if we don't have GUID (could hit wrong mob with same name)
	if not guid then
		return false, nil, "no GUID (name: " .. (mobName or "?") .. ")"
	end

	-- Check if the mob is still alive
	if ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local hp = UnitHealth(guid)
		if not hp or hp <= 0 then
			return false, nil, "target dead"
		end

		-- Check if mob is in range (5yd for Overpower)
		local dist = ATW.GetDistance and ATW.GetDistance(guid)
		if dist and dist > 5 then
			return false, nil, "out of range (" .. string.format("%.1f", dist) .. "yd)"
		end
	end

	-- Window urgent - should switch
	if windowRemaining <= 2 then
		return true, guid, "window expiring (" .. string.format("%.1f", windowRemaining) .. "s)"
	end

	-- Window has time - switching is optional
	return true, guid, "different target (" .. string.format("%.1f", windowRemaining) .. "s left)"
end
