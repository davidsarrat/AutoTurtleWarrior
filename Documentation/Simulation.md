# Simulation Engine

Single-layer **Tactical Simulation** with manual cooldown toggles. No hardcoded priorities.

## Architecture Overview

```
+-------------------------------------------------------------+
|  TACTICAL LAYER (Sim/Engine.lua)                            |
|  -------------------------------------------------------------
|  Runs: Every 100-200ms (with caching)                       |
|  Purpose: Which ability to use NOW                          |
|                                                             |
|  Key Features:                                              |
|  - Stance switches as FIRST-CLASS ACTIONS                   |
|  - Real swing timers (mhTimer/ohTimer)                      |
|  - Configurable lookahead (default 30s / 20 GCDs)           |
|  - HS/Cleave valued by actual swing timing                  |
|  - Charge travel time simulation (28 yards/sec)             |
+-------------------------------------------------------------+
                          |
                          v
+-------------------------------------------------------------+
|  CACHE LAYER                                                |
|  -------------------------------------------------------------
|  Purpose: Avoid redundant calculations, reduce lag          |
|                                                             |
|  Invalidation triggers:                                     |
|  - Rage change >= 5                                         |
|  - Stance change                                            |
|  - Execute phase entered/exited                             |
|  - Overpower proc appeared/expired                          |
|  - Major cooldown became ready                              |
|  - Swing queue changed (HS/Cleave toggle)                   |
|  - MH swing imminent (< 300ms)  <-- NEW                     |
|  - Enemy count changed                                      |
+-------------------------------------------------------------+
                          |
                          v
+-------------------------------------------------------------+
|  TOGGLE SYSTEM (Manual Cooldown Control)                    |
|  -------------------------------------------------------------
|  Purpose: Player controls when cooldowns are available      |
|                                                             |
|  - /atw burst [on|off]  - Death Wish + Racials             |
|  - /atw reck [on|off]   - Recklessness                     |
|  - /atw sync [on|off]   - Racials wait for Death Wish      |
|  - /atw aoemode [on|off] - AoE vs single target            |
|  - /atw rendspread [on|off] - Rend spreading               |
+-------------------------------------------------------------+
```

## Key Design: Stance Switches as First-Class Actions

The simulator treats **stance switches as explicit actions** that compete with abilities:

```lua
-- In GetValidActions(), stance switches are generated like abilities:
if canSwitchStance and currentStance ~= 3 then
    table.insert(actions, {
        name = "BerserkerStance",
        targetStance = 3,
        isStanceSwitch = true,
        rage = 0,
        rageLoss = math.max(0, rage - tacticalMastery),
    })
end

if canSwitchStance and currentStance ~= 1 then
    table.insert(actions, {
        name = "BattleStance",
        targetStance = 1,
        isStanceSwitch = true,
        rage = 0,
        rageLoss = math.max(0, rage - tacticalMastery),
    })
end

-- DefensiveStance is NEVER recommended for DPS rotations
```

**Why This Matters:**
- Berserker Stance provides +3% crit on ALL attacks
- Battle Stance enables Overpower, Charge, Rend, Sweeping Strikes
- The simulator calculates which stance yields more DPS over the horizon
- No hardcoded "if wrong stance, switch" logic

**Execution Flow:**
```
Keypress 1: Simulator says "BerserkerStance" -> CastShapeshiftForm(3)
Keypress 2: Simulator says "Bloodthirst" -> CastSpellByName("Bloodthirst")
```

## Real Swing Timers for Auto-Attack Estimation

The simulator uses **actual swing timer values** from the game state:

```lua
-- In CaptureCurrentState() -> InitPlayer():
state.mhTimer = (ATW.GetMHSwingRemaining() or 0) * 1000  -- Time until next MH swing (ms)
state.ohTimer = (ATW.GetOHSwingRemaining() or 0) * 1000  -- Time until next OH swing (ms)
```

### EstimateAutoAttackDamage()

This function calculates auto-attack damage over the decision horizon using real timers:

