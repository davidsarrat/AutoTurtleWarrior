# Spell & Talent System

This document explains how spell ranks and talents are detected and used by the simulator.

## Overview

The addon dynamically detects:
1. **Talents** - Points spent in each talent
2. **Spells** - Which spells are known and their maximum rank

This allows the simulation to use correct values regardless of character level or spec. **Critically, the simulator ONLY considers abilities the player has actually learned**.

## Spell Rank Detection

### Finding Max Rank

The `GetMaxSpellRank()` function scans the player's spellbook to find the highest rank of a spell:

```lua
-- Player/Talents.lua
function ATW.GetMaxSpellRank(spellName)
    local maxRank = 0
    local id = 1

    for t = 1, GetNumSpellTabs() do
        local _, _, _, n = GetSpellTabInfo(t)
        for s = 1, n do
            local name, rank = GetSpellName(id, BOOKTYPE_SPELL)
            if name == spellName then
                -- Parse rank from "Rank X" string
                local _, _, rankNum = strfind(rank or "", "(%d+)")
                if rankNum then
                    local r = tonumber(rankNum)
                    if r and r > maxRank then
                        maxRank = r
                    end
                elseif maxRank == 0 then
                    maxRank = 1  -- No rank text = rank 1
                end
            end
            id = id + 1
        end
    end

    return maxRank  -- Returns 0 if spell not found
end
```

### Loading All Spell Data

The `LoadSpells()` function populates `ATW.Spells` with all ability ranks:

```lua
-- Player/Talents.lua
function ATW.LoadSpells()
    ATW.Spells = ATW.Spells or {}

    -- Core combat spells (ranked)
    ATW.Spells.RendRank = ATW.GetMaxSpellRank("Rend")
    ATW.Spells.HasRend = ATW.Spells.RendRank > 0
    ATW.Spells.ExecuteRank = ATW.GetMaxSpellRank("Execute")
    ATW.Spells.HeroicStrikeRank = ATW.GetMaxSpellRank("Heroic Strike")
    ATW.Spells.CleaveRank = ATW.GetMaxSpellRank("Cleave")
    ATW.Spells.OverpowerRank = ATW.GetMaxSpellRank("Overpower")
    ATW.Spells.HamstringRank = ATW.GetMaxSpellRank("Hamstring")
    ATW.Spells.SlamRank = ATW.GetMaxSpellRank("Slam")
    ATW.Spells.WhirlwindRank = ATW.GetMaxSpellRank("Whirlwind")
    ATW.Spells.BattleShoutRank = ATW.GetMaxSpellRank("Battle Shout")

    -- Talent abilities (only 1 rank)
    ATW.Spells.BloodthirstRank = ATW.GetMaxSpellRank("Bloodthirst")
    ATW.Spells.MortalStrikeRank = ATW.GetMaxSpellRank("Mortal Strike")

    -- Utility spells (needed for simulator)
    ATW.Spells.ChargeRank = ATW.GetMaxSpellRank("Charge")
    ATW.Spells.BloodrageRank = ATW.GetMaxSpellRank("Bloodrage")
    ATW.Spells.BerserkerRageRank = ATW.GetMaxSpellRank("Berserker Rage")
    ATW.Spells.PummelRank = ATW.GetMaxSpellRank("Pummel")

    -- Cooldown abilities (talent-based)
    ATW.Spells.DeathWishRank = ATW.GetMaxSpellRank("Death Wish")
    ATW.Spells.RecklessnessRank = ATW.GetMaxSpellRank("Recklessness")
    ATW.Spells.SweepingStrikesRank = ATW.GetMaxSpellRank("Sweeping Strikes")

    -- CACHE REND VALUES (use these instead of calling functions)
    if ATW.Spells.RendRank > 0 then
        local rendData = ATW.RendData[ATW.Spells.RendRank]
        if rendData then
            ATW.RendDuration = rendData.duration      -- Cached duration (seconds)
            ATW.RendTicks = math.floor(rendData.duration / 3)
            ATW.RendBaseDamage = rendData.damage      -- Before talent bonus
        end
    end

    -- Update RendTracker with cached value
    if ATW.RendTracker then
        ATW.RendTracker.REND_DURATION = ATW.RendDuration
    end
end
```

