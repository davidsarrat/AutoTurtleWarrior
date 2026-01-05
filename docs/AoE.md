# AoE Detection & Enemy Counting

This document explains how the addon detects and counts nearby enemies.

## Overview

AoE detection is crucial for:
- Deciding when to use Whirlwind vs single-target abilities
- Rend spreading decisions
- Sweeping Strikes optimization
- Cleave vs Heroic Strike choice

## Nameplate Scanning

### How It Works

In vanilla WoW, nameplates are child frames of `WorldFrame`. We scan these to find nearby enemies.

```lua
function ATW.EnemyCount(customRange)
    local range = customRange or 8  -- Default WW range
    local count = 0

    local numChildren = WorldFrame:GetNumChildren()
    local children = { WorldFrame:GetChildren() }

    for i = 1, numChildren do
        local frame = children[i]

        -- Nameplates are visible frames without names
        if frame and frame:IsVisible() and not frame:GetName() then
            local frameChildren = { frame:GetChildren() }

            for _, child in ipairs(frameChildren) do
                -- Find the health bar (StatusBar)
                if child:GetObjectType() == "StatusBar" then
                    local guid = ATW.GetNameplateGUID(frame)

                    if guid and UnitCanAttack("player", guid) == 1 then
                        local dist = ATW.GetDistance(guid)
                        if dist and dist <= range then
                            count = count + 1
                        end
                    end
                    break
                end
            end
        end
    end

    return count
end
```

### Nameplate Identification

Nameplates are identified by:
1. Being a child of `WorldFrame`
2. Being visible
3. Having no name (`frame:GetName() == nil`)
4. Containing a `StatusBar` child (the health bar)

### GUID Extraction (SuperWoW)

```lua
function ATW.GetNameplateGUID(frame)
    if not ATW.HasSuperWoW() then
        return nil
    end

    local ok, guid = pcall(function()
        return frame:GetName(1)  -- SuperWoW feature
    end)

    if ok and guid and guid ~= "" then
        return guid
    end
    return nil
end
```

## Range Constants

| Range | Use | Abilities |
|-------|-----|-----------|
| 5 yards | Melee range | Rend, Heroic Strike, Execute |
| 8 yards | Whirlwind | WW, Cleave |
| 25 yards | Charge range | Charge |

### Convenience Functions

```lua
-- Count enemies in WW range (8 yards)
function ATW.EnemyCount(customRange)
    return -- count at customRange or 8
end

-- Count enemies in melee range (5 yards)
function ATW.MeleeEnemyCount()
    return ATW.EnemyCount(5)
end
```

## Detailed Enemy Information

### GetEnemiesWithTTD

Returns comprehensive data about nearby enemies:

```lua
function ATW.GetEnemiesWithTTD(maxRange)
    maxRange = maxRange or 8
    local enemies = {}

    -- Cleanup expired Rend tracking
    ATW.RendTracker.Cleanup()

    local children = { WorldFrame:GetChildren() }

    for i, frame in ipairs(children) do
        if frame:IsVisible() and not frame:GetName() then
            -- Find StatusBar child
            for _, child in ipairs({ frame:GetChildren() }) do
                if child:GetObjectType() == "StatusBar" then
                    local guid = ATW.GetNameplateGUID(frame)

                    if guid and UnitCanAttack("player", guid) == 1 then
                        local dist = ATW.GetDistance(guid)
                        if dist and dist <= maxRange then
                            -- Get TTD
                            local ttd = ATW.GetUnitTTD(guid) or 30

                            -- Check bleed immunity
                            local bleedImmune, creatureType =
                                ATW.IsBleedImmuneGUID(guid)

                            -- Check Rend status
                            local hasRend = ATW.HasRend(guid)
                            local rendRemaining =
                                ATW.GetRendRemaining(guid)

                            -- Get HP via SuperWoW
                            local hp = UnitHealth(guid)
                            local maxHp = UnitHealthMax(guid)

                            table.insert(enemies, {
                                guid = guid,
                                distance = dist,
                                ttd = ttd,
                                bleedImmune = bleedImmune,
                                creatureType = creatureType,
                                hasRend = hasRend,
                                rendRemaining = rendRemaining,
                                hp = hp,
                                maxHp = maxHp,
                            })
                        end
                    end
                    break
                end
            end
        end
    end

    return enemies
end
```

### Return Data Structure

```lua
{
    guid = "0x0000000012345678",
    distance = 3.5,           -- Yards from player
    ttd = 15.2,               -- Seconds until death
    bleedImmune = false,      -- Can be bled?
    creatureType = "Beast",   -- Creature type
    hasRend = true,           -- Currently has Rend?
    rendRemaining = 12.5,     -- Seconds of Rend left
    hp = 5000,                -- Current HP
    maxHp = 10000,            -- Max HP
}
```

