--[[
	Auto Turtle Warrior - Player/Gear
	Equipment tracking: Set bonuses, trinkets, weapon enchants, procs
	Based on TurtleWoW itemization
]]--

ATW.Gear = {
	-- Cached equipment state
	sets = {},
	trinkets = {},
	enchants = {},
	weaponType = nil,  -- "Axe", "Mace", "Sword", "Polearm", or nil
	is2H = false,  -- true if 2H weapon equipped
	normSpeed = 2.4,  -- Normalization speed (2.4 for 1H, 3.3 for 2H)
	lastScan = 0,
	scanInterval = 2,  -- Rescan every 2 seconds
}

---------------------------------------
-- Set Bonus Definitions (TurtleWoW)
---------------------------------------
ATW.SetBonuses = {
	-- Might Set (Tier 1)
	Might = {
		items = {
			"Helm of Might", "Pauldrons of Might", "Breastplate of Might",
			"Gauntlets of Might", "Legplates of Might", "Sabatons of Might",
			"Belt of Might", "Bracers of Might"
		},
		bonuses = {
			[3] = { effect = "might3", desc = "+15 rage on miss" },
			[5] = { effect = "might5", desc = "BT cost -10" },
			[8] = { effect = "might8", desc = "+20 AR" },
		},
	},

	-- Wrath Set (Tier 2)
	Wrath = {
		items = {
			"Helm of Wrath", "Pauldrons of Wrath", "Breastplate of Wrath",
			"Gauntlets of Wrath", "Legplates of Wrath", "Sabatons of Wrath",
			"Waistband of Wrath", "Bracers of Wrath"
		},
		bonuses = {
			[3] = { effect = "wrath3", desc = "+20 rage on BT" },
			[5] = { effect = "wrath5", desc = "+8% WW damage" },
			[8] = { effect = "wrath8", desc = "+50 AP" },
		},
	},

	-- Conqueror's Battlegear (AQ40)
	Conqueror = {
		items = {
			"Conqueror's Crown", "Conqueror's Spaulders", "Conqueror's Breastplate",
			"Conqueror's Gauntlets", "Conqueror's Legguards", "Conqueror's Greaves"
		},
		bonuses = {
			[3] = { effect = "conq3", desc = "+40 AP" },
			[5] = { effect = "conq5", desc = "+20 STR" },
		},
	},

	-- Dreadnaught's Battlegear (Naxx)
	Dreadnaught = {
		items = {
			"Dreadnaught Helmet", "Dreadnaught Pauldrons", "Dreadnaught Breastplate",
			"Dreadnaught Gauntlets", "Dreadnaught Legplates", "Dreadnaught Sabatons",
			"Dreadnaught Waistguard", "Dreadnaught Bracers"
		},
		bonuses = {
			[2] = { effect = "dread2", desc = "+20 STR" },
			[4] = { effect = "dread4", desc = "WW reduces armor by 700" },
			[6] = { effect = "dread6", desc = "+30% Overpower damage" },
			[8] = { effect = "dread8", desc = "+200 AP on Execute" },
		},
	},

	-- Brotherhood of the Light (TurtleWoW custom)
	Brotherhood = {
		items = {
			"Brotherhood Crown", "Brotherhood Pauldrons", "Brotherhood Cuirass",
			"Brotherhood Gauntlets", "Brotherhood Legguards"
		},
		bonuses = {
			[3] = { effect = "brotherhood3", desc = "WW/HS cost -5" },
			[5] = { effect = "brotherhood5", desc = "+5% melee crit" },
		},
	},
}

---------------------------------------
-- Trinket Definitions
-- Data lives in Player/Trinkets.lua (auto-generated). Loaded before this file.
---------------------------------------

---------------------------------------
-- Weapon Enchant Definitions
---------------------------------------
ATW.Enchants = {
	["Crusader"] = {
		effect = "crusader",
		proc = { chance = 5, stat = "str", value = 100, duration = 15 },
	},
	["Fiery Weapon"] = {
		effect = "fiery",
		proc = { chance = 5, damage = 40, type = "fire" },
	},
	["Lifestealing"] = {
		effect = "lifesteal",
		proc = { chance = 5, damage = 30, heal = 30 },
	},
	["Strength"] = {
		effect = "str_enchant",
		stats = { str = 15 },
		passive = true,
	},
	["Agility"] = {
		effect = "agi_enchant",
		stats = { agi = 15 },
		passive = true,
	},
}

