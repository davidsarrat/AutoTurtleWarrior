# Simulation Engine

This document explains how the DPR-based simulation engine works.

## Overview

The simulation engine predicts optimal ability usage by calculating **Damage Per Rage (DPR)** for each available ability and simulating combat scenarios.

## DPR (Damage Per Rage)

DPR is the primary metric for ability prioritization:

```
DPR = Expected Damage / Rage Cost
```

### Why DPR?

Rage is the limiting resource for Warriors. By maximizing damage per rage spent, we ensure optimal DPS output regardless of rage income variations.

### Example DPR Calculations

With 1500 AP:

| Ability | Damage | Rage | DPR |
|---------|--------|------|-----|
| Bloodthirst | ~725 | 30 | 24.2 |
| Whirlwind | ~600 | 25 | 24.0 |
| Heroic Strike | ~350 | 15 | 23.3 |
| Execute (low rage) | ~600 | 15 | 40.0 |
| Rend (full duration) | ~670 | 10 | 67.0 |

## Engine Architecture

### File: `Sim/Engine.lua`

```lua
ATW.Engine = {}

-- Constants
Engine.REND_AP_COEFF = 0.05      -- 5% AP per tick
Engine.SLAM_BONUS = 87           -- TurtleWoW Slam bonus
Engine.DW_PERCENT = 0.60         -- Deep Wounds 60% weapon damage

-- Buff durations (milliseconds)
Engine.BUFF_DURATIONS = {
    Enrage = 12000,
    DeathWish = 30000,
    Recklessness = 15000,
    BattleShout = 120000,
    Rend = 21000,  -- Dynamic from spell rank
}
```

## State Object

The simulation uses a state object to track combat conditions:

```lua
state = {
    -- Resources
    time = 0,               -- Current time (ms)
    rage = 50,              -- Current rage
    gcd = 0,                -- GCD end time

    -- Player stats
    ap = 1500,              -- Attack power
    crit = 25,              -- Crit chance %
    hit = 8,                -- Hit chance bonus %

    -- Weapon info
    mhSpeed = 2.6,          -- Main hand speed
    mhMin = 100,            -- Main hand min damage
    mhMax = 200,            -- Main hand max damage
    ohSpeed = 2.4,          -- Off-hand speed (if dual wield)

    -- Cooldowns (end times in ms)
    cooldowns = {
        Bloodthirst = 0,
        Whirlwind = 0,
        Overpower = 0,
        Execute = 0,
    },

    -- Active buffs
    buffs = {
        Enrage = { endTime = 0 },
        DeathWish = { endTime = 0 },
        Flurry = { charges = 0 },
        BattleShout = { endTime = 0 },
    },

    -- DoTs
    dots = {
        rend = {},      -- [targetId] = { endTime, nextTick, tickDamage }
        deepWounds = {},
    },

    -- Combat state
    stance = 3,             -- Current stance (1/2/3)
    tacticalMastery = 25,   -- Rage retained on stance switch

    -- Target info
    targetHP = 100,         -- Target HP %
    targetTTD = 30,         -- Target TTD seconds
}
```

## Damage Calculations

### Weapon Damage

```lua
function Engine.RollWeaponDamage(state, isOH, normalized)
    local min, max, speed

    if isOH then
        min = state.ohMin or 50
        max = state.ohMax or 100
        speed = state.ohSpeed or 2.4
    else
        min = state.mhMin or 100
        max = state.mhMax or 200
        speed = state.mhSpeed or 2.6
    end

    -- Random damage roll
    local baseDmg = min + math.random() * (max - min)

    -- AP contribution
    local apBonus
    if normalized then
        -- Normalized: use 2.4 for 1H, 3.3 for 2H
        apBonus = (state.ap / 14) * 2.4
    else
        -- Non-normalized: use actual weapon speed
        apBonus = (state.ap / 14) * speed
    end

    local damage = baseDmg + apBonus

    -- Off-hand penalty (50% damage)
    if isOH then
        damage = damage * 0.5
    end

    return damage
end
```

### Ability Damage

```lua
function Engine.CalculateAbilityDamage(state, abilityName)
    local damage = 0

    if abilityName == "Bloodthirst" then
        -- 45% of AP
        damage = state.ap * 0.45

    elseif abilityName == "Whirlwind" then
        -- Normalized weapon damage
        damage = Engine.RollWeaponDamage(state, false, true)

    elseif abilityName == "Execute" then
        -- Base 600 + 15 per extra rage
        local extraRage = math.max(0, state.rage - 15)
        damage = 600 + (extraRage * 15)

    elseif abilityName == "HeroicStrike" then
        -- Weapon damage + 138 (rank 9)
        damage = Engine.RollWeaponDamage(state, false, false) + 138

    elseif abilityName == "Rend" then
        -- DoT: base + 5% AP per tick
        -- Calculated when applied, not here
        damage = 0
    end

    return damage
end
```

