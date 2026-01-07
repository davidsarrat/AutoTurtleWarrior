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

| Range | Use | Abilities | Max Targets |
|-------|-----|-----------|-------------|
| 5 yards | Melee range | Rend, Heroic Strike, Execute, Cleave, Sweeping Strikes | Cleave: 2, SS: 1 secondary |
| 8 yards | Whirlwind | Whirlwind only | WW: 4 |
| 8-25 yards | Charge range | Charge | - |

**Important:** Cleave is **NOT** 8 yards - it's a melee range (5yd) ability that hits up to 2 targets.
Whirlwind is the only warrior AoE with 8 yard range.

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
AutoTurtleWarrior_Config = {
    AoEEnabled = true,   -- true = auto AoE, false = single target
    RendSpread = true,   -- Spread Rend to multiple targets
}
```

**Note:** When `AoEEnabled = false`, `RendSpread` is automatically disabled (single target funnel mode).

### Slash Commands

```
/atw aoemode        - Toggle AoE mode
/atw aoemode on     - Enable auto AoE
/atw aoemode off    - Single target mode

/atw rendspread     - Toggle Rend spreading
/atw rendspread on  - Spread Rend to multiple targets
/atw rendspread off - Rend main target only
```

### Mode Logic

```lua
-- In Engine.CaptureCurrentState()
local aoeEnabled = AutoTurtleWarrior_Config.AoEEnabled
if aoeEnabled == nil then aoeEnabled = true end

local rendSpreadEnabled = AutoTurtleWarrior_Config.RendSpread
if rendSpreadEnabled == nil then rendSpreadEnabled = true end

-- AoE OFF implies Rend Spread OFF (single target funnel mode)
if not aoeEnabled then
    rendSpreadEnabled = false
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

## Sweeping Strikes Simulation

Sweeping Strikes provides 5 charges that duplicate melee damage to a secondary target. The simulation properly tracks and consumes these charges.

### How SS Works

- **Charges**: 5 charges per activation
- **Range**: Melee (5 yards) - requires 2+ enemies in melee range
- **Duration**: 20 seconds or until charges consumed
- **Damage**: Duplicates the full damage of the attack to secondary target

### Abilities That Trigger SS

The following abilities consume SS charges in the simulation:

| Ability | Triggers SS? | Notes |
|---------|-------------|-------|
| Auto-attack (MH) | Yes | Only if NOT queueing Cleave |
| Heroic Strike | Yes | Replaces auto, triggers SS |
| Cleave | No | Already multi-target |
| Bloodthirst | Yes | Melee ability |
| Mortal Strike | Yes | Melee ability |
| Overpower | Yes | Melee ability |
| Execute | Yes | Melee ability |
| Slam | Yes | Melee ability |
| Whirlwind | No | Already multi-target |
| Rend | No | DoT, not direct damage |

### Simulation Implementation

```lua
-- In Engine.lua
function Engine.ProcessSweepingStrikes(state, primaryDamage, abilityName)
    -- Check if SS is active with charges
    if not state.sweepingCharges or state.sweepingCharges <= 0 then
        return 0
    end

    -- Need 2+ enemies in melee range for secondary target
    local meleeTargets = state.enemyCountMelee or 1
    if meleeTargets < 2 then
        return 0
    end

    -- Duplicate damage to secondary target
    local ssDamage = primaryDamage

    -- Consume one charge
    state.sweepingCharges = state.sweepingCharges - 1

    -- Deactivate buff if no charges left
    if state.sweepingCharges <= 0 then
        state.hasSweepingStrikes = false
    end

    return ssDamage
end
```

### State Tracking

```lua
state = {
    hasSweepingStrikes = true,   -- Buff active?
    sweepingCharges = 5,         -- Charges remaining (0-5)
    enemyCountMelee = 2,         -- Enemies in melee range
}
```

## Integration with Rotation

### Cleave vs Heroic Strike

```lua
-- Simulation decides based on damage comparison:
-- - Cleave: weapon damage + bonus to 2 targets (5yd)
-- - HS + SS: weapon damage + HS bonus + SS duplicate (if 2+ enemies)

-- When no SS active and 2+ enemies:
if enemies >= 2 then
    return "Cleave"  -- Always better for multi-target
else
    return "HeroicStrike"
end

-- When SS active and 2+ enemies:
-- HS triggers SS for equivalent multi-target damage
-- Simulation compares total damage scenarios
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
