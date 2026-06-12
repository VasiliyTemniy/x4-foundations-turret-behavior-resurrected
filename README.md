# Turret Behaviour Menu (Resurrected)

A right-click-menu mod for X4: Foundations that lets you set turret behaviour
in bulk — across fleets, per turret size, per turret type — and copy a ship's
turret configuration onto other ships in one click.

Original design and turret-walking logic by **Berserk Knight** (2019).
This is a port to current X4 on top of **kuertee UI Extensions**, with a few
additions on top.

---

## Game version compatibility

- 9.00 release - **supported**
- 9.00 betas and release candidates - **supported**
- 8.00 release - **partially supported**. Some minor features are disabled (submenus per turret type). Copy-paste config feature works, turret config per size works.

---

## Dependencies

- **kuertee UI Extensions and HUD** ([link](https://www.nexusmods.com/x4foundations/mods/552)) — provides the patched interact menu and
  its callback API. The whole UI integration runs through it.
- **SirNukes Mod Support APIs** ([link](https://www.nexusmods.com/x4foundations/mods/503)) — provides the Lua loader and the
  Interact Menu API used by the copy actions.

Both are hard dependencies. The mod will not load without them.

Please, **make sure to use the latest Kuertee's UI Extensions mod available for your game version**.
If it was not installed previously and the protected ui mode was "on", you would have to
disable the protected ui mode first. To do that, first you would have to disable all ui
mods, including Kuertee's UI Extensions, then reload the game, then turn off the protected
mode, reload the game again, turn on all the mods you like, reload the game again...
Then you can play! :)

---

## Mass turret-behaviour menu

Open the right-click menu in space, on the map, or directly on a player-owned
ship/station. The mod can add one of three sections, each shown only when relevant:

- **Turret Behaviour** — for the player's *occupied* ship.
- **Selected Turret Behaviour** — for the ships in your current map selection.
- **Station Turret Behaviour** — for the player-owned station you clicked.

The menu picks one scope at a time: selected ships first, then stations, then
the player's occupied ship. Extension Options can hide any of these three
sections; the player-ship section is off by default.

Each section has the same flat layout at root level (sizes the player doesn't
own are hidden):

```
Turret Behaviour
├─ All                       — every turret on the target
├─ XL Turrets                — all XL turrets
├─ XL Turrets (per type)     — list of XL types → click any to drill in
├─ L Turrets                 — all L turrets
├─ L Turrets (per type)
├─ M Turrets                 — all M turrets
├─ M Turrets (per type)
├─ S Turrets                 — all S turrets
└─ S Turrets (per type)
```

The "per type" entries use a nested navigation panel (chemodun's sub-group
API from kuertee). Click into one to reach a specific turret type and apply
behaviour to it alone.

Available actions inside every leaf section:

- **Armed / Disarmed**
- **Attack all enemies**
- **Attack only capital ships** / **Attack capital ships first**
- **Attack only fighters** / **Attack fighters first**
- **Defend**
- **Mining** *(ships only)*
- **Missile defence** / **Shoot missiles first**
- **Attack my current enemy** *(ships only)*
- **Towing** *(only on per-type entries for tug-class turrets)*

The station section additionally exposes **All Missile Turrets** /
**All Non-Missile Turrets** alongside the size buckets.

### Picking the right scope

The intent is: pick the smallest scope that does what you need.

- *Whole fleet, blanket order*: top-level **All** → done.
- *One size class across a fleet*: **L Turrets** / **M Turrets** → done.
- *Specific turret model, e.g. all "L Beam Mk1"*: open **L Turrets (per type)**
  → click **L Beam Mk1** → pick the mode.

This keeps the menu navigable even with very large fleet selections, where
the per-type list would otherwise scroll off the screen.

---

## Copy turret behaviour from one ship to others

When you right-click a **player-owned ship** while you have **at least one
other player ship selected** in the map, two extra entries appear in the
*Orders for ...* section:

- **Copy Turret Behaviour (by type)**
- **Copy Turret Behaviour (by slot)**

Both copy the *full* behaviour (mode + armed/disarmed) of the right-clicked
ship's turrets onto every other ship in the current selection. The
right-clicked ship itself is excluded. If the right-clicked ship has no
turrets, the operation is skipped silently.

The two modes differ in how they decide *which* config from the source maps
to *which* turret on each destination ship.

Both algorithms share the same fallback chain — they only differ in their
first tier. The shared tail is, in order:

1. **Same firing style at same size**: source's first turret of the same size
   whose firing-style icon (the small icon on each turret card in the
   equipment UI) matches the destination's. Two turrets share a firing style
   when the game UI renders the same icon for them, so e.g. Plasma↔Plasma,
   Bolt↔Bolt, Beam↔Beam, Tracking↔Tracking. This means a destination M Bolt
   Mk1 with no source M Bolt will still pick up a source M Pulse Mk1's config
   only if Pulse and Bolt share an icon (they don't), but will gladly pick
   up another M Bolt variant when available.
2. **Same size, any firing style**: source's first turret of the same size.
3. **Fallback**: source's very first turret, period.

### Algorithm — by type

The first tier:

- Take the destination turret's `(size, type)` — e.g. `(M, Plasma Mk1)`.
- If the source ship has a turret with exactly the same `(size, type)`, apply
  its mode + armed state.

Then fall through the shared chain above.

Use this mode when copying across **different ship hulls** — the source and
destination loadouts don't have to line up. Anything the source has equipped
of the same type gets matched first; anything else is matched by firing style
then by size.

### Algorithm — by slot

The first tier:

- Take the destination turret's **slot index** (for singular hull slots) or
  its `(path, group)` identifier (for grouped turrets on capital ships).
- If the source has a turret at the same identifier *and* the sizes line up,
  apply its config.

Then fall through the shared chain above.

Use this mode when copying across **same-hull ships** with potentially
*different per-slot configuration* — e.g. you've tuned a Behemoth so that
M1–M3 are *Defend* and M4–M6 are *Attack fighters first*, and you want
every other Behemoth in the fleet to mirror exactly that layout, position by
position.

The "by type" mode would collapse all those M Pulse Mk1 turrets to one
common behaviour. The "by slot" mode preserves the position-specific tuning.

### Choosing between the two

| Situation                                                    | Use      |
| ------------------------------------------------------------ | -------- |
| Different ship classes / loadouts in the selection           | by type  |
| Same hull, same equipped types, blanket per-type behaviour   | by type  |
| Same hull, per-position tuning that varies between slots     | by slot  |

When in doubt, **by type** is the safer default. **By slot** only beats it
when slot position carries meaning the source ship has set up deliberately.

### Notes and caveats

- Mode and armed state are both copied.
- Stations are not valid copy sources or destinations from these entries;
  use the station section of the right-click menu for station turrets.
- No undo. Pick carefully; or use the menu to reapply.
- Extension Options can hide the selected-ships, station, and player-ship menu
  sections. Debug logging is also available there and is off by default.

---

## Credits

- **Berserk Knight** — original *Turret Behaviour Menu* mod (2019 last upd 2022); menu
  structure and turret-walking logic.
- **morbideth** — original *RightClickAPI* / *G_Work_Around* which the 2019
  mod depended on. Both are no longer used in this port.
- **kuertee** and contributors — *UI Extensions and HUD*, on which this mod
  builds its interact-menu integration.
- **chemodun** — nested sub-subsection navigation in kuertee's interact menu,
  used here for the "per type" entries.
- **SirNuke** — *Mod Support APIs*, providing the Lua loader and Interact
  Menu API used by the copy actions.
- Port and copy-paste feature by **VasiliyTemniy**.

## Source

https://github.com/VasiliyTemniy/x4-foundations-turret-behavior-resurrected
