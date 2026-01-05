# Detection Systems

This document covers the various detection systems used by the addon.

## SuperWoW Detection

SuperWoW is a TurtleWoW client extension that provides enhanced API functions.

### Checking Availability

```lua
function ATW.HasSuperWoW()
    return SetAutoloot ~= nil  -- SuperWoW adds this function
end
```

### Key SuperWoW Features Used

1. **GUID from UnitExists**
   ```lua
   local exists, guid = UnitExists("target")
   -- guid is a unique identifier like "0x0000000012345678"
   ```

2. **GUID-based Unit Functions**
   SuperWoW extends all unit functions to accept GUIDs:
   ```lua
   UnitHealth(guid)      -- HP of unit by GUID
   UnitHealthMax(guid)   -- Max HP by GUID
   UnitDebuff(guid, i)   -- Debuffs by GUID
   UnitName(guid)        -- Name by GUID
   ```

3. **Nameplate GUID Extraction**
   ```lua
   local guid = frame:GetName(1)  -- Returns GUID of nameplate unit
   ```

### File: `Core/Helpers.lua`

```lua
function ATW.HasSuperWoW()
    return SetAutoloot ~= nil
end
```

## UnitXP Detection

UnitXP_SP3 provides additional unit information functions.

### Checking Availability

```lua
function ATW.HasUnitXP()
    return UnitXP ~= nil
end
```

### File: `Core/Helpers.lua`

## Creature Type Detection

Used to determine bleed immunity based on creature type.

### Bleed-Immune Types

| Creature Type | Bleed Immune | Reason |
|---------------|--------------|--------|
| Mechanical    | Yes | No blood |
| Elemental     | Yes | No physical form |
| Undead        | Partial | Some can bleed |
| Others        | No | Normal creatures |

### Implementation

```lua
-- Detection/CreatureType.lua

-- Cache for creature types (persists during session)
ATW.CreatureTypeCache = {}

function ATW.IsBleedImmune(unit)
    local creatureType = UnitCreatureType(unit)

    if creatureType == "Mechanical" then
        return true, "Mechanical"
    elseif creatureType == "Elemental" then
        return true, "Elemental"
    end

    return false, creatureType
end

-- GUID-based version for nameplates
function ATW.IsBleedImmuneGUID(guid)
    -- Check cache first
    if ATW.CreatureTypeCache[guid] then
        local cached = ATW.CreatureTypeCache[guid]
        return cached.immune, cached.creatureType
    end

    -- Try to get type via SuperWoW
    if ATW.HasSuperWoW() then
        local ok, ctype = pcall(function()
            return UnitCreatureType(guid)
        end)
        if ok and ctype then
            local immune = (ctype == "Mechanical" or ctype == "Elemental")
            ATW.CreatureTypeCache[guid] = {
                immune = immune,
                creatureType = ctype
            }
            return immune, ctype
        end
    end

    return false, "Unknown"
end
```

### Learning from Target

When targeting a unit, we learn its creature type for future reference:

```lua
function ATW.LearnTargetCreatureType()
    if not UnitExists("target") then return end

    local _, guid = UnitExists("target")
    if not guid then return end

    local creatureType = UnitCreatureType("target")
    if creatureType then
        local immune = (creatureType == "Mechanical" or
                       creatureType == "Elemental")
        ATW.CreatureTypeCache[guid] = {
            immune = immune,
            creatureType = creatureType
        }
    end
end
```

## Buff/Debuff Detection

### Standard Detection (Unit ID)

```lua
function ATW.Buff(unit, texture)
    local i = 1
    while UnitBuff(unit, i) do
        if strfind(UnitBuff(unit, i), texture) then
            return true
        end
        i = i + 1
    end
    return false
end

function ATW.Debuff(unit, texture)
    local i = 1
    while UnitDebuff(unit, i) do
        if strfind(UnitDebuff(unit, i), texture) then
            return true
        end
        i = i + 1
    end
    return false
end
```