### Cached Rend Values

To prevent fallback values from being used mid-combat, Rend values are cached:

```lua
-- Set by LoadSpells() - use these instead of calling functions
ATW.RendDuration    -- Duration in seconds (e.g., 22)
ATW.RendTicks       -- Number of ticks (e.g., 7)
ATW.RendBaseDamage  -- Base damage before talents (e.g., 147)

-- Usage:
local duration = (ATW.RendDuration and ATW.RendDuration > 0) and ATW.RendDuration or 22
```

## Simulator Spell Verification

### The hasSpell() Function

The simulator's `GetValidActions()` uses `hasSpell()` to verify each ability before considering it:

```lua
-- Sim/Engine.lua, inside GetValidActions()
local function hasSpell(spellName)
    -- Map internal names to ATW.Spells rank keys
    local spellRankMap = {
        -- Core abilities
        Execute = "ExecuteRank",
        Rend = "RendRank",
        HeroicStrike = "HeroicStrikeRank",
        Cleave = "CleaveRank",
        Overpower = "OverpowerRank",
        Whirlwind = "WhirlwindRank",
        Slam = "SlamRank",
        Hamstring = "HamstringRank",
        BattleShout = "BattleShoutRank",
        -- Talent abilities
        Bloodthirst = "BloodthirstRank",
        MortalStrike = "MortalStrikeRank",
        -- Utility abilities
        Charge = "ChargeRank",
        Bloodrage = "BloodrageRank",
        BerserkerRage = "BerserkerRageRank",
        Recklessness = "RecklessnessRank",
        DeathWish = "DeathWishRank",
        SweepingStrikes = "SweepingStrikesRank",
        Pummel = "PummelRank",
    }

    -- Check ATW.Spells first (most reliable)
    if ATW.Spells then
        local rankKey = spellRankMap[spellName]
        if rankKey then
            local rank = ATW.Spells[rankKey]
            if rank ~= nil then
                return rank > 0
            end
        end
    end

    -- Fallback: check spellbook directly
    if ATW.SpellID then
        local displayNames = {
            BattleShout = "Battle Shout",
            HeroicStrike = "Heroic Strike",
            MortalStrike = "Mortal Strike",
            BerserkerRage = "Berserker Rage",
            DeathWish = "Death Wish",
            SweepingStrikes = "Sweeping Strikes",
        }
        local displayName = displayNames[spellName] or spellName
        local spellId = ATW.SpellID(displayName)
        if spellId then
            return true
        end
    end

    -- CRITICAL: Default to FALSE
    -- This prevents pooling rage for unlearned abilities
    return false
end
```

### Why Default to FALSE?

This is critical for proper rotation behavior:

```
Player at level 20:
- Has: Heroic Strike, Rend, Overpower
- Does NOT have: Execute (level 24), Whirlwind (level 36)

Without hasSpell() check:
  Simulator might pool rage for Execute → rotation stalls

With hasSpell() returning FALSE for unlearned:
  Simulator only considers HS, Rend, Overpower → uses rage efficiently
```

### Usage in GetValidActions()

Every ability is wrapped with a `hasSpell()` check:

```lua
-- Execute - only if learned AND target < 20%
if inExecute and hasSpell("Execute") then
    -- Generate Execute action
end

-- Bloodthirst - only if learned (talent ability)
if hasSpell("Bloodthirst") then
    -- Generate Bloodthirst action
end

-- Whirlwind - only if learned (level 36+)
if hasSpell("Whirlwind") then
    -- Generate Whirlwind action
end
```

## Talent Detection

### File: `Player/Talents.lua`

Talents are detected using the `GetTalentInfo()` API:

```lua
local name, iconTexture, tier, column, rank, maxRank = GetTalentInfo(tabIndex, talentIndex)
```

