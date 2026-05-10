#!/usr/bin/env python3
"""
Extract trinket definitions from Zebouski/WarriorSim-TurtleWoW and write them
to Player/Trinkets.lua as the ATW.TrinketDB table.

Usage:
    python scripts/extract_trinkets.py

Sources:
    - js/data/gear.js          Vanilla trinket items (slot key "trinket1")
    - js/data/gear_turtle.js   TurtleWoW custom trinkets
    - js/classes/spell.js      Aura subclasses (on-use effect mechanics)

The Aura -> trinket mapping is hardcoded below because spell.js is JavaScript
code, not data. Each on-use trinket has a class extending Aura with stats /
duration / cooldown defined in code; we mirror those values here.
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

REPO_RAW = "https://raw.githubusercontent.com/Zebouski/WarriorSim-TurtleWoW/master"
GEAR_URLS = [
    f"{REPO_RAW}/js/data/gear.js",
    f"{REPO_RAW}/js/data/gear_turtle.js",
]
OUTPUT = Path(__file__).resolve().parents[1] / "Player" / "Trinkets.lua"

# Hardcoded on-use effect data extracted from js/classes/spell.js Aura
# subclasses. Real-game cooldowns differ from the sim's "firstuse" model;
# we use the in-game values so the addon respects actual CDs.
ONUSE_EFFECTS = {
    "Earthstrike": {
        "duration": 20, "cooldown": 120,
        "buff": {"ap": 280},
        "priority": 65,
    },
    "Diamond Flask": {
        "duration": 60, "cooldown": 360,
        "buff": {"str": 75},
        "priority": 60,
    },
    "Slayer's Crest": {
        "duration": 20, "cooldown": 120,
        "buff": {"ap": 260},
        "priority": 65,
    },
    "Jom Gabbar": {
        "duration": 20, "cooldown": 120,
        "buff": {"ap": 65},
        "stacking": {"tickInterval": 2, "maxStacks": 10},
        "priority": 65,
    },
    "Kiss of the Spider": {
        "duration": 15, "cooldown": 120,
        "mult_buff": {"haste": 20},
        "priority": 70,
    },
    "Badge of the Swarmguard": {
        "duration": 30, "cooldown": 180,
        "proc": {"ppm": 10, "armorPen": 200, "maxStacks": 6},
        "priority": 60,
    },
    "Zandalarian Hero Charm": {
        "duration": 20, "cooldown": 120,
        "buff": {"dmgmod": 40},
        "decay": {"perProc": 2, "minValue": 0},
        "priority": 70,
    },
}

# Items that ARE on-use trinkets but appear in gear data with annotations
# like "(Used last 20 secs)" or compound forms with proc info. Strip those
# suffixes before matching against ONUSE_EFFECTS.
NAME_SUFFIX_PATTERN = re.compile(
    r"\s*\((?:Used last \d+\s*secs?(?:\s*/\s*[^)]+)?|Assumed[^)]+|10 PPM|vs Undead)\)\s*$"
)

# Conditional bonuses (vs Undead, vs Demons) — not applied unconditionally.
CONDITIONAL_PATTERNS = [
    (re.compile(r"\(vs (Undead)\)", re.I), "Undead"),
    (re.compile(r"\(vs (Demons?)\)", re.I), "Demon"),
]

# Items where gear data lacks a "proc" field but the WarriorSim engine binds
# them to a proc Aura class. Hardcode the proc info so the addon knows about
# them. Values mirror spell.js classes.
SPECIAL_PROC_ITEMS = {
    "Vial of Potent Venoms": {
        # PotentVenoms class: 12s, 120 dmg per stack per tick (3s ticks),
        # max 2 stacks. 50% proc chance per swing.
        "type": "venom_dot",
        "chance": 50,
        "duration": 12,
        "tickInterval": 3,
        "tickDamage": 30,  # 120 / 4 ticks at 1 stack
        "maxStacks": 2,
    },
}

# Items to exclude entirely (resist trinkets — no DPS value).
EXCLUDED_NAMES = {
    "Blazing Emblem",
    "Loatheb's Reflection",
    "Gyrofreeze Ice Reflector",
    "Exalted AV Insignia Rank 6",
    "Heart of Noxxion",
    "Zandalarian Hero Medallion",  # different item from the on-use Charm
    "Hatereaver Cog",  # tank stats, no warrior DPS value
}


def fetch(url: str) -> str:
    print(f"  fetching {url}", file=sys.stderr)
    with urllib.request.urlopen(url) as r:
        return r.read().decode("utf-8")


def extract_section(js: str, section: str) -> list:
    """Pull a named array out of a JS object literal. Returns parsed list of dicts."""
    start = js.find(f'"{section}"')
    if start < 0:
        return []
    bracket = js.find("[", start)
    depth = 0
    for i in range(bracket, len(js)):
        c = js[i]
        if c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                raw = js[bracket : i + 1]
                # JS uses unquoted keys sometimes? gear.js uses quoted keys, OK.
                # Trailing commas need stripping for JSON.
                raw = re.sub(r",\s*([\]}])", r"\1", raw)
                return json.loads(raw)
    return []


def clean_name(name: str) -> str:
    return NAME_SUFFIX_PATTERN.sub("", name).strip()


def detect_conditional(original: str):
    for pat, label in CONDITIONAL_PATTERNS:
        if pat.search(original):
            return label
    return None


def lua_value(v, indent=2):
    pad = "\t" * indent
    if isinstance(v, dict):
        if not v:
            return "{}"
        items = []
        for k, val in v.items():
            key = f"[{json.dumps(k)}]" if not k.isidentifier() else k
            items.append(f"{pad}{key} = {lua_value(val, indent + 1)},")
        return "{\n" + "\n".join(items) + "\n" + ("\t" * (indent - 1)) + "}"
    if isinstance(v, list):
        if not v:
            return "{}"
        items = [f"{pad}{lua_value(x, indent + 1)}," for x in v]
        return "{\n" + "\n".join(items) + "\n" + ("\t" * (indent - 1)) + "}"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if v is None:
        return "nil"
    return json.dumps(v)


def build_entry(item: dict) -> dict:
    """Convert one gear.js trinket entry into a TrinketDB record."""
    raw_name = item["name"]
    name = clean_name(raw_name)
    record = {
        "itemId": item["id"],
        "name": name,
    }

    passive = {}
    range_separators = re.compile(r"[‐-―\-]")  # any dash
    for stat in ("ap", "str", "agi", "sta", "crit", "hit", "haste", "dodge",
                 "parry", "arp", "arpv"):
        if stat not in item:
            continue
        # arp/arpv → arpen; for on-use proc trinkets we skip arpv (it's the
        # max armor pen during proc, modelled separately in the on-use entry).
        if stat == "arpv" and item["name"].startswith("Badge of the Swarmguard"):
            continue
        key = "arpen" if stat in ("arp", "arpv") else stat
        val = item[stat]
        if isinstance(val, str) and range_separators.search(val):
            try:
                passive[key] = int(range_separators.split(val)[-1].strip())
            except ValueError:
                pass
        else:
            passive[key] = val

    cond = detect_conditional(raw_name)
    if cond:
        record["appliesAgainst"] = cond

    onuse = ONUSE_EFFECTS.get(name)
    proc_data = item.get("proc")

    if onuse:
        record["category"] = "onuse_with_passive" if passive else "onuse"
        record["onuse"] = {
            "duration": onuse["duration"],
            "cooldown": onuse["cooldown"],
        }
        if "buff" in onuse:
            record["onuse"]["buff"] = onuse["buff"]
        if "mult_buff" in onuse:
            record["onuse"]["multBuff"] = onuse["mult_buff"]
        if "stacking" in onuse:
            record["onuse"]["stacking"] = onuse["stacking"]
        if "proc" in onuse:
            record["onuse"]["proc"] = onuse["proc"]
        if "decay" in onuse:
            record["onuse"]["decay"] = onuse["decay"]
        record["priority"] = onuse["priority"]
        record["respectsSharedCD"] = True
    elif proc_data:
        record["category"] = "passive_with_proc" if passive else "proc"
        proc = {"chance": proc_data.get("chance", 0)}
        if proc_data.get("extra"):
            proc["type"] = "extra_attack"
            proc["extraAttacks"] = proc_data["extra"]
        elif proc_data.get("magic") or proc_data.get("dmg"):
            proc["type"] = "magic_damage"
            proc["damage"] = proc_data.get("dmg", 0)
        else:
            # Bare proc with no damage/extra-attack info — model as a buff
            # proc; the addon doesn't simulate the resulting buff in detail
            # but tracks that the trinket is proc-based.
            proc["type"] = "buff"
        record["proc"] = proc
    elif name in SPECIAL_PROC_ITEMS:
        record["category"] = "passive_with_proc" if passive else "proc"
        record["proc"] = dict(SPECIAL_PROC_ITEMS[name])
    elif passive:
        record["category"] = "passive_conditional" if cond else "passive"
    else:
        # No useful data for warrior DPS — skip
        return None

    if passive:
        record["passive"] = passive

    return record


def main():
    # Fetch and extract trinket entries from both gear sources
    items_by_id = {}
    for url in GEAR_URLS:
        js = fetch(url)
        for raw in extract_section(js, "trinket1"):
            name = clean_name(raw["name"])
            if name in EXCLUDED_NAMES:
                continue
            entry = build_entry(raw)
            if entry is None:
                continue
            # Later sources win (gear_turtle.js overrides gear.js)
            items_by_id[entry["itemId"]] = entry

    # Add Zandalarian Hero Charm explicitly (id 19950) — the on-use trinket
    # is missing from gear.js (only the passive Medallion id 19949 is listed).
    # The Charm exists in TurtleWoW and uses the Zandalarian aura class.
    if 19950 not in items_by_id:
        onuse = ONUSE_EFFECTS["Zandalarian Hero Charm"]
        items_by_id[19950] = {
            "itemId": 19950,
            "name": "Zandalarian Hero Charm",
            "category": "onuse",
            "onuse": {
                "duration": onuse["duration"],
                "cooldown": onuse["cooldown"],
                "buff": onuse["buff"],
                "decay": onuse["decay"],
            },
            "priority": onuse["priority"],
            "respectsSharedCD": True,
        }

    # Render Lua
    entries_sorted = sorted(items_by_id.values(),
                            key=lambda e: (e.get("category", ""), e["name"]))

    lines = [
        "--[[",
        "\tAuto Turtle Warrior - Player/Trinkets",
        "\tAuto-generated by scripts/extract_trinkets.py from Zebouski/WarriorSim-TurtleWoW.",
        "\tDO NOT edit by hand — re-run the script to regenerate.",
        "]]--",
        "",
        "ATW.TrinketDB = {",
    ]
    for entry in entries_sorted:
        name_key = entry.pop("name")
        lines.append(f'\t["{name_key}"] = ' + lua_value(entry, indent=2) + ",")
    lines.append("}")
    lines.append("")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"Wrote {len(entries_sorted)} trinkets to {OUTPUT}", file=sys.stderr)


if __name__ == "__main__":
    main()