```lua
function Engine.EstimateAutoAttackDamage(state, horizon)
    -- Use REAL swing timers, not estimates
    local mhTimer = state.mhTimer or mhSpeed
    local ohTimer = state.ohTimer or ohSpeed

    -- Calculate exact swing times within horizon
    local mhTime = mhTimer
    local firstMHSwing = true

    while mhTime <= horizon do
        local swingDamage = mhAvg * damageMod * critMultiplier

        -- FIRST MH swing gets HS/Cleave bonus if queued
        if firstMHSwing and state.swingQueued then
            if state.swingQueued == "hs" then
                swingDamage = swingDamage + hsBonus
            elseif state.swingQueued == "cleave" then
                swingDamage = swingDamage + cleaveBonus * min(2, enemyCount)
            end
            firstMHSwing = false
        end

        damage = damage + swingDamage
        mhTime = mhTime + mhSpeed
    end

    -- Same for off-hand (50% damage, no HS/Cleave)
    if state.hasOH then
        local ohTime = ohTimer
        while ohTime <= horizon do
            damage = damage + ohAvg * damageMod * critMultiplier * 0.5
            ohTime = ohTime + ohSpeed
        end
    end

    return damage
end
```

### Cache Invalidation on Imminent Swing

When a MH swing is about to land (< 300ms), the cache is invalidated to ensure optimal HS/Cleave decisions:

```lua
-- In CacheValid():
local mhTimer = newState.mhTimer or 0
if mhTimer > 0 and mhTimer < 300 then
    return false  -- Force recalculation
end
```

## Charge Travel Time Simulation

The simulator accounts for **Charge travel time** based on TrinityCore research:

### Constants (from TrinityCore)
```lua
Engine.CHARGE_SPEED = 28         -- Yards per second (minimum)
Engine.MELEE_RANGE = 5           -- Melee range in yards
Engine.CHARGE_MIN_RANGE = 8      -- Minimum Charge range
Engine.CHARGE_MAX_RANGE = 25     -- Maximum Charge range
```

### Travel Time Calculation
- At max range (25 yards): 25 / 28 = **~890ms** travel time
- At min range (8 yards): 8 / 28 = **~290ms** travel time

### State Fields
```lua
state.inMeleeRange = true    -- Are we in melee range (<=5 yards)?
state.timeToMelee = 0        -- Milliseconds until we reach melee
state.targetDistance = nil   -- Current distance to target
```

### Ability Requirements

**Melee Required (blocked during travel):**
- Execute, Bloodthirst, Mortal Strike, Whirlwind, Overpower
- Rend, Slam, Pummel

**Pre-Queueable (can queue during travel, fires on arrival):**
- Heroic Strike, Cleave
- These queue for "next swing" - queue them during Charge travel so they're ready the instant you arrive!

**Range-Agnostic (usable anytime):**
- Battle Shout, Bloodrage, Death Wish, Recklessness
- Berserker Rage, Blood Fury, Berserking
- Stance switches

### Simulation Flow After Charge
```lua
-- ApplyAction when Charge is used:
local distance = newState.targetDistance or 15
local travelTimeMs = (distance / Engine.CHARGE_SPEED) * 1000
newState.timeToMelee = travelTimeMs
newState.inMeleeRange = false

-- ApplyAction time advancement:
if newState.timeToMelee > 0 then
    newState.timeToMelee = max(0, newState.timeToMelee - gcd)
    if newState.timeToMelee <= 0 then
        newState.inMeleeRange = true  -- Arrived!
    end
end
```

### Impact on Auto-Attacks
```lua
-- EstimateAutoAttackDamage:
if not state.inMeleeRange then
    local timeToMelee = state.timeToMelee or 0
    if timeToMelee > 0 then
        -- Traveling after Charge - reduce horizon by travel time
        horizon = horizon - timeToMelee
        if horizon <= 0 then return 0 end
        -- Continue with remaining horizon after arrival
    else
        -- NOT in melee and NOT traveling = can't auto-attack!
        -- This happens at Charge range before Charging
        return 0
    end
end
```

**Critical Logic:**
- `inMeleeRange = false` AND `timeToMelee = 0` → At Charge range, haven't Charged → **0 auto-attacks**
- `inMeleeRange = false` AND `timeToMelee > 0` → Just Charged, traveling → **reduce horizon by travel time**
- `inMeleeRange = true` → In melee → **normal auto-attack calculation**

### Pre-Combat Detection (Charge Opener)

The simulator correctly identifies when we're at Charge range and need to Charge first:

