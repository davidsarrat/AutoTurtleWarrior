# Simulation Engine

Single-layer **Tactical Simulation** with manual cooldown toggles. No hardcoded priorities.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│  TACTICAL LAYER (Sim/Engine.lua)                            │
│  ─────────────────────────────────────────────────────────  │
│  Runs: Every 100-200ms (with caching)                       │
│  Purpose: Which ability to use NOW                          │
│                                                             │
│  Decisions:                                                 │
│  - BT vs WW vs HS vs Cleave                                │
│  - Execute priority in execute phase                        │
│  - Overpower on dodge procs                                │
│  - Rend application on specific targets                    │
│  - Sweeping Strikes charge consumption                     │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  CACHE LAYER                                                │
│  ─────────────────────────────────────────────────────────  │
│  Purpose: Avoid redundant calculations, reduce lag          │
│                                                             │
│  - Skip recalculation if state unchanged                    │
│  - Minimum 100ms between full simulations                  │
│  - Invalidate on: rage change, stance change, CD ready     │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  TOGGLE SYSTEM (Manual Cooldown Control)                    │
│  ─────────────────────────────────────────────────────────  │
│  Purpose: Player controls when cooldowns are available      │
│                                                             │
│  - /atw burst [on|off]  - Death Wish + Racials             │
│  - /atw reck [on|off]   - Recklessness                     │
│  - /atw sync [on|off]   - Racials wait for Death Wish      │
│  - /atw aoemode [on|off] - AoE vs single target            │
│  - /atw rendspread [on|off] - Rend spreading               │
└─────────────────────────────────────────────────────────────┘
```

## Cooldown Synergy

When `SyncCooldowns = true`, racials wait up to 10 seconds for Death Wish to come off cooldown before being used. This is handled directly in `GetValidActions()`:

```lua
-- In GetValidActions()
local function shouldWaitForDWSync()
    if not SyncCooldowns then return false end
    if not ATW.Has.DeathWish then return false end

    local dwCD = state.cooldowns.DeathWish or 999999
    if dwCD <= 0 then return false end  -- DW ready, no wait
    if dwCD <= 10000 then return true end  -- DW coming soon, wait!

    return false
end

-- Applied to Blood Fury, Berserking, Perception
if ATW.Has.BloodFury and cooldowns.BloodFury <= 0 and not waitingForDW then
    table.insert(actions, {name = "BloodFury", ...})
end
```

Death Wish + racials are **multiplicative**, not additive:

```
Death Wish: +20% damage (1.2x multiplier)
Blood Fury: +120 AP (more damage per ability)
Berserking: +10% haste (more attacks)

Together = much more than separately!
```

## Tactical Layer

### File: `Sim/Engine.lua`

```
Engine.GetRecommendation()
    └── Engine.GetBestAction()
            ├── Check cache (skip if state unchanged)
            ├── Engine.CaptureCurrentState()     -- Snapshot game state
            ├── Engine.GetValidActions()         -- Only LEARNED spells + toggle checks
            │   └── CD sync: racials wait for DW if SyncCooldowns enabled
            └── Engine.SimulateDecisionHorizon() -- 9s lookahead (6 GCDs)
```

### Tactical Horizon

Simulates **9 seconds** (6 GCDs) ahead - enough for rotation decisions without lag:

```lua
Engine.TACTICAL_HORIZON = 9000  -- 9 seconds
-- Previously was 60000 (60s) which caused lag
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

    -- Racial Buffs (TurtleWoW)
    hasBloodFury = false,       -- Blood Fury active? (+AP)
    hasBerserking = false,      -- Berserking active? (+haste)
    hasPerception = false,      -- Perception active? (+2% crit)

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
    -- IMPORTANT: These are READ FROM GAME API via ATW.GetCooldownRemaining()
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
        -- Racial cooldowns
        BloodFury = 0,      -- 2 min CD
        Berserking = 0,     -- 3 min CD
        Perception = 0,     -- 3 min CD
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

Simulates **9 seconds** (6 GCDs) forward starting with `firstAction`:

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
        local damage = SimulateDecisionHorizon(state, action, 9000)
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

### Racial Abilities (TurtleWoW)

Three racial abilities affect DPS and are fully integrated into simulation:

| Racial | Race | Effect | CD | GCD |
|--------|------|--------|-----|-----|
| Blood Fury | Orc | +AP (level×2) for 15s | 2min | Off |
| Berserking | Troll | +10-15% haste for 10s | 3min | On |
| Perception | Human | +2% crit for 20s | 3min | Off |

