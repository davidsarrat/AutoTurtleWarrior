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