---------------------------------------
-- Weapon Proc Definitions
---------------------------------------
ATW.WeaponProcs = {
	["Windfury Totem"] = {
		effect = "windfury",
		proc = { chance = 20, extraAttacks = 2, apBonus = 315 },
		fromBuff = true,
	},
	["Flurry Axe"] = {
		effect = "flurry_axe",
		proc = { chance = 5, extraAttacks = 1 },
	},
	["Ironfoe"] = {
		effect = "ironfoe",
		proc = { chance = 4, extraAttacks = 2 },
	},
	["Deathbringer"] = {
		effect = "deathbringer",
		proc = { chance = 3, damage = 125, type = "shadow" },
	},
	["Chromatically Tempered Sword"] = {
		effect = "cts",
		proc = { chance = 5, damage = 240 },
	},
}

---------------------------------------
-- Scan equipped items for set pieces
---------------------------------------
function ATW.ScanSets()
	ATW.Gear.sets = {}

	-- Scan equipment slots
	local slots = {
		1,  -- Head
		3,  -- Shoulder
		5,  -- Chest
		6,  -- Waist
		7,  -- Legs
		8,  -- Feet
		9,  -- Wrist
		10, -- Hands
	}

	-- Get equipped item names
	local equippedItems = {}
	for _, slot in ipairs(slots) do
		local link = GetInventoryItemLink("player", slot)
		if link then
			local _, _, name = string.find(link, "%[(.+)%]")
			if name then
				equippedItems[name] = true
			end
		end
	end

	-- Check each set
	for setName, setData in pairs(ATW.SetBonuses) do
		local count = 0
		for _, itemName in ipairs(setData.items) do
			if equippedItems[itemName] then
				count = count + 1
			end
		end

		if count > 0 then
			ATW.Gear.sets[setName] = {
				count = count,
				bonuses = {},
			}

			-- Check which bonuses are active
			for threshold, bonus in pairs(setData.bonuses) do
				if count >= threshold then
					ATW.Gear.sets[setName].bonuses[threshold] = bonus
				end
			end
		end
	end
end

---------------------------------------
-- Scan trinkets
---------------------------------------
function ATW.ScanTrinkets()
	ATW.Gear.trinkets = {}

	if not ATW.TrinketDB then return end

	-- Trinket slots: 13, 14
	for _, slot in ipairs({13, 14}) do
		local link = GetInventoryItemLink("player", slot)
		if link then
			local _, _, name = string.find(link, "%[(.+)%]")
			if name and ATW.TrinketDB[name] then
				table.insert(ATW.Gear.trinkets, {
					name = name,
					slot = slot,
					data = ATW.TrinketDB[name],
				})
			end
		end
	end
end

---------------------------------------
-- Check for weapon enchants (via buff detection)
---------------------------------------
function ATW.ScanEnchants()
	ATW.Gear.enchants = {}

	-- Check for Crusader proc buff
	if ATW.Buff("player", "Spell_Holy_HolyBolt") then
		ATW.Gear.enchants.crusader = {
			active = true,
			stats = { str = 100 },
		}
	end

	-- Check for Windfury buff
	if ATW.Buff("player", "Spell_Nature_Windfury") then
		ATW.Gear.enchants.windfury = {
			active = true,
		}
	end
end