**Buff Effects Integration:**

```lua
-- GetCritChance() includes Perception
if state.buffs.Perception then
    crit = crit + 2
end

-- GetEffectiveAP() includes Blood Fury
if state.buffs.BloodFury then
    ap = ap + (UnitLevel("player") * 2)  -- 120 at level 60
end

-- GetHasteMod() includes Berserking (stacks with Flurry)
if state.buffs.Berserking then
    haste = haste * 1.125  -- Average of 10-15%
end
```

**Action Generation:**

```lua
-- Blood Fury (Orc): off-GCD, any stance
if ATW.Racials.HasBloodFury then
    if cooldowns.BloodFury <= 0 and not state.hasBloodFury then
        table.insert(actions, {name = "BloodFury", offGCD = true})
    end
end

-- Berserking (Troll): on-GCD, costs 5 rage
if ATW.Racials.HasBerserking then
    if cooldowns.Berserking <= 0 and not state.hasBerserking and rage >= 5 then
        table.insert(actions, {name = "Berserking", rage = 5})
    end
end

-- Perception (Human): off-GCD, any stance
if ATW.Racials.HasPerception then
    if cooldowns.Perception <= 0 and not state.hasPerception then
        table.insert(actions, {name = "Perception", offGCD = true})
    end
end
```

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
- **Scenario A**: Use HS now → simulate 9s → total damage X
- **Scenario B**: Wait → use BT → simulate 9s → total damage Y
- Pick whichever yields more damage

This is the **Zebouski approach**: no arbitrary rules, just damage comparison.

## Cooldown Toggle System

Cooldowns are controlled by toggles (see `Documentation/Toggles.md` for full details):

```lua
-- Config toggles
BurstEnabled = true,     -- Death Wish + Racials
RecklessEnabled = false, -- Recklessness

-- Check function
function ATW.IsCooldownAllowed(cdName)
    if ATW.BURST_COOLDOWNS[cdName] then
        return AutoTurtleWarrior_Config.BurstEnabled == true
    end
    if ATW.RECKLESS_COOLDOWNS[cdName] then
        return AutoTurtleWarrior_Config.RecklessEnabled == true
    end
    return true
end
```

**Integration points:**
1. `Engine.GetValidActions()` - Excludes disabled CDs from action list
2. `shouldWaitForDWSync()` - Delays racials when DW coming soon (if SyncCooldowns enabled)

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
/atw decision   - Show tactical decision comparison (all actions + damage)
/atw cache      - Show cache statistics (hit rate, update frequency)
/atw aoe        - Show AoE strategy analysis (Rend vs Cleave)
/atw sim        - Simulate next 5 abilities
/atw rend       - Show Rend decision info
/atw spells     - Show which abilities are detected as learned
/atw cd         - Show cooldown status and toggle states
```

### Example Output: /atw decision

```
=== Decision Simulator ===
Horizon: 9s (6 GCDs)

Action comparison:
  Bloodthirst: 4850 dmg << BEST
  Whirlwind: 3200 dmg
  Rend [GUID]: 2100 dmg
  HeroicStrike: 1800 dmg
  Wait: 1200 dmg

Current state:
  Rage: 65
  Stance: 3
  Battle Shout: YES
  Rend (target): NO
  Target HP: 75.0%

Multi-target (3 enemies):
  Melee range (5yd): 2
  WW range (8yd): 3
  Rended: 1/3
  Needs Rend: 2
```

### Example Output: /atw cache

```
=== Engine Cache Stats ===
Cache hits: 1523
Cache misses: 89
Hit rate: 94.5%
Min interval: 100ms
Last update: 45ms ago
```

## Configuration

Settings that affect simulation behavior:

```lua
AutoTurtleWarrior_Config = {
    DanceRage = 10,         -- Min rage to consider stance dancing

    -- Cooldown Toggles (see Documentation/Toggles.md)
    BurstEnabled = true,    -- Death Wish + Racials
    RecklessEnabled = false, -- Recklessness
    SyncCooldowns = true,   -- Racials wait for Death Wish

    -- AoE Toggles
    AoEEnabled = true,      -- Auto AoE based on enemy count
    RendSpread = true,      -- Spread Rend to multiple targets
}
```

**Notes:**
- HS/Cleave have **no rage threshold** - the simulation determines optimal usage by comparing damage scenarios over the 9-second horizon.
- When `AoEEnabled = false`, Rend spreading is automatically disabled (single target funnel mode).
- When `SyncCooldowns = true`, racials wait up to 10s for Death Wish before being used.