### Talent Tree Indices

| Tab | Tree |
|-----|------|
| 1 | Arms |
| 2 | Fury |
| 3 | Protection |

### Arms Tree Talents

```lua
-- Improved Heroic Strike (tier 1, slot 1)
-- Reduces rage cost by 1/2/3
_, _, _, _, r = GetTalentInfo(1, 1)
ATW.Talents.HSCost = 15 - r

-- Improved Rend (tier 2, slot 1)
-- TurtleWoW: 2 points for +10/20% damage
_, _, _, _, r = GetTalentInfo(1, 3)
ATW.Talents.ImpRend = r

-- Improved Charge (tier 2, slot 2)
-- +3/6 rage on Charge
_, _, _, _, r = GetTalentInfo(1, 4)
ATW.Talents.ChargeRage = 9 + (r * 3)  -- Total rage from Charge

-- Tactical Mastery (tier 3, slot 1)
-- Retain 5/10/15/20/25 rage when switching stances
_, _, _, _, r = GetTalentInfo(1, 5)
ATW.Talents.TM = r * 5

-- Improved Overpower (tier 5, slot 1)
-- +25/50% crit chance on Overpower
_, _, _, _, r = GetTalentInfo(1, 9)
ATW.Talents.OPCrit = r * 25

-- Deep Wounds (tier 6, slot 1)
-- 20/40/60% weapon damage over 12s on crit
_, _, _, _, r = GetTalentInfo(1, 11)
ATW.Talents.DeepWounds = r

-- Two-Handed Weapon Specialization (tier 6, 5 points)
-- +1/2/3/4/5% damage with 2H weapons
-- Usually slot 7, but scanned by NAME for reliability
ATW.Talents.TwoHandSpec = 0
for i = 1, 30 do
    local name, _, _, _, rank = GetTalentInfo(1, i)
    if name and string.find(name, "Two-Handed Weapon Specialization") then
        ATW.Talents.TwoHandSpec = rank  -- 0-5 points
        break
    end
end

-- Impale (tier 6, slot 2)
-- +10/20% crit damage on abilities
_, _, _, _, r = GetTalentInfo(1, 12)
ATW.Talents.Impale = r

-- Sweeping Strikes (tier 7)
_, _, _, _, r = GetTalentInfo(1, 13)
ATW.Talents.HasSS = r > 0

-- Mortal Strike (tier 9, slot 1)
_, _, _, _, r = GetTalentInfo(1, 17)
ATW.Talents.HasMS = r > 0
```

### Fury Tree Talents

```lua
-- Improved Battle Shout (tier 2, 5 points)
-- +5/10/15/20/25% Battle Shout AP
-- Scanned by NAME since position may vary in TurtleWoW
ATW.Talents.ImprovedBattleShout = 0
for i = 1, 30 do
    local name, _, _, _, rank = GetTalentInfo(2, i)
    if name and string.find(name, "Improved Battle Shout") then
        ATW.Talents.ImprovedBattleShout = rank  -- 0-5 points
        break
    end
end

-- Cruelty (tier 1, slot 2)
-- +1/2/3/4/5% crit chance
_, _, _, _, r = GetTalentInfo(2, 2)
ATW.Talents.Cruelty = r

-- Unbridled Wrath (tier 2, slot 3)
-- 8/16/24/32/40% chance for +1 rage on hit (1H) or +2 rage (2H in TurtleWoW)
_, _, _, _, r = GetTalentInfo(2, 5)
ATW.Talents.UnbridledWrath = r * 8

-- Improved Execute (tier 5, slot 2)
-- Reduces Execute cost by 2/5 rage
_, _, _, _, r = GetTalentInfo(2, 10)
ATW.Talents.ExecCost = 15 - math.floor(r * 2.5)

-- Flurry (tier 6, slot 1)
-- On crit, +10/15/20/25/30% attack speed for 3 swings
_, _, _, _, r = GetTalentInfo(2, 12)
ATW.Talents.Flurry = r

-- Dual Wield Specialization (tier 6, 5 points)
-- +5/10/15/20/25% offhand weapon damage
-- Scanned by NAME since position may vary in TurtleWoW
ATW.Talents.DualWieldSpec = 0
for i = 1, 30 do
    local name, _, _, _, rank = GetTalentInfo(2, i)
    if name and string.find(name, "Dual Wield Specialization") then
        ATW.Talents.DualWieldSpec = rank  -- 0-5 points
        break
    end
end

-- Death Wish (tier 7, slot 1)
_, _, _, _, r = GetTalentInfo(2, 13)
ATW.Talents.HasDW = r > 0

-- Improved Berserker Rage (tier 7, slot 3)
_, _, _, _, r = GetTalentInfo(2, 15)
ATW.Talents.HasIBR = r > 0

-- Bloodthirst (tier 9, slot 1)
_, _, _, _, r = GetTalentInfo(2, 17)
ATW.Talents.HasBT = r > 0
```

