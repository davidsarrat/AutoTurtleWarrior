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

    -- Update RendTracker duration with actual spell rank
    if ATW.RendTracker and ATW.Spells.RendRank > 0 then
        ATW.RendTracker.REND_DURATION = ATW.GetRendDuration()
    end
end
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
-- Cruelty (tier 1, slot 2)
-- +1/2/3/4/5% crit chance
_, _, _, _, r = GetTalentInfo(2, 2)
ATW.Talents.Cruelty = r

-- Unbridled Wrath (tier 2, slot 3)
-- 8/16/24/32/40% chance for +1 rage on hit
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

TurtleWoW has modified some talents from vanilla:

| Talent | Vanilla | TurtleWoW |
|--------|---------|-----------|
| Improved Rend | 3 pts, +15/25/35% dmg | 2 pts, +10/20% dmg |
| Unbridled Wrath | +1 rage | +1 rage (1H), +2 rage (2H) |

## Rend Data by Rank

```lua
ATW.RendData = {
    -- [rank] = { damage, duration, level }
    [1] = { damage = 15,  duration = 9,  level = 4 },
    [2] = { damage = 28,  duration = 12, level = 10 },
    [3] = { damage = 45,  duration = 15, level = 20 },
    [4] = { damage = 66,  duration = 18, level = 30 },
    [5] = { damage = 98,  duration = 21, level = 40 },
    [6] = { damage = 126, duration = 21, level = 50 },
    [7] = { damage = 147, duration = 21, level = 60 },
}
```

## Dynamic Spell Functions

### Rend Duration

```lua
function ATW.GetRendDuration()
    local rank = ATW.Spells and ATW.Spells.RendRank or 0
    if rank <= 0 then return 0 end
    local data = ATW.RendData[rank]
    return data and data.duration or 21
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

## When Data is Loaded

### Initial Load

```lua
-- Commands/Events.lua, VARIABLES_LOADED event
ATW.LoadTalents()
ATW.LoadSpells()
```

### On Level Up / New Spells

```lua
-- Commands/Events.lua
elseif event == "PLAYER_LEVEL_UP" or event == "SPELLS_CHANGED" then
    ATW.LoadTalents()
    ATW.LoadSpells()  -- Re-detect spell ranks
```

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