### GUID-Based Detection (SuperWoW)

```lua
function ATW.DebuffOnGUID(guid, texture)
    if not guid or guid == "" then return false end

    -- Priority 1: Direct UnitDebuff with GUID (SuperWoW)
    if ATW.HasSuperWoW() then
        local ok, found = pcall(function()
            local i = 1
            while true do
                local debuffTexture = UnitDebuff(guid, i)
                if not debuffTexture then break end
                if strfind(debuffTexture, texture) then
                    return true
                end
                i = i + 1
            end
            return false
        end)
        if ok and found then
            return true
        end
    end

    -- Priority 2: Check RendTracker for Rend specifically
    if texture == "Ability_Gouge" and ATW.RendTracker then
        return ATW.RendTracker.HasRend(guid)
    end

    return false
end
```

### Texture Names

Common ability textures used:

| Ability | Texture |
|---------|---------|
| Rend | `Ability_Gouge` |
| Battle Shout | `Ability_Warrior_BattleShout` |
| Sweeping Strikes | `Ability_Rogue_SliceDice` |

## HP Detection

HP detection in TurtleWoW/SuperWoW can be inconsistent. The API sometimes returns:
- Real HP values (e.g., 5000/10000)
- Percentage values (e.g., 50/100)
- Mixed values (HP as percentage, MaxHP as real)

### Robust HP Percentage Function

```lua
function ATW.GetHealthPercent(unit)
    unit = unit or "player"

    local hp = UnitHealth(unit)
    local max = UnitHealthMax(unit)

    if not hp or not max or max == 0 then
        return 100
    end

    -- Player always returns real values
    if unit == "player" then
        return (hp / max) * 100
    end

    -- Heuristics for non-player units:

    -- If max <= 100, assume vanilla percentage mode
    if max <= 100 then
        return hp  -- hp is already percentage
    end

    -- If hp looks like percentage but max is real (BROKEN case)
    if hp <= 100 and max > 1000 then
        return hp  -- Return hp as percentage directly
    end

    -- Both are real values
    return (hp / max) * 100
end
```

### Execute Phase Detection

```lua
function ATW.InExecutePhase(unit)
    unit = unit or "target"
    if not UnitExists(unit) then return false end
    return ATW.GetHealthPercent(unit) < 20
end
```

## Distance Detection

Range checking for abilities and enemy counting.

### File: `Detection/Distance.lua`

```lua
function ATW.GetDistance(unitOrGUID)
    if not ATW.HasSuperWoW() then
        return nil
    end

    -- SuperWoW provides UnitXYZ for position
    local ok, dist = pcall(function()
        local px, py, pz = UnitXYZ("player")
        local tx, ty, tz = UnitXYZ(unitOrGUID)

        if px and tx then
            local dx = px - tx
            local dy = py - ty
            local dz = pz - tz
            return math.sqrt(dx*dx + dy*dy + dz*dz)
        end
        return nil
    end)

    return ok and dist or nil
end
```

### Range Constants

| Range | Use |
|-------|-----|
| 5 yards | Melee range (Rend, HS) |
| 8 yards | Whirlwind range |
| 25 yards | Charge max range |

## Stance Detection

### Available Stances

```lua
ATW.StanceNames = {
    [1] = "Battle",
    [2] = "Defensive",
    [3] = "Berserker"
}
```

### Current Stance

```lua
function ATW.Stance()
    for i = 1, 3 do
        local _, _, active = GetShapeshiftFormInfo(i)
        if active then
            return i
        end
    end
    return 0
end
```

### Stance Requirements by Ability

| Ability | Stances |
|---------|---------|
| Rend | Battle (1), Defensive (2) |
| Execute | Battle (1), Berserker (3) |
| Whirlwind | Berserker (3) |
| Overpower | Battle (1) |
| Bloodthirst | Any |