## TurtleWoW Differences

TurtleWoW has modified some spells and talents from vanilla:

| Item | Vanilla | TurtleWoW |
|------|---------|-----------|
| Rend Duration | 9/12/15/18/21/21/21s | 10/13/16/19/22/22/22s |
| Improved Rend | 3 pts, +15/25/35% dmg | 2 pts, +10/20% dmg |
| Unbridled Wrath | +1 rage | +1 rage (1H), +2 rage (2H) |
| Weapon Normalization | 2.4 for all weapons | 2.4 (1H), 3.3 (2H) |
| Two-Hand Weapon Spec | 3 pts, +1/2/3% dmg | 5 pts, +1/2/3/4/5% dmg |
| Dual Wield Spec | N/A (vanilla) | 5 pts, +5/10/15/20/25% OH dmg |

**Critical Implementation Notes:**
- **2H Detection**: Uses `GetItemInfo()` inventoryType check (INVTYPE_2HWEAPON)
- **Dynamic Normalization**: Whirlwind and Mortal Strike use 3.3 normalization with 2H, 2.4 with 1H
- **Unbridled Wrath Bonus**: Applied in rage generation - checks `is2H` flag
- **Dual Wield Spec**: Applied in `ProcessHit()` after crit calculation when `isOH = true`
- **Two-Hand Spec**: Applied in `GetDamageMod()` when `is2H = true`

## Rend Data by Rank (TurtleWoW)

```lua
ATW.RendData = {
    -- [rank] = { damage, duration, level }
    -- TurtleWoW uses 10/13/16/19/22/22/22 (not vanilla 9/12/15/18/21/21/21)
    [1] = { damage = 15,  duration = 10, level = 4 },
    [2] = { damage = 28,  duration = 13, level = 10 },
    [3] = { damage = 45,  duration = 16, level = 20 },
    [4] = { damage = 66,  duration = 19, level = 30 },
    [5] = { damage = 98,  duration = 22, level = 40 },
    [6] = { damage = 126, duration = 22, level = 50 },
    [7] = { damage = 147, duration = 22, level = 60 },
}
```

## Dynamic Spell Functions

### Rend Duration

**Prefer using cached `ATW.RendDuration` instead of calling this function.**

```lua
function ATW.GetRendDuration()
    -- First check cached value (set by LoadSpells)
    if ATW.RendDuration and ATW.RendDuration > 0 then
        return ATW.RendDuration
    end
    -- Fallback to calculation
    local rank = ATW.Spells and ATW.Spells.RendRank or 0
    if rank <= 0 then return 0 end
    local data = ATW.RendData[rank]
    return data and data.duration or 22  -- TurtleWoW max rank = 22s
end
```

### Rend Damage (with talent bonus)

