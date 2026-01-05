# Swing Timer System

This document explains how the addon tracks weapon swing timers.

## Overview

The swing timer is critical for:
- Knowing when the next auto-attack will land
- Timing Heroic Strike/Cleave to not clip swings
- Slam usage (TurtleWoW: Slam resets swing timer)
- Optimal ability queuing

## Combat Log Parsing

### Events Used

```lua
EventFrame:RegisterEvent("CHAT_MSG_COMBAT_SELF_HITS")
EventFrame:RegisterEvent("CHAT_MSG_COMBAT_SELF_MISSES")
EventFrame:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
```

### Swing Detection

Swings are detected via combat log messages:

```lua
function ATW.ParseCombatLogForSwing(msg, event)
    local now = GetTime()

    if event == "CHAT_MSG_COMBAT_SELF_HITS" then
        -- "You hit X for Y damage."
        -- "You crit X for Y damage."
        if strfind(msg, "^You hit") or strfind(msg, "^You crit") then
            ATW.OnMainHandSwing(now)
        end

    elseif event == "CHAT_MSG_COMBAT_SELF_MISSES" then
        -- "You miss X."
        -- "Your attack was parried."
        -- "Your attack was dodged."
        -- "Your attack was blocked."
        if strfind(msg, "^You miss") or
           strfind(msg, "^Your attack") then
            ATW.OnMainHandSwing(now)
        end

    elseif event == "CHAT_MSG_SPELL_SELF_DAMAGE" then
        -- Heroic Strike/Cleave hits are spell damage
        -- "Your Heroic Strike hits X for Y damage."
        -- "Your Cleave hits X for Y damage."
        if strfind(msg, "^Your Heroic Strike") or
           strfind(msg, "^Your Cleave") then
            ATW.OnMainHandSwing(now)
            ATW.OnSwingAbilityUsed()
        end
    end
end
```

## Swing Timer State

### File: `Combat/SwingTimer.lua`

```lua
ATW.SwingTimer = {
    -- Main hand
    mhSpeed = 2.6,          -- Base speed (seconds)
    mhLastSwing = 0,        -- Time of last swing
    mhNextSwing = 0,        -- Predicted next swing

    -- Off-hand (if dual wielding)
    ohSpeed = 2.4,
    ohLastSwing = 0,
    ohNextSwing = 0,

    -- Modifiers
    hasteMultiplier = 1.0,  -- From Flurry, etc.
    flurryCharges = 0,

    -- Queue state
    queuedAbility = nil,    -- "HeroicStrike" or "Cleave"
    queuedTime = 0,
}
```

## Swing Processing

### On Main Hand Swing

```lua
function ATW.OnMainHandSwing(timestamp)
    local timer = ATW.SwingTimer

    -- Record this swing
    timer.mhLastSwing = timestamp

    -- Calculate next swing time
    local speed = timer.mhSpeed

    -- Apply haste (Flurry)
    if timer.flurryCharges > 0 then
        local flurryBonus = ATW.Talents.Flurry * 5 + 5  -- 10/15/20/25/30%
        speed = speed / (1 + flurryBonus / 100)
        timer.flurryCharges = timer.flurryCharges - 1
    end

    timer.mhNextSwing = timestamp + speed
end
```

### Flurry Tracking

Flurry is triggered on critical strikes:

```lua
function ATW.OnCriticalStrike()
    local timer = ATW.SwingTimer

    if ATW.Talents.Flurry and ATW.Talents.Flurry > 0 then
        timer.flurryCharges = 3  -- 3 swings of bonus speed
    end
end
```

## Querying Swing State

### Time Until Next Swing

```lua
function ATW.GetMHSwingRemaining()
    local timer = ATW.SwingTimer
    local now = GetTime()

    if timer.mhNextSwing > now then
        return timer.mhNextSwing - now
    end

    return 0  -- Swing ready or no data
end
```

### Is Swing Ready?

```lua
function ATW.IsMHSwingReady()
    return ATW.GetMHSwingRemaining() <= 0
end
```

## Heroic Strike / Cleave Queue

### Queue Tracking

```lua
function ATW.OnSwingAbilityQueued(abilityName)
    ATW.SwingTimer.queuedAbility = abilityName
    ATW.SwingTimer.queuedTime = GetTime()
end

function ATW.OnSwingAbilityUsed()
    ATW.SwingTimer.queuedAbility = nil
    ATW.SwingTimer.queuedTime = 0
end

function ATW.HasSwingAbilityQueued()
    return ATW.SwingTimer.queuedAbility ~= nil
end
```

### Cancel Logic

