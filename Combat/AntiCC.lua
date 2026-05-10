--[[
	Auto Turtle Warrior - Combat/AntiCC

	Detect Fear / Sap / Polymorph / Charm on the player and break it with
	Berserker Rage (which provides 10s immunity to fear/sap/incapacitate
	in vanilla — also breaks active fear effects on cast).
]]--

ATW.AntiCC = ATW.AntiCC or {}

local AntiCC = ATW.AntiCC

---------------------------------------
-- Debuff icon textures that Berserker Rage breaks/prevents.
-- We match by texture substring (icon names) to be language-independent.
---------------------------------------
AntiCC.BERSERKER_BREAKABLE = {
	"Spell_Shadow_Possession",     -- Fear (Warlock, mob)
	"Ability_Warrior_PunishingBlow", -- Intimidating Shout
	"Spell_Shadow_Charm",          -- Mind Control
	"Spell_Shadow_DeathScream",    -- Death Coil (PvP — fear)
	-- Sap (rogue) — incapacitate. Berserker Rage breaks incapacitate too.
	"Ability_Sap",
	-- Howl of Terror (Warlock AoE fear)
	"Spell_Shadow_DeathPact",
	-- Scare Beast (Hunter)
	"Ability_Druid_Cower",
}

---------------------------------------
-- Returns true if the player has any debuff Berserker Rage can break.
---------------------------------------
function AntiCC.PlayerHasFearOrSap()
	local i = 1
	while UnitDebuff("player", i) do
		local texture = UnitDebuff("player", i)
		if texture then
			for _, pattern in ipairs(AntiCC.BERSERKER_BREAKABLE) do
				if string.find(texture, pattern) then
					return true, pattern
				end
			end
		end
		i = i + 1
	end
	return false, nil
end

---------------------------------------
-- Try to fire Berserker Rage to break/prevent the CC. Returns true if used.
---------------------------------------
function AntiCC.TryBreak()
	if not ATW.Has or not ATW.Has.BerserkerRage then return false end

	local feared, source = AntiCC.PlayerHasFearOrSap()
	if not feared then return false end

	-- Cooldown check
	if ATW.SpellID then
		local sid = ATW.SpellID("Berserker Rage")
		if sid then
			local start, duration = GetSpellCooldown(sid, BOOKTYPE_SPELL)
			if start and start > 0 then
				local rem = (start + duration) - GetTime()
				if rem > 0 then return false end
			end
		end
	end

	-- Berserker Rage works in any stance
	CastSpellByName("Berserker Rage")
	if ATW.Debug then
		ATW.Debug("AntiCC -> Berserker Rage (broke " .. (source or "?") .. ")")
	end
	return true
end

---------------------------------------
-- Debug: print current player debuffs and which would be broken.
---------------------------------------
function AntiCC.PrintState()
	if not ATW.Print then return end
	ATW.Print("=== AntiCC ===")
	local i = 1
	local any = false
	while UnitDebuff("player", i) do
		local texture = UnitDebuff("player", i)
		if texture then
			any = true
			local breakable = false
			for _, pattern in ipairs(AntiCC.BERSERKER_BREAKABLE) do
				if string.find(texture, pattern) then breakable = true; break end
			end
			ATW.Print("  debuff " .. i .. ": " .. texture
				.. (breakable and " |cffff5555[BREAKABLE]|r" or ""))
		end
		i = i + 1
	end
	if not any then ATW.Print("  no debuffs") end

	if ATW.Has and ATW.Has.BerserkerRage then
		local sid = ATW.SpellID and ATW.SpellID("Berserker Rage")
		if sid then
			local start, duration = GetSpellCooldown(sid, BOOKTYPE_SPELL)
			if start and start > 0 then
				local rem = (start + duration) - GetTime()
				if rem > 0 then
					ATW.Print(string.format("  Berserker Rage CD: %.1fs", rem))
				else
					ATW.Print("  Berserker Rage |cff00ff00READY|r")
				end
			else
				ATW.Print("  Berserker Rage |cff00ff00READY|r")
			end
		end
	else
		ATW.Print("  Berserker Rage not learned")
	end
end