```lua
function ATW.GetRendDamage()
    local rank = ATW.Spells and ATW.Spells.RendRank or 0
    if rank <= 0 then return 0 end
    local data = ATW.RendData[rank]
    if not data then return 0 end

    local baseDamage = data.damage

    -- Apply Improved Rend talent (10% per point in TurtleWoW)
    local impRend = ATW.Talents and ATW.Talents.ImpRend or 0
    if impRend > 0 then
        baseDamage = baseDamage * (1 + impRend * 0.10)
    end

    return baseDamage
end
```

## Battle Shout System

### Smart Battle Shout Override

The addon implements an intelligent Battle Shout system that **prevents overriding superior buffs** from other warriors:

**Problem:**
- Multiple warriors can cast Battle Shout
- Different ranks give different AP (Rank 1: 15 AP, Rank 7: 232 AP)
- Improved Battle Shout talent adds +25% AP at 5 points (232 AP → 290 AP)
- Without protection, a low-rank Battle Shout can overwrite a better one

**Solution: Tooltip Scanning + AP Comparison**

#### GetActiveBattleShoutAP() (Core/Helpers.lua)

```lua
function ATW.GetActiveBattleShoutAP()
    -- Create hidden tooltip for scanning
    if not ATW_ScanTooltip then
        ATW_ScanTooltip = CreateFrame("GameTooltip", "ATW_ScanTooltip", UIParent, "GameTooltipTemplate")
        ATW_ScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    end

    -- Find Battle Shout buff index
    local buffIndex = 0
    for i = 1, 32 do
        local texture = UnitBuff("player", i)
        if texture and strfind(texture, "Ability_Warrior_BattleShout") then
            buffIndex = i
            break
        end
    end

    if buffIndex == 0 then
        return 0  -- No Battle Shout active
    end

    -- Scan tooltip and extract AP value
    ATW_ScanTooltip:ClearLines()
    ATW_ScanTooltip:SetUnitBuff("player", buffIndex)

    -- Parse patterns: "by 232" or "232 attack power"
    for i = 1, ATW_ScanTooltip:NumLines() do
        local line = getglobal("ATW_ScanTooltipTextLeft" .. i)
        if line then
            local text = line:GetText()
            if text then
                local _, _, apValue = strfind(text, "by (%d+)")
                if apValue then return tonumber(apValue) end

                local _, _, apValue2 = strfind(text, "(%d+)%s+attack power")
                if apValue2 then return tonumber(apValue2) end
            end
        end
    end

    return 0  -- Couldn't parse
end
```

#### State Capture (Sim/Engine.lua)

```lua
-- In CaptureCurrentState():
state.hasBattleShout = ATW.Buff and ATW.Buff("player", "Ability_Warrior_BattleShout")
state.activeBattleShoutAP = 0
if state.hasBattleShout and ATW.GetActiveBattleShoutAP then
    state.activeBattleShoutAP = ATW.GetActiveBattleShoutAP()
end
```

#### Comparison Logic (Sim/Engine.lua)

```lua
-- In GetValidActions():
if hasSpell("BattleShout") then
    local bsCost = 10
    local shouldCast = false

    if not state.hasBattleShout then
        shouldCast = true  -- No buff active
    else
        -- Compare AP values
        local ourBattleShoutAP = ATW.GetBattleShoutAP and ATW.GetBattleShoutAP() or 232
        local activeBattleShoutAP = state.activeBattleShoutAP or 0

        -- Only override if ours is BETTER (+5 AP threshold to avoid spam)
        if ourBattleShoutAP > (activeBattleShoutAP + 5) then
            shouldCast = true
        end
    end

    if shouldCast and rage >= bsCost then
        table.insert(actions, {name = "BattleShout", rage = bsCost})
    end
end
```

### Battle Shout Ranks (Vanilla/TurtleWoW)

```
Rank 1: 15 AP   (level 1)
Rank 2: 35 AP   (level 12)
Rank 3: 55 AP   (level 22)
Rank 4: 85 AP   (level 32)
Rank 5: 130 AP  (level 42)
Rank 6: 185 AP  (level 52)
Rank 7: 232 AP  (level 60)

With Improved Battle Shout (5 points): +25%
Rank 7 + 5/5 Improved: 290 AP (MAXIMUM)
```

