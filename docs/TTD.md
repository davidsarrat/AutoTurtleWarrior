# Time To Die (TTD) Algorithm

This document explains the linear regression algorithm used for predicting when enemies will die.

## Overview

TTD (Time To Die) is crucial for:
- Deciding whether to apply Rend (needs ~15s to be worth it)
- Execute phase prediction
- DoT duration optimization
- Multi-target priority decisions

## The Problem

Predicting when a mob will die is challenging because:
1. Damage is variable (crits, procs, etc.)
2. Healing can occur
3. Multiple sources of damage
4. HP values may be percentages or real numbers

## Algorithm: Linear Regression

We use **Linear Regression**, the industry-standard method used by:
- HeroLib (retail WoW)
- MaxDps
- Hekili
- WeakAuras TTD templates

### Why Linear Regression?

Simple approaches like "current HP / recent DPS" are unreliable because:
- Burst phases skew the average
- A single crit can drastically change estimates
- No smoothing of data

Linear regression fits a line through HP samples over time, providing:
- Noise reduction
- Trend-based prediction
- Stable estimates even with variable damage

## Mathematical Basis

### The Model

We model HP as a linear function of time:

```
HP(t) = a + b × t
```

Where:
- `a` = intercept (HP at time 0)
- `b` = slope (HP change per second, negative when taking damage)
- `t` = time

### Finding a and b

Using least squares regression:

```
Given n samples: (t₁, HP₁), (t₂, HP₂), ..., (tₙ, HPₙ)

Σx² = Σtᵢ²
Σx  = Σtᵢ
Σxy = Σ(tᵢ × HPᵢ)
Σy  = Σ HPᵢ

denominator = Σx² × n - (Σx)²

a = (-Σx × Σxy + Σx² × Σy) / denominator
b = (n × Σxy - Σx × Σy) / denominator
```

### Solving for TTD

Once we have `a` and `b`, we solve for when HP = 0:

```
0 = a + b × t
t = -a / b
```

TTD from current time:
```
TTD = t - currentTime
```

## Implementation

### File: `Player/TTD.lua`

```lua
ATW.TTD = {
    units = {},             -- [guid] = { samples = {}, lastSample = 0 }
    maxSamples = 30,        -- Keep last 30 samples (7.5s of data)
    sampleInterval = 0.25,  -- Sample every 0.25s (4/second)
    minSamples = 8,         -- Minimum 8 samples (2 seconds)
    maxUnits = 20,          -- Max units to track
    cleanupInterval = 5,    -- Cleanup every 5s
}
```

### Sampling HP

```lua
local function SampleUnit(guid, hp, maxHp)
    if not guid or hp <= 0 or maxHp <= 0 then return end

    local now = GetTime()
    local data = GetUnitData(guid)

    -- Rate limiting
    if now - data.lastSample < ATW.TTD.sampleInterval then
        return
    end

    -- Add sample
    table.insert(data.samples, {
        time = now,
        hp = hp,
        maxHp = maxHp,
    })

    -- Trim old samples
    while table.getn(data.samples) > ATW.TTD.maxSamples do
        table.remove(data.samples, 1)
    end

    data.lastSample = now
end
```

### Linear Regression Calculation

```lua
function ATW.GetUnitTTD(guid)
    if not guid then return 999 end

    local data = ATW.TTD.units[guid]
    if not data then return 999 end

    local samples = data.samples
    local n = table.getn(samples)

    -- Need minimum samples for reliable regression
    if n < ATW.TTD.minSamples then
        return 999
    end

    -- Get max HP for percentage conversion
    local lastSample = samples[n]
    local maxHP = lastSample.maxHp
    if maxHP <= 0 then return 999 end

    -- Calculate regression sums
    local Ex2, Ex, Exy, Ey = 0, 0, 0, 0

    for i = 1, n do
        local sample = samples[i]
        local x = sample.time
        local y = (sample.hp / maxHP) * 100  -- HP as percentage

        Ex2 = Ex2 + x * x
        Ex = Ex + x
        Exy = Exy + x * y
        Ey = Ey + y
    end

    -- Calculate denominator
    local denominator = Ex2 * n - Ex * Ex
    if math.abs(denominator) < 0.0001 then
        return 999  -- Avoid division by zero
    end

    local invariant = 1 / denominator

    -- Calculate coefficients
    local a = (-Ex * Exy * invariant) + (Ex2 * Ey * invariant)
    local b = (n * Exy * invariant) - (Ex * Ey * invariant)

    -- If slope >= 0, HP is not decreasing
    if b >= 0 then
        return 999
    end

    -- Calculate time at HP = 0
    local currentTime = GetTime()
    local timeAtZero = -a / b
    local ttd = timeAtZero - currentTime

    -- Sanity checks
    if ttd < 0 then
        return 1  -- Already should be dead
    end
    if ttd > 300 then
        return 300  -- Cap at 5 minutes
    end

    return ttd
end
```