```lua
-- In CaptureCurrentState():
if state.inCombat then
    -- In combat: assume melee (we're actively fighting)
    state.inMeleeRange = true
else
    -- Out of combat: check if we're in Charge range (8-25 yards)
    local inChargeRange = state.targetDistance and
        state.targetDistance >= Engine.CHARGE_MIN_RANGE and
        state.targetDistance <= Engine.CHARGE_MAX_RANGE

    if inChargeRange then
        -- NOT in melee - need to Charge to engage!
        -- Auto-attacks and melee abilities won't work
        state.inMeleeRange = false
    else
        -- Very close (<8yd) or no data - assume melee
        state.inMeleeRange = true
    end
end
```

**Why This Matters:**
- At Charge range with `inMeleeRange = false`:
  - Auto-attack damage = 0 (not in melee)
  - Melee abilities blocked by `canMelee()` check
  - Charge is the ONLY way to enable damage
- Charge gets massive value because it:
  - Generates rage (9-15 with talent)
  - Enables all auto-attacks
  - Enables all melee abilities
- Pre-combat buffs (Perception, etc.) have much lower value since they don't enable damage

## Decision Flow

### 1. CaptureCurrentState()

Captures complete combat state including **stance, swing timers, and multi-target info**:

```lua
state = {
    -- Resources
    rage = 50,
    stance = 3,                 -- 1=Battle, 2=Def, 3=Berserker

    -- Combat State (for Charge)
    inCombat = true,
    targetDistance = 15,

    -- Player Stats
    ap = 1500,
    crit = 25,
    mhDmgMin = 100,
    mhDmgMax = 200,
    mhSpeed = 2600,             -- Main hand speed (ms)
    hasOH = false,
    tacticalMastery = 25,       -- Rage retained on stance switch

    -- REAL Swing Timers (from game state)
    mhTimer = 1200,             -- Time until next MH swing (ms)
    ohTimer = 800,              -- Time until next OH swing (ms)

    -- Buffs
    hasBattleShout = true,
    hasDeathWish = false,
    hasRecklessness = false,
    hasSweepingStrikes = false,

    -- Combat Windows
    overpowerReady = true,
    shouldInterrupt = false,

    -- Swing Queue (critical for HS/Cleave)
    swingQueued = nil,          -- nil, "hs", "cleave"

    -- Current Target
    targetGUID = "0x...",
    targetHPPercent = 85,
    targetTTD = 25000,
    targetBleedImmune = false,
    rendOnTarget = false,

    -- Multi-Target
    enemies = { ... },
    enemyCount = 3,
    enemyCountMelee = 2,        -- 5yd (Rend/Cleave)
    enemyCountWW = 3,           -- 8yd (Whirlwind)

    -- Cooldowns (ms remaining)
    cooldowns = { ... },
}
```

### 2. GetValidActions(state)

Generates all valid actions including **stance switches**:

```lua
actions = {}

-- STANCE SWITCHES (first-class actions)
if stanceCdReady and stance ~= 3 then
    table.insert(actions, {
        name = "BerserkerStance",
        targetStance = 3,
        isStanceSwitch = true,
    })
end

if stanceCdReady and stance ~= 1 then
    table.insert(actions, {
        name = "BattleStance",
        targetStance = 1,
        isStanceSwitch = true,
    })
end

-- ABILITIES (only in correct stance)
-- Berserker Stance abilities
if stance == 3 then
    if hasSpell("Bloodthirst") and cd.Bloodthirst <= 0 then
        table.insert(actions, {name = "Bloodthirst", rage = 30})
    end
    if hasSpell("Whirlwind") and cd.Whirlwind <= 0 then
        table.insert(actions, {name = "Whirlwind", rage = 25})
    end
end

-- Battle Stance abilities
if stance == 1 then
    if overpowerReady and hasSpell("Overpower") then
        table.insert(actions, {name = "Overpower", rage = 5})
    end
    if hasSpell("Rend") and not rendOnTarget then
        table.insert(actions, {name = "Rend", rage = 10})
    end
end

-- Both stances
if stance == 1 or stance == 3 then
    if targetHP < 20 and hasSpell("Execute") then
        table.insert(actions, {name = "Execute", rage = execCost})
    end
end

-- HS/Cleave (off-GCD, any stance)
if hasSpell("HeroicStrike") and not swingQueued then
    table.insert(actions, {name = "HeroicStrike", rage = hsCost, offGCD = true})
end
```