Sometimes we want to cancel a queued HS/Cleave:
- Execute target appeared (need rage)
- Running low on rage
- Target dying

```lua
function ATW.ShouldCancelSwingAbility()
    if not ATW.HasSwingAbilityQueued() then
        return false, nil
    end

    local rage = UnitMana("player")

    -- Cancel for Execute
    if ATW.InExecutePhase("target") then
        local execCost = ATW.Talents.ExecCost or 15
        if rage < execCost + 30 then
            return true, "need rage for Execute"
        end
    end

    -- Cancel if very low rage
    if rage < 20 then
        return true, "rage too low"
    end

    return false, nil
end

function ATW.CancelSwingAbility()
    -- In vanilla, you cancel by stopping attack briefly
    -- This is done via macro or SpellStopCasting
    if ATW.SwingTimer.queuedAbility then
        -- Clear queue state
        ATW.SwingTimer.queuedAbility = nil
        ATW.SwingTimer.queuedTime = 0
    end
end
```

## Weapon Speed Detection

### From Equipment

```lua
function ATW.UpdateWeaponSpeeds()
    local timer = ATW.SwingTimer

    -- Main hand
    local mhLink = GetInventoryItemLink("player", 16)
    if mhLink then
        -- Parse tooltip for speed
        -- Or use hardcoded values from item database
        timer.mhSpeed = ATW.GetWeaponSpeed(mhLink) or 2.6
    end

    -- Off-hand
    local ohLink = GetInventoryItemLink("player", 17)
    if ohLink then
        timer.ohSpeed = ATW.GetWeaponSpeed(ohLink) or 2.4
        timer.hasOffHand = true
    else
        timer.hasOffHand = false
    end
end
```

### Common Weapon Speeds

| Weapon Type | Speed Range |
|-------------|-------------|
| Daggers | 1.3 - 1.8 |
| 1H Swords | 1.8 - 2.6 |
| 1H Axes | 1.5 - 2.7 |
| 2H Swords | 3.0 - 3.8 |
| 2H Axes | 3.0 - 3.7 |

## Integration with Simulation

### Engine State

```lua
state = {
    mhSpeed = 2.6,
    ohSpeed = 2.4,
    nextMHSwing = 0,      -- Time of next MH swing (ms)
    nextOHSwing = 0,      -- Time of next OH swing (ms)
    hsQueued = false,     -- HS/Cleave queued
}
```

### Simulation Loop

```lua
function Engine.SimulateCombat(duration)
    local state = Engine.CreateState()

    -- Initialize swing timers from real state
    state.nextMHSwing = ATW.GetMHSwingRemaining() * 1000
    state.nextOHSwing = ATW.GetOHSwingRemaining() * 1000

    while state.time < duration do
        -- Process MH swing
        if state.nextMHSwing <= state.time then
            damage = Engine.ProcessAutoAttack(state, false)
            state.nextMHSwing = state.time + (state.mhSpeed * 1000)
        end

        -- Process OH swing (if dual wield)
        if state.hasOffHand and state.nextOHSwing <= state.time then
            damage = Engine.ProcessAutoAttack(state, true)
            state.nextOHSwing = state.time + (state.ohSpeed * 1000)
        end

        state.time = state.time + 100
    end
end
```

## HS/Cleave Decision Making

### Rage Thresholds

```lua
-- Default config
AutoTurtleWarrior_Config.HSRage = 50  -- Only HS when rage > 50
```

### Decision Logic

```lua
function ATW.ShouldUseHeroicStrike()
    local rage = UnitMana("player")
    local threshold = AutoTurtleWarrior_Config.HSRage

    -- Check rage threshold
    if rage < threshold then
        return false
    end

    -- Don't HS if BT/WW coming off CD soon
    if ATW.Talents.HasBT then
        local btReady = ATW.Ready("Bloodthirst")
        if btReady then return false end
    end

    local wwReady = ATW.Ready("Whirlwind")
    if wwReady then return false end

    -- Safe to HS
    return true
end
```

## Debug Command

```
/atw swing
```

Example output:
```
--- Swing Timer ---
MH Speed: 2.60s
MH Next: 1.23s
OH Speed: 2.40s
OH Next: 0.87s
Flurry: 2 charges
Queued: Heroic Strike
```

## Accuracy Limitations

Swing timer accuracy in vanilla is limited by:

1. **Combat log latency**: Messages arrive slightly after events
2. **No direct API**: Can't query actual swing state
3. **Haste calculation**: Must track all haste sources manually
4. **Parry haste**: Enemy parries speed up enemy attacks (not tracked)

The system provides "best effort" tracking that's accurate enough for rotation decisions but may drift over long fights.