---------------------------------------
-- Detect equipped main-hand weapon type AND 2H status
-- Returns: "Axe", "Mace", "Sword", "Polearm", or nil
-- Also sets is2H and normSpeed
-- Used for Master of Arms talent (TurtleWoW 1.17.2) and weapon normalization
---------------------------------------
function ATW.ScanWeaponType()
	ATW.Gear.weaponType = nil
	ATW.Gear.is2H = false
	ATW.Gear.normSpeed = 2.4  -- Default 1H

	-- Main hand slot is 16
	local itemLink = GetInventoryItemLink("player", 16)
	if not itemLink then
		return
	end

	-- Get item info from link
	-- Return order: name, link, quality, iLevel, reqLevel, type, subType, stackCount, invType
	local _, _, _, _, _, itemType, itemSubType, _, inventoryType = GetItemInfo(itemLink)

	-- Detect 2H vs 1H from inventory type
	if inventoryType == "INVTYPE_2HWEAPON" then
		ATW.Gear.is2H = true
		ATW.Gear.normSpeed = 3.3  -- 2H normalization
	elseif inventoryType == "INVTYPE_WEAPON" then
		ATW.Gear.is2H = false
		ATW.Gear.normSpeed = 2.4  -- 1H normalization
	end

	-- Detect weapon type for Master of Arms
	if itemType == "Weapon" or itemType == "Arma" then  -- "Arma" for localized clients
		-- Map weapon subtypes to categories
		-- English/Localized weapon subtype strings
		if itemSubType then
			local subTypeLower = string.lower(itemSubType)

			-- Axes
			if string.find(subTypeLower, "axe") or string.find(subTypeLower, "hacha") then
				ATW.Gear.weaponType = "Axe"

			-- Maces
			elseif string.find(subTypeLower, "mace") or string.find(subTypeLower, "maza") then
				ATW.Gear.weaponType = "Mace"

			-- Swords
			elseif string.find(subTypeLower, "sword") or string.find(subTypeLower, "espada") then
				ATW.Gear.weaponType = "Sword"

			-- Polearms
			elseif string.find(subTypeLower, "polearm") or string.find(subTypeLower, "asta") then
				ATW.Gear.weaponType = "Polearm"
			end
		end
	end
end

---------------------------------------
-- Full gear scan
---------------------------------------
function ATW.ScanGear()
	local now = GetTime()
	if now - ATW.Gear.lastScan < ATW.Gear.scanInterval then
		return
	end

	ATW.ScanSets()
	ATW.ScanTrinkets()
	ATW.ScanEnchants()
	ATW.ScanWeaponType()
	ATW.Gear.lastScan = now
end

---------------------------------------
-- Get active set bonus effects
---------------------------------------
function ATW.GetSetBonusEffects()
	local effects = {}

	for setName, setInfo in pairs(ATW.Gear.sets) do
		for threshold, bonus in pairs(setInfo.bonuses) do
			effects[bonus.effect] = true
		end
	end

	return effects
end

---------------------------------------
-- Check if specific set bonus is active
---------------------------------------
function ATW.HasSetBonus(setName, threshold)
	local setInfo = ATW.Gear.sets[setName]
	if not setInfo then return false end
	return setInfo.count >= threshold
end

---------------------------------------
-- Get stat bonuses from gear
---------------------------------------
function ATW.GetGearStatBonuses()
	local bonuses = {
		str = 0,
		agi = 0,
		ap = 0,
		crit = 0,
		hit = 0,
		haste = 0,
	}

	-- Passive trinket stats. Skip conditional bonuses (vs Undead/Demons) —
	-- those need target type detection and are added separately by callers
	-- via ATW.GetConditionalGearBonuses(unit).
	for _, trinket in ipairs(ATW.Gear.trinkets) do
		if trinket.data.passive and not trinket.data.appliesAgainst then
			for stat, value in pairs(trinket.data.passive) do
				bonuses[stat] = (bonuses[stat] or 0) + value
			end
		end
	end

	-- Active enchant buffs
	if ATW.Gear.enchants.crusader and ATW.Gear.enchants.crusader.active then
		bonuses.str = bonuses.str + 100
	end

	return bonuses
end

---------------------------------------
-- Get conditional gear bonuses for a target's creature type.
-- Trinkets like Mark of the Champion (vs Undead/Demons) and Seal of the
-- Dawn (vs Undead) only grant their AP bonus against matching mobs.
-- Returns: { ap, str, crit, hit, haste, ... } table with applicable bonuses.
---------------------------------------
function ATW.GetConditionalGearBonuses(unit)
	local bonuses = { str = 0, agi = 0, ap = 0, crit = 0, hit = 0, haste = 0 }

	if not unit or not UnitExists(unit) then return bonuses end
	if not ATW.Gear or not ATW.Gear.trinkets then return bonuses end

	local creatureType = ATW.GetCreatureType and ATW.GetCreatureType(unit) or nil
	if not creatureType or creatureType == "Unknown" then return bonuses end

	for _, trinket in ipairs(ATW.Gear.trinkets) do
		local cond = trinket.data.appliesAgainst
		if cond and trinket.data.passive then
			local matches = false
			if type(cond) == "string" then
				matches = (cond == creatureType)
			elseif type(cond) == "table" then
				for _, t in ipairs(cond) do
					if t == creatureType then matches = true; break end
				end
			end
			if matches then
				for stat, value in pairs(trinket.data.passive) do
					bonuses[stat] = (bonuses[stat] or 0) + value
				end
			end
		end
	end

	return bonuses