### Examples

**Scenario 1**: No buff active
- **Action**: Cast your Battle Shout
- ✅ Correct

**Scenario 2**: Active buff = 130 AP (Rank 5), yours = 290 AP
- **Comparison**: 290 > (130 + 5) = TRUE
- **Action**: Cast your Battle Shout (override)
- ✅ Correct (yours is much better)

**Scenario 3**: Active buff = 290 AP, yours = 232 AP
- **Comparison**: 232 > (290 + 5) = FALSE
- **Action**: Don't cast (keep better buff)
- ✅ Correct (theirs is better)

**Scenario 4**: Active buff = 285 AP, yours = 290 AP
- **Comparison**: 290 > (285 + 5) = FALSE (within threshold)
- **Action**: Don't cast (essentially equal)
- ✅ Correct (avoid spam for minor differences)

## When Data is Loaded

### Initial Load

```lua
-- Commands/Events.lua, VARIABLES_LOADED event
ATW.LoadTalents()
ATW.LoadSpells()   -- Detect spell ranks + cache Rend values
ATW.LoadRacials()  -- Detect racial abilities (Blood Fury, Berserking, etc.)
```

### On Level Up / New Spells / Talent Changes

```lua
-- Commands/Events.lua
elseif event == "PLAYER_LEVEL_UP" or event == "SPELLS_CHANGED" or event == "CHARACTER_POINTS_CHANGED" then
    ATW.LoadTalents()
    ATW.LoadSpells()   -- Re-detect spell ranks + re-cache Rend values
    ATW.LoadRacials()  -- Re-detect racials (Blood Fury AP scales with level)
    ATW.DetectStances()
```

### Events Registered

| Event | Purpose |
|-------|---------|
| VARIABLES_LOADED | Initial load on login |
| PLAYER_LEVEL_UP | New spell ranks available |
| SPELLS_CHANGED | New spells learned |
| CHARACTER_POINTS_CHANGED | Talent points spent/refunded |

## Racial Abilities

### LoadRacials() Function

Detects and loads race-specific abilities:

```lua
-- Player/Talents.lua
function ATW.LoadRacials()
    ATW.Racials = ATW.Racials or {}
    local _, race = UnitRace("player")

    if race == "Orc" then
        ATW.Racials.HasBloodFury = ATW.GetMaxSpellRank("Blood Fury") > 0
    elseif race == "Troll" then
        ATW.Racials.HasBerserking = ATW.GetMaxSpellRank("Berserking") > 0
    elseif race == "Human" then
        ATW.Racials.HasPerception = ATW.GetMaxSpellRank("Perception") > 0
    end
end
```

### Supported Racials

| Race | Ability | Effect | Duration | CD |
|------|---------|--------|----------|-----|
| Orc | Blood Fury | +AP (level * 2) | 15s | 2m |
| Troll | Berserking | 10-15% haste | 10s | 3m |
| Human | Perception | +2% crit | 20s | 3m |

Racials are treated as self-buffs (no target required) and their cooldowns are tracked by the simulation.

## Debug Command

```
/atw spells   - Show all detected spell ranks
```

Example output:
```
--- Spells for Simulator ---
Combat Abilities:
  Execute: R3
  Heroic Strike: R5
  Cleave: R3
  Overpower: R2
  Rend: R4
  Whirlwind: NOT LEARNED
  Slam: NOT LEARNED
Talent Abilities:
  Bloodthirst: NOT LEARNED
  Mortal Strike: NOT LEARNED
  Sweeping Strikes: NOT LEARNED
  Death Wish: NOT LEARNED
Utility:
  Battle Shout: R4
  Charge: R2
  Bloodrage: R1
  Berserker Rage: NOT LEARNED
  Pummel: NOT LEARNED
  Recklessness: NOT LEARNED
Sim will ONLY use learned spells!
```

The green/red coloring and "NOT LEARNED" status helps identify which abilities the simulator will consider.