**Key Points:**
- Stance switches compete directly with abilities
- Abilities are ONLY available in the correct stance
- No `needsDance` flags - the simulator handles stance naturally
- HS/Cleave has no threshold - simulation decides

### 3. GetActionDamage(state, action)

Calculates expected damage:

```lua
-- Stance switches: 0 direct damage, but enable abilities
if action.isStanceSwitch then
    return 0  -- Value comes from SimulateDecisionHorizon
end

-- Bloodthirst: 45% AP
if action.name == "Bloodthirst" then
    damage = ap * 0.45
end

-- Apply Berserker stance +3% crit
if state.stance == 3 then
    crit = crit + 3
end

-- Apply crit expectation
damage = damage * (1 + critChance * (critMult - 1))
```

### 4. ApplyAction(state, action)

Updates state after an action. **Now handles HS/Cleave queue correctly:**

```lua
function ApplyAction(state, action)
    local newState = DeepCopyState(state)

    -- STANCE SWITCH
    if action.isStanceSwitch then
        local tm = newState.tacticalMastery or 0
        local rageLoss = math.max(0, newState.rage - tm)
        newState.rage = newState.rage - rageLoss
        newState.stance = action.targetStance
        return newState
    end

    -- PAY RAGE COST
    newState.rage = newState.rage - action.rage

    -- ABILITY-SPECIFIC EFFECTS
    if action.name == "Execute" then
        newState.rage = 0  -- Consumes ALL rage
        newState.inCombat = true

    elseif action.name == "Bloodthirst" then
        newState.cooldowns.Bloodthirst = 6000
        newState.inCombat = true

    elseif action.name == "HeroicStrike" then
        newState.swingQueued = "hs"  -- CRITICAL: Set queue state

    elseif action.name == "Cleave" then
        newState.swingQueued = "cleave"  -- CRITICAL: Set queue state

    elseif action.name == "Slam" then
        newState.mhTimer = newState.mhSpeed  -- Reset swing timer
        newState.inCombat = true
    end

    return newState
end
```

### 5. SimulateDecisionHorizon(state, firstAction, horizon)

Simulates configurable horizon (default 30s / 20 GCDs) with auto-attack damage:

```lua
function SimulateDecisionHorizon(state, firstAction, horizon)
    local simState = DeepCopyState(state)
    local totalDamage = 0

    -- Execute first action
    totalDamage = totalDamage + GetActionDamage(simState, firstAction)
    simState = ApplyAction(simState, firstAction)

    -- CRITICAL: Include auto-attack damage AFTER applying action
    -- This ensures HS/Cleave queue is reflected in swingQueued
    totalDamage = totalDamage + EstimateAutoAttackDamage(simState, horizon)

    -- Continue with greedy best action
    local timeElapsed = firstAction.offGCD and 0 or 1500

    while timeElapsed < horizon do
        local actions = GetValidActions(simState)
        local bestAction = findBestImmediate(actions)

        totalDamage = totalDamage + GetActionDamage(simState, bestAction)
        simState = ApplyAction(simState, bestAction)
        timeElapsed = timeElapsed + 1500
    end

    return totalDamage
end
```

### 6. GetBestAction()

Main entry point with caching:

```lua
function GetBestAction()
    local state = CaptureCurrentState()

    -- INTERRUPT PRIORITY
    if state.shouldInterrupt then
        -- Return Pummel immediately
    end

    -- CHECK CACHE
    if CacheValid(state) then
        return GetCachedResult()
    end

    -- SIMULATE ALL ACTIONS
    local actions = GetValidActions(state)
    local bestAction, bestDamage = nil, -1

    local horizon = Engine.GetHorizon()  -- Default 30000ms
    for _, action in ipairs(actions) do
        local damage = SimulateDecisionHorizon(state, action, horizon)
        if damage > bestDamage then
            bestDamage = damage
            bestAction = action
        end
    end

    UpdateCache(state, {bestAction, bestDamage})
    return bestAction, bestDamage
end
```

## Heroic Strike / Cleave - Pure Simulation

HS/Cleave are properly valued because:

1. **ApplyAction sets swingQueued** when HS/Cleave is chosen
2. **EstimateAutoAttackDamage** adds bonus damage for queued abilities
3. **Real swing timers** determine exactly when the bonus applies
4. **Cache invalidates** when swing is imminent (< 300ms)