end

---------------------------------------
-- Modify ability costs based on set bonuses
---------------------------------------
function ATW.GetModifiedRageCost(abilityName, baseCost)
	local cost = baseCost

	local effects = ATW.GetSetBonusEffects()

	-- Might 5-set: BT cost -10
	if abilityName == "Bloodthirst" and effects.might5 then
		cost = cost - 10
	end

	-- Brotherhood 3-set: WW/HS cost -5
	if effects.brotherhood3 then
		if abilityName == "Whirlwind" or abilityName == "HeroicStrike" then
			cost = cost - 5
		end
	end

	return math.max(cost, 0)
end

---------------------------------------
-- Check for Hand of Justice extra attack proc
---------------------------------------
function ATW.CheckHandOfJusticeProc()
	for _, trinket in ipairs(ATW.Gear.trinkets) do
		if trinket.name == "Hand of Justice" then
			local roll = math.random() * 100
			if roll < 2 then  -- 2% chance
				return true
			end
		end
	end
	return false
end

---------------------------------------
-- Debug: Print gear info
---------------------------------------
function ATW.PrintGear()
	ATW.ScanGear()

	ATW.Print("=== Gear Info ===")

	-- Weapon Type (for Master of Arms)
	ATW.Print("Weapon Type: " .. (ATW.Gear.weaponType or "Unknown"))
	if ATW.Gear.weaponType and ATW.Talents and ATW.Talents.MasterOfArms and ATW.Talents.MasterOfArms > 0 then
		ATW.Print("  Master of Arms (" .. ATW.Talents.MasterOfArms .. " points) active!")
		if ATW.Gear.weaponType == "Axe" then
			ATW.Print("  Bonus: +" .. (ATW.Talents.MasterOfArms) .. "% crit")
		elseif ATW.Gear.weaponType == "Mace" then
			ATW.Print("  Bonus: +" .. (ATW.Talents.MasterOfArms * 4) .. "% armor pen")
		elseif ATW.Gear.weaponType == "Sword" then
			ATW.Print("  Bonus: +" .. (ATW.Talents.MasterOfArms * 2) .. "% extra attack on crit")
		elseif ATW.Gear.weaponType == "Polearm" then
			ATW.Print("  Bonus: +" .. ATW.Talents.MasterOfArms .. " yard range")
		end
	end

	-- Sets
	ATW.Print("Set Bonuses:")
	local hasSet = false
	for setName, setInfo in pairs(ATW.Gear.sets) do
		hasSet = true
		local bonusStr = ""
		for threshold, bonus in pairs(setInfo.bonuses) do
			bonusStr = bonusStr .. " [" .. threshold .. "pc: " .. bonus.desc .. "]"
		end
		ATW.Print("  " .. setName .. " (" .. setInfo.count .. "pc)" .. bonusStr)
	end
	if not hasSet then
		ATW.Print("  None detected")
	end

	-- Trinkets
	ATW.Print("Trinkets:")
	if table.getn(ATW.Gear.trinkets) > 0 then
		for _, trinket in ipairs(ATW.Gear.trinkets) do
			ATW.Print("  " .. trinket.name)
		end
	else
		ATW.Print("  None detected")
	end

	-- Enchants
	ATW.Print("Active Procs:")
	if ATW.Gear.enchants.crusader and ATW.Gear.enchants.crusader.active then
		ATW.Print("  Crusader (+100 STR)")
	end
	if ATW.Gear.enchants.windfury and ATW.Gear.enchants.windfury.active then
		ATW.Print("  Windfury")
	end
end