### Crit Calculation

```lua
function Engine.GetCritChance(state, abilityName)
    local crit = state.crit or 20

    -- Recklessness: +100% crit
    if state.buffs.Recklessness and
       state.buffs.Recklessness.endTime > state.time then
        crit = crit + 100
    end

    -- Improved Overpower: +25/50% crit
    if abilityName == "Overpower" and ATW.Talents.ImpOP then
        crit = crit + ATW.Talents.ImpOP
    end

    return math.min(100, crit)
end
```

### Effective AP (with buffs)

```lua
function Engine.GetEffectiveAP(state)
    local ap = state.ap or 1000

    -- Battle Shout
    if state.buffs.BattleShout and
       state.buffs.BattleShout.endTime > state.time then
        ap = ap + 232  -- Rank 7
    end

    -- Crusader proc
    if state.buffs.Crusader and
       state.buffs.Crusader.endTime > state.time then
        ap = ap + 200
    end

    return ap
end
```

## Priority System

### GetNextAbility Flow

```lua
function ATW.GetNextAbility()
    local state = Engine.CreateState()
    local abilities = {}

    -- Gather available abilities
    for name, ability in pairs(ATW.Abilities) do
        if Engine.IsAbilityUsable(state, name) then
            local dpr = Engine.CalculateDPR(state, name)
            table.insert(abilities, {
                name = name,
                dpr = dpr,
                needsDance = Engine.NeedsStanceSwitch(state, name),
            })
        end
    end

    -- Sort by DPR (highest first)
    table.sort(abilities, function(a, b)
        return a.dpr > b.dpr
    end)

    -- Return best ability
    if abilities[1] then
        return abilities[1].name,
               abilities[1].needsDance,
               abilities[1].targetStance,
               abilities[1].targetGUID
    end

    return nil
end
```

### DPR Calculation with Stance Cost

```lua
function Engine.CalculateEffectiveDPR(state, abilityName)
    local damage = Engine.CalculateAbilityDamage(state, abilityName)
    local rageCost = ATW.Abilities[abilityName].rage

    -- Factor in stance switch cost
    local needsSwitch, targetStance = Engine.NeedsStanceSwitch(state, abilityName)
    if needsSwitch then
        local rageLost = math.max(0, state.rage - state.tacticalMastery)
        rageCost = rageCost + rageLost
    end

    -- Effective DPR
    if rageCost <= 0 then
        return damage * 100  -- Free abilities are very high priority
    end

    return damage / rageCost
end
```

## Time-Based Simulation

### Full Combat Simulation

```lua
function Engine.SimulateCombat(duration)
    local state = Engine.CreateState()
    local totalDamage = 0
    local endTime = state.time + (duration * 1000)

    while state.time < endTime do
        -- Process auto-attacks
        if state.nextMHSwing <= state.time then
            totalDamage = totalDamage + Engine.ProcessAutoAttack(state, false)
            state.nextMHSwing = state.time + (state.mhSpeed * 1000)
        end

        -- Process GCD abilities
        if state.gcd <= state.time then
            local ability = Engine.GetBestAbility(state)
            if ability and state.rage >= ability.rage then
                local dmg = Engine.UseAbility(state, ability.name)
                totalDamage = totalDamage + dmg
            end
        end

        -- Process DoT ticks
        totalDamage = totalDamage + Engine.ProcessDoTs(state)

        -- Advance time
        state.time = state.time + 100  -- 100ms steps
    end

    return totalDamage, state
end
```

### Rend Application in Simulation

```lua
function Engine.ApplyRend(state, targetId)
    if not state.dots.rend then
        state.dots.rend = {}
    end

    -- Dynamic damage from spell rank
    local baseTickDmg = ATW.GetRendTickDamage() or 21
    local tickDamage = baseTickDmg + (Engine.GetEffectiveAP(state) * 0.05)

    -- Dynamic duration from spell rank
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

## Strategy Comparison

The engine can compare different strategies to find optimal play:

```lua
function ATW.FindOptimalStrategy()
    -- Simulate normal rotation
    local normalDmg = Engine.SimulateCombat(20)

    -- Simulate with Rend spreading
    local rendSpreadDmg = Engine.SimulateRendSpread(20)

    -- Calculate gain
    local gain = ((rendSpreadDmg - normalDmg) / normalDmg) * 100

    if gain > 0 then
        return "rend_spread", gain
    else
        return "normal", 0
    end
end
```

## Debug Output

```
/atw sim      - Show next 5 ability predictions
/atw engine   - Full 20s combat simulation
/atw strat    - Compare strategies
/atw prio     - Show DPR priority list
```