```lua
-- Example: Why HS might be chosen
-- Scenario A: Use HS now
--   - HS queued, next swing in 500ms = HS bonus applies
--   - Total damage over 9s includes HS bonus
-- Scenario B: Save rage for BT
--   - Next BT in 2s, no HS bonus on next swing
--   - Compare total damage

-- Simulation picks higher damage scenario automatically
```

## Stance Decision Example

```
Current: Battle Stance, 45 rage, Overpower ready

Actions simulated:
1. Overpower (5 rage) -> 1500 dmg + future abilities
2. BerserkerStance -> Switch, then BT/WW with +3% crit
3. Rend -> DoT damage over target TTD

Simulation results:
- Overpower path: 12,000 total damage
- BerserkerStance path: 14,500 total damage (3% crit over 9s = more)
- Rend path: 8,000 total damage

Winner: BerserkerStance (switch now, abilities with +3% crit are better)
```

## Cooldown Synergy

When `SyncCooldowns = true`, racials wait up to 10 seconds for Death Wish:

```lua
local function shouldWaitForDWSync()
    if not SyncCooldowns then return false end
    if not ATW.Has.DeathWish then return false end

    local dwCD = state.cooldowns.DeathWish or 999999
    if dwCD <= 0 then return false end  -- DW ready, no wait
    if dwCD <= 10000 then return true end  -- DW coming soon, wait!

    return false
end
```

Death Wish + racials are **multiplicative**:
```
Death Wish: +20% damage (1.2x multiplier)
Blood Fury: +120 AP (more damage per ability)
Berserking: +10% haste (more attacks)

Together = 1.2x * more AP * more attacks = huge burst
```

## Tactical Mastery and Stance Switches

Rage loss on stance switch respects Tactical Mastery talent:

```lua
-- In ApplyAction for stance switches:
local tm = newState.tacticalMastery or (ATW.Talents and ATW.Talents.TM) or 0
local rageLoss = math.max(0, newState.rage - tm)
newState.rage = newState.rage - rageLoss
newState.stance = action.targetStance
```

With 5/5 Tactical Mastery (25 rage retained):
- 45 rage -> switch -> 25 rage (lose 20)
- 20 rage -> switch -> 20 rage (lose 0)

## Debug Commands

```
/atw decision   - Show all actions with simulated damage
/atw cache      - Show cache hit rate and timing
/atw swing      - Show swing timer state
/atw sim        - Run extended simulation
/atw horizon    - Show current decision horizon
/atw horizon N  - Set decision horizon to N seconds (3-120)
```

### Example: /atw decision

```
=== Decision Simulator ===
Horizon: 30s (20 GCDs)

Action comparison:
  BerserkerStance: 14500 dmg << BEST (stance switch)
  Overpower: 12000 dmg
  Rend [GUID]: 8000 dmg
  HeroicStrike: 6500 dmg
  Wait: 4200 dmg

Current state:
  Rage: 45
  Stance: 1 (Battle)
  MH Timer: 1.2s
  Swing Queued: none
  Target HP: 75.0%
```

## Configuration

```lua
AutoTurtleWarrior_Config = {
    DanceRage = 10,         -- Min rage to consider stance dancing
    DecisionHorizon = 30000, -- Simulation lookahead (ms), default 30s

    -- Cooldown Toggles
    BurstEnabled = true,    -- Death Wish + Racials
    RecklessEnabled = false, -- Recklessness
    SyncCooldowns = true,   -- Racials wait for Death Wish

    -- AoE Toggles
    AoEEnabled = true,      -- Auto AoE based on enemy count
    RendSpread = true,      -- Spread Rend to multiple targets
}
```

## Why Simulation > Priority Lists

### Priority List Problems
```
1. "Switch to Berserker for BT" - What if Overpower is up?
2. "HS if rage > 50" - What if BT comes off CD in 0.5s?
3. "Execute > all" - What if target dies to DoT?
```

### Simulation Solves These

The simulation **compares actual damage** over the decision horizon (default 30s):
- Stance switch now vs use Overpower? Calculate both, pick higher
- HS now vs save for BT? Simulate both scenarios with real swing timers
- Execute vs WW on 4 targets? WW might do 4x damage

**No arbitrary rules. Just damage comparison.**