## Data Sources

### Target HP Updates

```lua
-- Via UNIT_HEALTH event
function ATW.UpdateTargetTTD()
    if not UnitExists("target") or UnitIsDead("target") then
        return
    end

    local guid = nil
    local hp, maxHp = nil, nil

    if ATW.HasSuperWoW() then
        local _, g = UnitExists("target")
        guid = g

        -- Use GUID-based functions for consistency
        hp = UnitHealth(guid)
        maxHp = UnitHealthMax(guid)
    end

    -- Fallback for non-SuperWoW
    if not guid then
        guid = UnitName("target") .. ":" .. UnitLevel("target")
    end

    if not hp or not maxHp then
        hp = UnitHealth("target")
        maxHp = UnitHealthMax("target")

        -- Handle percentage-mode HP
        if maxHp == 100 then
            maxHp = 10000
            hp = hp * 100
        end
    end

    SampleUnit(guid, hp, maxHp)
end
```

### Nameplate HP Updates

```lua
-- Via OnUpdate (throttled to 0.25s)
function ATW.UpdateAllTTD()
    -- Update target
    ATW.UpdateTargetTTD()

    -- Update nameplates (requires SuperWoW)
    if ATW.HasSuperWoW() then
        local children = { WorldFrame:GetChildren() }
        for i, frame in ipairs(children) do
            if frame:IsVisible() and not frame:GetName() then
                local guid = frame:GetName(1)  -- SuperWoW GUID
                if guid then
                    local hp = UnitHealth(guid)
                    local maxHp = UnitHealthMax(guid)
                    if hp and maxHp and hp > 0 and maxHp > 0 then
                        SampleUnit(guid, hp, maxHp)
                    end
                end
            end
        end
    end
end
```

## Configuration Parameters

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `maxSamples` | 30 | 7.5s of data at 4/sec sampling |
| `sampleInterval` | 0.25s | Balance between accuracy and performance |
| `minSamples` | 8 | 2 seconds minimum for reliable prediction |
| `maxUnits` | 20 | Memory limit for tracked units |
| `cleanupInterval` | 5s | Remove stale tracking data |

### Why These Values?

- **30 samples / 7.5s window**: Long enough to smooth out burst damage, short enough to react to damage changes
- **8 minimum samples / 2s**: Minimum data for meaningful regression without wild predictions
- **0.25s interval**: 4 samples/second is sufficient for smooth tracking without performance impact

## Convenience Functions

```lua
-- Check if target will die within X seconds
function ATW.WillDieSoon(seconds)
    return ATW.GetTTD() <= seconds
end

-- Check if unit (by GUID) will die within X seconds
function ATW.UnitWillDieSoon(guid, seconds)
    return ATW.GetUnitTTD(guid) <= seconds
end

-- Estimate time to reach execute phase (20% HP)
function ATW.WillReachExecute(seconds)
    local currentPercent = ATW.GetTargetHPPercent()
    local ttd = ATW.GetTTD()

    if currentPercent < 20 then return true end
    if ttd >= 999 then return false end

    local percentToExecute = currentPercent - 20
    local timeToExecute = (percentToExecute / currentPercent) * ttd

    return timeToExecute <= seconds
end
```

## Debug Output

```
/atw ttd
```

Example output:
```
--- TTD Info ---
Target TTD: 12.3s | HP: 45.2% | Exec: NO
Tracking 5 units
  0x000012... : 12.3s (24 samples)
  0x000034... : 8.7s (18 samples)
  0x000056... : 25.1s (12 samples)
```

## Edge Cases

### HP Not Decreasing
If `b >= 0` (slope not negative), the unit is being healed or not taking damage. Return 999 (unknown).

### Already Dead
If calculated TTD is negative, the unit should already be dead according to the regression. Return 1 (imminent).

### Insufficient Data
If fewer than 8 samples, don't trust the prediction. Return 999 (unknown).

### Very Long TTD
Cap at 300 seconds (5 minutes) for sanity.

## Performance Considerations

- Sampling is throttled to 0.25s intervals
- Maximum 20 units tracked simultaneously
- Stale units (no update for 10s) are automatically cleaned up
- OnUpdate runs at frame rate but checks are time-gated
