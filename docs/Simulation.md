# Simulation Engine

100% simulation-based decision system (Zebouski-style). **NO HARDCODED PRIORITIES**.

## Overview

The addon uses a **pure simulation approach** to determine the optimal ability at any moment:

1. **Capture State**: Snapshot current combat state (all enemies, Rend status, cooldowns, combat state)
2. **Generate Actions**: List all valid actions from current state (only learned spells!)
3. **Simulate Each**: For each action, simulate 6 seconds of combat
4. **Compare Damage**: Pick the action that yields highest total damage

This is the same approach used by the [Zebouski WarriorSim](https://zebouski.github.io/WarriorSim-TurtleWoW/).

## Core Functions

### File: `Sim/Engine.lua`

```
Engine.GetRecommendation()
    └── Engine.GetRecommendationSimBased()
            └── Engine.GetBestAction()
                    ├── Engine.CaptureCurrentState()  -- Get combat state
                    ├── Engine.GetValidActions()      -- List valid actions (hasSpell checks!)
                    └── Engine.SimulateDecisionHorizon()  -- Simulate each
```

## Decision Flow

### 1. CaptureCurrentState()

Captures the full combat state including **multi-target** and **combat state** for Charge:

```lua
state = {
    -- Resources
    rage = 50,                  -- Current rage
    stance = 3,                 -- Current stance (1=Battle, 2=Def, 3=Berserker)

    -- Combat State (for Charge)
    inCombat = true,            -- In combat? (Charge requires out of combat)
    targetDistance = 15,        -- Distance to target in yards

    -- Player
    ap = 1500,                  -- Attack power
    crit = 25,                  -- Crit %
    mhDmgMin = 100,             -- Weapon damage range
    mhDmgMax = 200,
    mhSpeed = 2600,             -- Main hand speed (ms)
    hasOH = false,              -- Has off-hand weapon?
    tacticalMastery = 25,       -- Rage retained on stance switch

    -- Buffs
    hasBattleShout = true,      -- Battle Shout active?
    hasDeathWish = false,       -- Death Wish active?
    hasRecklessness = false,    -- Recklessness active?
    hasBerserkerRage = false,   -- Berserker Rage active?
    hasSweepingStrikes = false, -- Sweeping Strikes active?
    hasBloodrageActive = false, -- Bloodrage ticking?
    overpowerReady = true,      -- Overpower proc available?
    overpowerEnd = 3000,        -- Time until window expires (ms)

    -- Swing Queue
    swingQueued = nil,          -- nil, "hs", "cleave"

    -- Current Target
    targetGUID = "0x...",
    targetHPPercent = 85,
    targetTTD = 25000,          -- Time to die (ms)
    targetBleedImmune = false,
    rendOnTarget = false,       -- Has Rend?
    rendRemaining = 0,          -- Rend duration left (ms)

    -- Multi-Target (ALL enemies in range)
    enemies = {
        { guid="0x1", hpPercent=85, ttd=25000, hasRend=false, distance=5, isTarget=true },
        { guid="0x2", hpPercent=70, ttd=20000, hasRend=true, distance=4, isTarget=false },
        { guid="0x3", hpPercent=90, ttd=30000, hasRend=false, distance=7, isTarget=false },
    },
    enemyCount = 3,
    enemyCountMelee = 2,        -- 5yd (Rend/Cleave range)
    enemyCountWW = 3,           -- 8yd (Whirlwind range)

    -- Cooldowns (ms remaining, 0 = ready)
    cooldowns = {
        Bloodthirst = 0,
        Whirlwind = 3000,
        MortalStrike = 0,
        Overpower = 0,
        Execute = 0,
        Slam = 0,
        Charge = 0,
        Bloodrage = 0,
        BerserkerRage = 0,
        DeathWish = 0,
        Recklessness = 0,
        SweepingStrikes = 0,
        Pummel = 0,
    },
}
```

### 2. GetValidActions(state)

Generates ALL valid actions from current state. **Every ability is wrapped with `hasSpell()` to verify it's learned**:

```lua
-- Helper function checks if spell is learned
local function hasSpell(spellName)
    -- Returns false if not learned - prevents pooling for unavailable abilities
    -- See Documentation/Spells.md for details
end

actions = {}

-- Charge (OUT OF COMBAT ONLY, 8-25 yard range)
if hasSpell("Charge") and not state.inCombat then
    local inChargeRange = state.targetDistance >= 8 and state.targetDistance <= 25
    if inChargeRange and state.cooldowns.Charge <= 0 then
        local chargeRage = ATW.Talents.ChargeRage or 9  -- 9 + Improved Charge
        table.insert(actions, {name = "Charge", stance = 1, rage = 0, rageGain = chargeRage})
    end
end

-- Execute (target < 20%)
if inExecute and hasSpell("Execute") then
    table.insert(actions, {name = "Execute", stance = stance, rage = execCost})
end

-- Bloodthirst (Fury talent)
if hasSpell("Bloodthirst") and state.cooldowns.Bloodthirst <= 0 then
    table.insert(actions, {name = "Bloodthirst", stance = 3, rage = 30})
end

-- Slam (2H weapons only, resets swing timer)
if hasSpell("Slam") and not state.hasOH then
    table.insert(actions, {name = "Slam", stance = stance, rage = 15})
end

-- Heroic Strike / Cleave (NO THRESHOLD - simulation decides)
if hasSpell("HeroicStrike") then
    if rage >= hsCost and not swingQueued then
        table.insert(actions, {name = "HeroicStrike", rage = hsCost, offGCD = true})
    end
end

-- Always valid fallback
table.insert(actions, {name = "Wait", rage = 0})
```

**Key Points:**
- Every ability checks `hasSpell()` first
- Charge requires `not state.inCombat` AND 8-25 yard range
- Slam only available for 2H weapons (`not state.hasOH`)
- HS/Cleave have NO threshold - simulation decides optimal rage management
- Multi-target Rend generates one action per enemy that needs it

### 3. GetActionDamage(state, action)

Calculates expected damage for an action:

```lua
-- Bloodthirst: 45% AP
damage = ap * 0.45

-- Whirlwind: weapon damage × targets (max 4)
damage = weaponDmg * min(4, state.enemyCountWW)

-- Execute: base + excess rage × coefficient
damage = 600 + (rage - 15) * 15

-- Charge: value = rage generated (no direct damage)
local rageGain = action.rageGain or 9
damage = rageGain * 5  -- Conservative damage equivalent

-- Slam: weapon damage + bonus
damage = weaponDmg + slamBonus

-- Rend: tick damage × ticks (based on TARGET-SPECIFIC TTD)
tickDamage = baseTickDmg + (ap * 0.05)
numTicks = min(7, floor(action.targetTTD / 3000))
damage = tickDamage * numTicks

-- Apply crit expectation
if canCrit then
    damage = damage * (1 + critChance * (critMult - 1))
end
```

### 4. ApplyAction(state, action) - Combat State Tracking

When an action is applied, state is updated. **Offensive abilities set `inCombat = true`** which blocks future Charge:

```lua
function ApplyAction(state, action)
    local newState = DeepCopyState(state)

    -- Stance switch FIRST (TM cap applies before ability cost)
    if action.needsDance then
        newState.rage = min(newState.rage, newState.tacticalMastery)
        newState.stance = action.stance
    end

    -- Pay rage cost
    newState.rage = newState.rage - action.rage

    -- Ability-specific effects
    if action.name == "Execute" then
        newState.rage = 0  -- Consumes ALL rage
        newState.inCombat = true

    elseif action.name == "Bloodthirst" then
        newState.cooldowns.Bloodthirst = 6000
        newState.inCombat = true

    elseif action.name == "Whirlwind" then
        newState.cooldowns.Whirlwind = 10000
        newState.inCombat = true

    elseif action.name == "Slam" then
        -- Slam RESETS swing timer (important penalty!)
        newState.mhTimer = newState.mhSpeed
        newState.inCombat = true

    elseif action.name == "Charge" then
        -- Charge enters combat and generates rage
        newState.inCombat = true
        newState.cooldowns.Charge = 15000
        newState.rage = min(100, newState.rage + action.rageGain)

    elseif action.name == "Bloodrage" then
        newState.cooldowns.Bloodrage = 60000
        newState.hasBloodrageActive = true
        newState.inCombat = true  -- Bloodrage ENTERS COMBAT - blocks Charge!
        newState.rage = min(100, newState.rage + 10)

    elseif action.name == "BattleShout" then
        newState.hasBattleShout = true
        -- Note: Battle Shout does NOT trigger combat

    elseif action.name == "Rend" then
        newState.inCombat = true
        -- Update specific enemy's Rend status
        if action.targetGUID then
            for _, enemy in ipairs(newState.enemies) do
                if enemy.guid == action.targetGUID then
                    enemy.hasRend = true
                    enemy.rendRemaining = 22000
                end
            end
        end
    end

    -- Advance time (except off-GCD)
    if not action.offGCD then
        advanceCooldowns(newState, 1500)
        decayRends(newState, 1500)
    end

    return newState
end
```

### 5. SimulateDecisionHorizon(state, firstAction, horizon)

Simulates 6 seconds (4 GCDs) forward starting with `firstAction`:

```lua
function SimulateDecisionHorizon(state, firstAction, horizon)
    local totalDamage = 0

    -- Execute first action
    totalDamage = GetActionDamage(state, firstAction)
    state = ApplyAction(state, firstAction)
    timeElapsed = 1500  -- 1 GCD

    -- Continue with greedy best action
    while timeElapsed < horizon do
        local actions = GetValidActions(state)
        local bestAction = findBestImmediate(actions)

        totalDamage = totalDamage + GetActionDamage(state, bestAction)
        state = ApplyAction(state, bestAction)
        timeElapsed = timeElapsed + 1500
    end

    return totalDamage
end
```

### 6. GetBestAction()

Main entry point - compares all actions:

```lua
function GetBestAction()
    local state = CaptureCurrentState()
    local actions = GetValidActions(state)
    local bestAction, bestDamage = nil, -1

    for _, action in ipairs(actions) do
        local damage = SimulateDecisionHorizon(state, action, 6000)
        if damage > bestDamage then
            bestDamage = damage
            bestAction = action
        end
    end

    return bestAction, bestDamage
end
```

## Special Mechanics

### Charge (Out of Combat Only)

Charge can only be used before entering combat:

```lua
-- In GetValidActions()
if hasSpell("Charge") and not state.inCombat then
    local inChargeRange = state.targetDistance >= 8 and state.targetDistance <= 25
    if inChargeRange and cooldowns.Charge <= 0 then
        table.insert(actions, {
            name = "Charge",
            stance = 1,  -- Battle Stance required
            rage = 0,
            needsDance = stance ~= 1,
            rageGain = ATW.Talents.ChargeRage or 9
        })
    end
end
```

**Combat triggers that block Charge:**
- Any offensive ability (Execute, BT, WW, Slam, Rend, etc.)
- Bloodrage (enters combat without attacking)
- Auto-attack (handled in Rotation.lua)

**NOT combat triggers:**
- Battle Shout (can be used before Charge)

### Slam Mechanics (2H Only)

Slam has a 1.5s cast time that **resets the swing timer**:

```lua
-- In GetValidActions() - only for 2H weapons
if hasSpell("Slam") and not state.hasOH then
    table.insert(actions, {name = "Slam", rage = 15})
end

-- In ApplyAction() - reset swing timer
elseif action.name == "Slam" then
    newState.mhTimer = newState.mhSpeed  -- Full reset
    newState.inCombat = true
```

This makes Slam a trade-off: good damage but delays your next auto-attack.

### Heroic Strike / Cleave - Pure Simulation

HS/Cleave use **no hardcoded thresholds** - the simulation decides optimal rage management:

```lua
-- Simple check: have rage and not already queued
if hasSpell("HeroicStrike") then
    if rage >= hsCost and not swingQueued then
        table.insert(actions, {name = "HeroicStrike", rage = hsCost, offGCD = true})
    end
end
```

The simulation naturally handles the "save rage for BT" decision:
- **Scenario A**: Use HS now → simulate 6s → total damage X
- **Scenario B**: Wait → use BT → simulate 6s → total damage Y
- Pick whichever yields more damage

This is the **Zebouski approach**: no arbitrary rules, just damage comparison.

## Multi-Target Mechanics

### Rend Spreading

The simulation generates **one Rend action per enemy** that needs it:

```lua
for _, enemy in ipairs(state.enemies) do
    if not enemy.hasRend and
       not enemy.bleedImmune and
       not enemy.inExecute and
       enemy.hpPercent >= 30 and
       enemy.ttd >= 9000 and
       enemy.distance <= 5 then

        table.insert(actions, {
            name = "Rend",
            targetGUID = enemy.guid,
            targetTTD = enemy.ttd,
        })
    end
end
```

The simulation automatically picks the **most valuable Rend target** based on total damage over horizon.

### AoE Damage

Whirlwind and Cleave use actual enemy counts:

```lua
-- Whirlwind: hits up to 4 targets in 8yd
targetsHit = min(4, state.enemyCountWW)
damage = weaponDmg * targetsHit

-- Cleave: hits up to 2 targets in 5yd
targetsHit = min(2, state.enemyCountMelee)
damage = (weaponDmg + bonus) * targetsHit
```

## Why Simulation > Priority Lists

### Priority List Problems

```
1. Execute > BT? What if BT is up and Execute target will die to DoTs?
2. Rend > WW? What if 4 targets = WW does 4× damage?
3. Battle Shout > Rend? Already handled by AP snapshot in Rend damage calc
4. Charge before Bloodrage? Priority list can't handle "must use first"
```

### Simulation Solves These

The simulation **naturally handles all edge cases** because it calculates actual damage:

- Execute target dying? Simulation shows low Execute damage → picks something else
- 4 targets? WW damage quadruples → beats Rend in comparison
- No Battle Shout? Rend damage is lower → BattleShout looks more valuable
- Charge opportunity? Simulating Bloodrage first sets inCombat=true → blocks Charge

## Debug Commands

```
/atw decision   - Show current decision comparison (all actions + damage)
/atw sim        - Show 30s combat simulation
/atw rend       - Show Rend decision info
/atw spells     - Show which abilities are detected as learned
```

### Example Output: /atw decision

```
=== Decision Simulator ===
Horizon: 6s

Action comparison:
  Bloodthirst: 4850 dmg << BEST
  Whirlwind: 3200 dmg
  Rend [GUID]: 2100 dmg
  HeroicStrike: 1800 dmg
  Wait: 1200 dmg

Current state:
  Rage: 65
  Stance: 3
  In Combat: YES
  Battle Shout: YES
  Rend (target): NO
  Target HP: 75.0%

Multi-target (3 enemies):
  Melee range (5yd): 2
  WW range (8yd): 3
  Rended: 1/3
  Needs Rend: 2
```

## Configuration

The only settings that affect simulation:

```lua
AutoTurtleWarrior_Config = {
    DanceRage = 10,     -- Min rage to consider stance dancing
}
```

Note: HS/Cleave have **no rage threshold** - the simulation determines optimal usage by comparing damage scenarios over the 6-second horizon.
