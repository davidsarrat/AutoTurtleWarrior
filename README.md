# AutoTurtleWarrior

A fully automated **simulation-based** Warrior DPS rotation addon for TurtleWoW.

> **Note**: This addon was built primarily as an experiment in simulation-driven decision making ("for science"). It implements a full combat simulator with rage modeling, swing timers, and multi-target tracking. While fully functional for actual gameplay, the main goal was exploring whether a simulation approach could outperform traditional priority lists.

Unlike traditional priority-based addons, this addon simulates multiple actions forward in time and picks the one that yields the highest total damage over a configurable tactical horizon.

## Acknowledgements

Thanks to [Zebouski](https://github.com/Zebouski) for [WarriorSim-TurtleWoW](https://github.com/Zebouski/WarriorSim-TurtleWoW), which served as an important inspiration and reference for this addon's simulation model and TurtleWoW Warrior mechanics.

## Requirements

This addon requires two additional addons to function:

### 1. SuperWoW (SuperAPI)

Provides GUID-based unit functions for precise targeting and distance calculations.

- **Download**: [SuperAPI on GitHub](https://github.com/balakethelock/SuperAPI)
- **Installation**: Extract to `Interface\AddOns\SuperAPI`

### 2. UnitXP_SP3

Provides extended unit information functions.

- **Download**: [UnitXP_SP3 on Codeberg](https://codeberg.org/konaka/UnitXP_SP3)
- **Installation**: Extract to `Interface\AddOns\UnitXP_SP3`

## Installation

1. Download and install both required addons (SuperAPI and UnitXP_SP3)
2. Extract this addon to `Interface\AddOns\AutoTurtleWarrior`
3. Restart the game or `/reload`

## Usage

```
/atw          - Execute rotation (bind to key for spam)
/atw help     - Show all commands
/atw status   - Check addon dependencies
```

This build intentionally creates no visual UI frames. Bind `/atw` directly for the rotation.

### Toggle Commands

```
/atw burst    - Toggle Death Wish + Racials
/atw reckless - Toggle Recklessness
/atw sync     - Sync racials with Death Wish
/atw aoemode  - Toggle AoE/single-target mode
/atw rendspread - Toggle multi-target Rend spreading
/atw pummel   - Toggle auto-interrupt
/atw brcombat - Toggle Bloodrage combat-only mode
```

### Debug Commands

```
/atw aoe      - Show AoE and Rend-spread analysis
/atw rend     - Show Rend decision and tracker state
```

### Simulation Settings

```
/atw horizon        - Show current tactical horizon
/atw horizon <sec>  - Set tactical horizon (3-120 seconds)
```

The tactical horizon defaults to 9 seconds. Longer horizons consider more future GCDs but may be less responsive to immediate changes.

## Features

- Simulation-based decision making (no hardcoded priorities)
- Configurable tactical horizon (9s default)
- Stance dancing with Tactical Mastery support
- Multi-target Rend tracking via GUID
- Time-to-Die (TTD) calculation via linear regression
- Auto-interrupt with Pummel
- Cooldown synergy optimization (Death Wish + Racials)
- 2H and Dual Wield weapon support
- Event-driven cache invalidation for instant response
- Trinket auto-press with shared internal CD tracking (24 trinkets)
- Conditional gear bonuses (Mark of the Champion etc. vs Undead/Demons)
- Auto consumables: healing potion / healthstone / Lifeblood at low HP
- Engineering items (Sapper Charge, Dense Dynamite) in burst/AoE windows
- Mighty Rage Potion sync with Death Wish bursts
- Berserker Rage anti-Fear/Sap auto-cast
- Intercept gap closer in Berserker stance
