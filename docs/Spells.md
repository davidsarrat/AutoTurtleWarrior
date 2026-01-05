# Spell & Talent System

This document explains how spell ranks and talents are detected and used.

## Overview

The addon dynamically detects:
1. **Talents** - Points spent in each talent
2. **Spells** - Which spells are known and their maximum rank

This allows the simulation to use correct values regardless of character level or spec.

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
ATW.Talents.ChargeRage = 9 + (r * 3)

-- Tactical Mastery (tier 3, slot 1)
-- Retain 5/10/15/20/25 rage when switching stances
_, _, _, _, r = GetTalentInfo(1, 5)
ATW.Talents.TM = r * 5

-- Improved Overpower (tier 5, slot 1)
-- +25/50% crit chance on Overpower
_, _, _, _, r = GetTalentInfo(1, 9)
ATW.Talents.ImpOP = r * 25

-- Anger Management (tier 5, slot 2)
-- Generates 1 rage every 3 seconds
_, _, _, _, r = GetTalentInfo(1, 10)
ATW.Talents.AngerManagement = r > 0

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

-- Enrage (tier 5, slot 3)
-- On crit, +5/10/15/20/25% damage for 12s
_, _, _, _, r = GetTalentInfo(2, 11)
ATW.Talents.Enrage = r

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

## TurtleWoW Talent Differences

TurtleWoW has modified some talents from vanilla:

| Talent | Vanilla | TurtleWoW |
|--------|---------|-----------|
| Improved Rend | 3 pts, +15/25/35% dmg | 2 pts, +10/20% dmg |
| Unbridled Wrath | +1 rage | +1 rage (1H), +2 rage (2H) |

## Spell Rank Detection

### Finding Max Rank

```lua
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
                    maxRank = 1  -- No rank = rank 1
                end
            end
            id = id + 1
        end
    end

    return maxRank
end
```

### Loading Spell Data

```lua
function ATW.LoadSpells()
    ATW.Spells = ATW.Spells or {}

    -- Core combat spells
    ATW.Spells.RendRank = ATW.GetMaxSpellRank("Rend")
    ATW.Spells.HasRend = ATW.Spells.RendRank > 0
    ATW.Spells.ExecuteRank = ATW.GetMaxSpellRank("Execute")
    ATW.Spells.WhirlwindRank = ATW.GetMaxSpellRank("Whirlwind")
    ATW.Spells.BloodthirstRank = ATW.GetMaxSpellRank("Bloodthirst")
    ATW.Spells.MortalStrikeRank = ATW.GetMaxSpellRank("Mortal Strike")
    ATW.Spells.HeroicStrikeRank = ATW.GetMaxSpellRank("Heroic Strike")
    ATW.Spells.BattleShoutRank = ATW.GetMaxSpellRank("Battle Shout")

    -- Update RendTracker with actual duration
    if ATW.RendTracker and ATW.Spells.RendRank > 0 then
        ATW.RendTracker.REND_DURATION = ATW.GetRendDuration()
    end
end
```

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

## Dynamic Rend Functions

### Duration

```lua
function ATW.GetRendDuration()
    local rank = ATW.Spells and ATW.Spells.RendRank or 0
    if rank <= 0 then return 0 end

    local data = ATW.RendData[rank]
    return data and data.duration or 21
end
```

### Damage (with talent bonus)

```lua
function ATW.GetRendDamage()
    local rank = ATW.Spells and ATW.Spells.RendRank or 0
    if rank <= 0 then return 0 end

    local data = ATW.RendData[rank]
    if not data then return 0 end

    local baseDamage = data.damage

    -- Apply Improved Rend talent
    -- TurtleWoW: 10% per point (2 points max)
    local impRend = ATW.Talents and ATW.Talents.ImpRend or 0
    if impRend > 0 then
        baseDamage = baseDamage * (1 + impRend * 0.10)
    end

    return baseDamage
end
```

### Ticks

```lua
function ATW.GetRendTicks()
    local duration = ATW.GetRendDuration()
    return math.floor(duration / 3)  -- Ticks every 3 seconds
end
```

### Damage per Tick

```lua
function ATW.GetRendTickDamage()
    local totalDamage = ATW.GetRendDamage()
    local ticks = ATW.GetRendTicks()
    if ticks <= 0 then return 0 end
    return totalDamage / ticks
end
```

## Usage in Simulation

### Abilities.lua

```lua
Rend = {
    name = "Rend",
    rage = 10,
    stance = {1, 2},
    damage = function(stats)
        -- Dynamic values from spell rank
        local baseDmg = ATW.GetRendDamage() or 147
        local ticks = ATW.GetRendTicks() or 7
        local apScaling = stats.AP * 0.05 * ticks
        return baseDmg + apScaling
    end,
    condition = function(state)
        -- Check if Rend is learned
        if ATW.Spells and not ATW.Spells.HasRend then
            return false
        end
        -- ... other conditions
    end,
}
```

### Engine.lua

```lua
function Engine.ApplyRend(state, targetId)
    -- Dynamic tick damage
    local baseTickDmg = ATW.GetRendTickDamage() or 21
    local tickDamage = baseTickDmg + (Engine.GetEffectiveAP(state) * 0.05)

    -- Dynamic duration
    local duration = ATW.GetRendDuration() or 21
    local durationMs = duration * 1000

    state.dots.rend[targetId] = {
        endTime = state.time + durationMs,
        nextTick = state.time + 3000,
        tickDamage = tickDamage,
        tickInterval = 3000,
    }
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
    ATW.DetectStances()
```

## Debug Commands

```
/atw spells   - Show detected spell ranks
```

Example output:
```
--- Spell Ranks ---
Rend: Rank 7 | 147 dmg / 21s (7 ticks)
  Improved Rend: +20% damage
Execute: Rank 3
Whirlwind: Rank 1
Heroic Strike: Rank 9
Battle Shout: Rank 7
Bloodthirst: Rank 1
```

## Spell Availability Check

Before suggesting an ability, we check if it's learned:

```lua
-- In ability condition
condition = function(state)
    if ATW.Spells and not ATW.Spells.HasRend then
        return false  -- Don't suggest if not learned
    end
    -- ...
end
```

This prevents the addon from suggesting abilities the character hasn't trained yet.