## AoE Mode Detection

### Configuration Options

```lua
AutoTurtleWarrior_Config.AoE = "auto"  -- "on", "off", or "auto"
AutoTurtleWarrior_Config.AoECount = 3  -- Threshold for auto mode
AutoTurtleWarrior_Config.WWRange = 8   -- Detection range
```

### Mode Logic

```lua
function ATW.InAoE()
    local mode = AutoTurtleWarrior_Config.AoE

    if mode == "on" then
        return true
    elseif mode == "off" then
        return false
    end

    -- Auto mode: check enemy count
    return ATW.EnemyCount() >= AutoTurtleWarrior_Config.AoECount
end
```

## Rend Spreading Analysis

### Should We Spread Rend?

```lua
function ATW.ShouldSpreadRend()
    local enemies = ATW.GetEnemiesWithTTD(5)  -- Melee range
    local meleeCount = table.getn(enemies)

    if meleeCount < 1 then
        return false, 0, 0
    end

    -- Count enemies worth Rending
    local worthyTargets = 0
    for _, enemy in ipairs(enemies) do
        if not enemy.hasRend and not enemy.bleedImmune then
            -- HP-based rule: >= 30% HP
            local hpPercent = 100
            if enemy.hp and enemy.maxHp and enemy.maxHp > 0 then
                hpPercent = (enemy.hp / enemy.maxHp) * 100
            end

            if hpPercent >= 30 then
                worthyTargets = worthyTargets + 1
            end
        end
    end

    -- Use simulation to compare strategies
    if worthyTargets >= 1 and ATW.FindOptimalStrategy then
        local strategy, gain = ATW.FindOptimalStrategy()
        if strategy == "rend_spread" and gain > 0 then
            return true, worthyTargets, gain
        end
    end

    return false, worthyTargets, 0
end
```

### Rend-Worthy Criteria

A target is worth Rending if:
1. Doesn't already have Rend (`!hasRend`)
2. Not bleed-immune (`!bleedImmune`)
3. HP >= 30% (will live long enough for value)
4. Within melee range (5 yards)

## Performance Considerations

### Nameplate Scanning Cost

Scanning nameplates is relatively expensive. Mitigations:

1. **Throttled updates**: Only scan every 0.25s (via OnUpdate)
2. **Early exit**: Stop checking children once StatusBar found
3. **Cached data**: Creature types cached to avoid repeated lookups

### Memory Management

```lua
ATW.TTD = {
    maxUnits = 20,  -- Limit tracked units
}
```

Oldest units are removed when limit is reached.

## Debug Command

```
/atw aoe
```

Example output:
```
--- AoE Analysis ---
WW range (8yd): 4 enemies
Melee range (5yd): 3 enemies
REND SPREAD: 2 targets
  Total Rend dmg: 1340

Enemies (with Rend tracking):
  3.2yd | HP: 75% | TTD: 18s [Beast]
  4.1yd | HP: 60% | TTD: 12s [REND 15.2s] [Beast]
  4.8yd | HP: 45% | TTD: 8s [Humanoid]
  7.2yd | HP: 90% | TTD: 25s [Beast]
```

## Integration with Rotation

### Priority Decisions

```lua
-- In Rotation.lua
local enemies = ATW.EnemyCount(8)

if enemies >= 3 then
    -- Consider Whirlwind/Cleave priority
    if ATW.Ready("Whirlwind") and rage >= 25 then
        -- WW is high priority in AoE
    end
end

if enemies >= 2 then
    -- Consider Sweeping Strikes
    if ATW.Talents.HasSS and ATW.Ready("Sweeping Strikes") then
        -- SS before big hits
    end
end
```

### Cleave vs Heroic Strike

```lua
-- When rage dumping
if ATW.InAoE() and rage >= 20 then
    return "Cleave"
else
    return "HeroicStrike"
end
```

## Distance Calculation

### Using SuperWoW UnitXYZ

```lua
function ATW.GetDistance(unitOrGUID)
    if not ATW.HasSuperWoW() then
        return nil
    end

    local px, py, pz = UnitXYZ("player")
    local tx, ty, tz = UnitXYZ(unitOrGUID)

    if px and tx then
        local dx = px - tx
        local dy = py - ty
        local dz = pz - tz
        return math.sqrt(dx*dx + dy*dy + dz*dz)
    end

    return nil
end
```

### 3D vs 2D Distance

We use 3D distance (including Z-axis) for accuracy with terrain elevation. This prevents counting enemies on different floors/levels.
