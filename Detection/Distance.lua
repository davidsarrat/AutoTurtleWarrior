--[[
	Auto Turtle Warrior - Detection/Distance
	Distance measurement using UnitXP
]]--

---------------------------------------
-- Dependency Checks
---------------------------------------
function ATW.HasUnitXP()
	return UnitXP ~= nil
end

function ATW.HasSuperWoW()
	return SUPERWOW_VERSION ~= nil or SUPERWOW_STRING ~= nil
end

---------------------------------------
-- Distance Measurement (UnitXP)
---------------------------------------

-- General distance (3D, includes height)
-- Used for: AoE abilities, ranged spells, general positioning
function ATW.GetDistance(unit)
	if not ATW.HasUnitXP() then
		return nil
	end

	local ok, dist = pcall(function()
		return UnitXP("distanceBetween", "player", unit or "target", "AoE")
	end)

	if ok and dist then
		return dist
	end
	return nil
end

-- Horizontal distance (2D, ignores height if z-diff < 6 yards)
-- Used for: Charge, melee abilities, movement validation
-- More accurate for ground-based combat mechanics
function ATW.GetHorizontalDistance(unit)
	if not ATW.HasUnitXP() then
		return nil
	end

	local ok, dist = pcall(function()
		-- meleeAutoAttack mode: Uses 2D distance when height diff < 6 yards
		-- Matches how WoW vanilla Charge and melee range work
		return UnitXP("distanceBetween", "player", unit or "target", "meleeAutoAttack")
	end)

	if ok and dist then
		return dist
	end
	return nil
end

---------------------------------------
-- Range Check for Target
---------------------------------------
function ATW.TargetInRange()
	if not UnitExists("target") then
		return false
	end

	local dist = ATW.GetDistance("target")
	if dist then
		return dist <= (AutoTurtleWarrior_Config.WWRange or 8)
	end

	-- Fallback to CheckInteractDistance
	return CheckInteractDistance("target", 3)
end
