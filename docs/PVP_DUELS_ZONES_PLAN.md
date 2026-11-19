# PvP missions: duel wins and the zone picker

Two additions to the PvP missions of `docs/PVP_MISSIONS_PLAN.md`: a mission kind that counts **duels won**, and a
**zone picker** in the mission form that offers the whole world, each continent and every zone, where a zone also
covers the cities inside it. Branch `feat/pvp-duels-zones` (from `develop`). Test runner: `busted` on a Lua 5.1
(LuaJIT) tree, plus `luacheck NrageAssistant tests` and `stylua --check .`.

Every rule of `docs/PVP_MISSIONS_PLAN.md` section 0.1 holds: client APIs only through `Core/Platform.lua` and guarded,
pure injected domain logic tested with fakes, hostile-input validation, every user string through `L()` with an
`esES` entry in the same change, coverage gate 80 %.

## Specs

- **S1** (user, verbatim): "Que se pueda poner como mision, ganar duelos".
- **S2** (user, verbatim): "que en el selector de zonas del creador de misiones, salga un selecctor con las zonas de
  los mapas, que ademas tenga la opcion todo el mundo, kalimdor, reinoes del este y luego cada sitio por separado, por
  ejemplo loch modan incluye todo, incluido ironforge".
  - Correction recorded with the plan: Ironforge sits inside **Dun Morogh**, not Loch Modan. The rule implemented is
    "a zone includes the cities inside it": Dun Morogh includes Ironforge, Elwynn Forest includes Stormwind City,
    Tirisfal Glades includes Undercity, Durotar includes Orgrimmar, Mulgore includes Thunder Bluff, Teldrassil
    includes Darnassus. Each city is also selectable on its own.

## 1. Zones (S2)

### 1.1 Data: `Core/Constants.lua`

Replace `PVP_MISSION_ZONES` with `PVP_MISSION_REGIONS`, a tree of the two continents and their zones (Classic
uiMapIds; still TO BE MEASURED on Forever, `API_NOTES.md` M1, keep that comment):

```lua
PVP_MISSION_REGIONS = {
  { mapId = 1414, nameKey = "Kalimdor", zones = {
    { mapId = 1411, nameKey = "Durotar", includes = { 1454 } },
    { mapId = 1454, nameKey = "Orgrimmar" },
    ...
  } },
  { mapId = 1415, nameKey = "Eastern Kingdoms", zones = { ... } },
}
```

Kalimdor (1414): Durotar 1411 (⊃ Orgrimmar 1454), Mulgore 1412 (⊃ Thunder Bluff 1456), The Barrens 1413,
Teldrassil 1438 (⊃ Darnassus 1457), Darkshore 1439, Ashenvale 1440, Thousand Needles 1441, Stonetalon Mountains 1442,
Desolace 1443, Feralas 1444, Dustwallow Marsh 1445, Tanaris 1446, Azshara 1447, Felwood 1448, Un'Goro Crater 1449,
Moonglade 1450, Silithus 1451, Winterspring 1452, Orgrimmar 1454, Thunder Bluff 1456, Darnassus 1457.

Eastern Kingdoms (1415): Alterac Mountains 1416, Arathi Highlands 1417, Badlands 1418, Blasted Lands 1419,
Tirisfal Glades 1420 (⊃ Undercity 1458), Silverpine Forest 1421, Western Plaguelands 1422, Eastern Plaguelands 1423,
Hillsbrad Foothills 1424, The Hinterlands 1425, Dun Morogh 1426 (⊃ Ironforge 1455), Searing Gorge 1427,
Burning Steppes 1428, Elwynn Forest 1429 (⊃ Stormwind City 1453), Deadwind Pass 1430, Duskwood 1431, Loch Modan 1432,
Redridge Mountains 1433, Stranglethorn Vale 1434, Swamp of Sorrows 1435, Westfall 1436, Wetlands 1437,
Stormwind City 1453, Ironforge 1455, Undercity 1458.

Every `nameKey` is an English `L()` key with an `esES` entry (official Spanish client names, e.g. "Reinos del Este",
"Dun Morogh", "Forjaz", "Ventormenta", "Bosque de Elwynn", "Los Baldíos", "Vega de Tuercespina").

### 1.2 Wire format: unchanged

`goal.zones` stays a list of at most `PVP_MISSION_ZONES_MAX` (5) uiMapIds. A continent id (1414, 1415) is a valid
entry. An empty list is "whole world" (already the meaning today). No protocol message changes.

### 1.3 Matching: `Domain/PvPMissionTracker.lua`

`inZones(zones, row)` matches when, for some selected id `S`:

1. `row.mapId == S`; or
2. `S` is a zone of the tree and `row.mapId` is in its `includes`; or
3. `S` is a continent of the tree and `row.mapId` is one of its zones or in the `includes` of one of them.

A row without `mapId`, or with a map id the tree does not know, matches only rule 1 (as today). Build the lookup
(`zoneOf[mapId]`, `regionOf[mapId]`) once from the constant, not per row. Expose `PvPMissionTracker.ZoneMatches(
selectedId, mapId)` for tests and the summary.

`PvPMissionTracker.ZoneName(mapId)` resolves continents and every zone of the tree. Update the other reader of the old
constant (`UI/Tabs/PvP.lua` around line 31) to the new tree; grep `PVP_MISSION_ZONES` must return nothing except
`PVP_MISSION_ZONES_MAX`.

### 1.4 Older clients

An older client treats 1414 as a literal map and never counts it, and does not apply `includes`. Make
`PvPSeasonModel.UsesNewGoalFeatures(goal)` return true when `goal.zones` holds a continent id or a zone that has
`includes`, so the existing "Members on an older addon version…" warning shows in the form.

### 1.5 Picker: `UI/Tabs/PvPAdmin.lua` `zonesField`

Replace the chip list with:

- A `Kit.Dropdown` (placeholder `L("Add a zone")`) whose items are, in order: `L("Whole world")`, `L("Kalimdor")`,
  `L("Eastern Kingdoms")`, a separator, a disabled header item `Kalimdor` followed by its zones sorted by localized
  name, a separator, a disabled header `Eastern Kingdoms` followed by its zones sorted by localized name. `Kit.Menu`
  supports `separator` and `disabled` and scrolls past 12 rows.
- Choosing "Whole world" clears `draft.zones`. Choosing any other entry adds it (no duplicates). When 5 are already
  selected, the choice is refused with `UI.Notify("warning", L("At most 5 zones."))`.
- The selected entries show below as active `Kit.Chip`s; toggling one off removes it. A selected id the tree does not
  know still shows (as its number) so it can be removed.
- When nothing is selected, a small label reads `L("Whole world")`.
- Keep the "Add current zone" button. Keep `draft.zones` as the same comma text so `ViewModel.PvPParseZones` and
  `PvPMissionFields` stay unchanged.
- The mission summary (`ViewModel.PvPMissionSummary`) already names zones through `zoneName`; continents now resolve.

## 2. Duel wins (S1)

### 2.1 Detection: `Core/Platform.lua` + `Core/Init.lua`

- Classic has no duel-winner event. The winner comes in `CHAT_MSG_SYSTEM` with the client globals
  `DUEL_WINNER_KNOCKOUT` ("%1$s has defeated %2$s in a duel") and `DUEL_WINNER_RETREAT` ("%2$s has fled from %1$s in a
  duel"); `%1$s` is the winner in both. The message also arrives for duels of nearby players.
- `Platform.ParseDuelResult(message)` → `winner, loser` or nil. Build the Lua patterns once from the globals (escape
  magic characters, map the positional `%n$s` to captures in the right order), guarded with `pcall`; nil when the
  globals are missing or the text does not match. Strip a realm suffix from both names.
- `Init.lua` wires `CHAT_MSG_SYSTEM` to `ns.pvpMissions:OnSystemMessage(message)` only while `ns.active`.
- Add measurement **M10** to `docs/API_NOTES.md`: confirm on Forever that both globals exist and the message fires for
  a knockout and a retreat.

### 2.2 Log: `Domain/PvPMissionService.lua`

`OnSystemMessage(message)`: parse; when `winner` is the own name (`platform.PlayerName()` or the existing helper),
append `{ kind = "duel", at = now, victim = loser, mapId = platform.GetPlayerMapId() }` to `char.pvpLog.events`
through the existing `Append` (same retention and cap). A loss or another player's duel logs nothing. No schema bump:
the log already holds rows with a `kind`.

### 2.3 Model: `Domain/PvPSeasonModel.lua`

- `GOAL_KINDS.duel_wins = true`.
- Options allowed for `duel_wins`: `count`, `zones`, `repeatKind`, `distinct = "none" | "name"` (refuse class/race
  values), `victimCapPerDay`, `window`, `maxCompletions`, `autoClaim`. Dropped for it: `place` (forced to `"any"`),
  `target`, `victimClasses`, `victimRaces`, `minGuildInGroup`, `bgs`.
- Evidence row: `{ at, victim, mapId?, duel = true }`. `validateEvidenceRow` accepts it (victim text within
  `PVP_FEED_VICTIM_MAX`, `duel` exactly `true`, no `place`, `bgWin`, `kos`, `class`, `race`, `guild`).
- `UsesNewGoalFeatures` returns true for `duel_wins`.

### 2.4 Counting: `Domain/PvPMissionTracker.lua`

- A `duel_wins` goal counts only rows with `kind == "duel"`, filtered by zones, window, season, period, distinct names
  and caps like a kill goal.
- **Kill goals must ignore duel rows** (today a kill is any row with a `victim` that is not a battleground: add the
  `kind ~= "duel"` check).
- The global per-victim daily cap (`PVP_VICTIM_DAILY_CAP`) and `victimCapPerDay` count duels and kills separately: a
  duel against X never uses up a kill of X.
- `evidenceRow` emits the duel shape of 2.3; the approver side re-reads it with the same tracker.
- Progress bar label `"Duels won"`.

### 2.5 Protocol

`PROTOCOL_MINOR` 16 → 17 in `Core/Constants.lua`; add "minor 17 added the `duel_wins` mission kind and the duel
evidence row" to the minor list in `docs/PROTOCOL.md`, and document the evidence row next to the others. An older
client refuses the unknown kind (no partial counting).

### 2.6 UI: `UI/ViewModelPvP.lua`, `UI/Tabs/PvPAdmin.lua`

- Kind label `L("Duels won")`, appended to `GOAL_ORDER`; the goal text `L("Counts duels won")`; summary like kills.
- The form for `duel_wins` shows count, zones, distinct names, per-opponent daily cap, window, max completions,
  auto-claim; it hides place, KOS target, class/race filters, guild-group and battlegrounds.
- A preset `L("Duelist: win 10 duels")` (`count = 10`, `repeatKind = "weekly"`, `victimCapPerDay = 3`).
- `docs/USER_GUIDE.md`: one paragraph on duel missions (opponents of either faction, guild members included; every
  claim still needs an officer's approval).

## 3. Tests (RED first)

- `tests/pvp_mission_tracker_spec.lua`: S2 rules 1–3 (Dun Morogh counts an Ironforge kill; Kalimdor counts a
  Durotar and an Orgrimmar kill and not a Westfall kill; Ironforge alone does not count a Dun Morogh kill; unknown
  map only exact); empty zones counts everywhere (existing behavior kept). Duel goal counts duel rows only; a kill
  goal ignores duel rows (regression); caps are separate for duels and kills; distinct names for duels.
- `tests/pvp_season_model_spec.lua`: `duel_wins` accepted with its options and drops the others; duel evidence row
  accepted and malformed ones refused; `UsesNewGoalFeatures` true for `duel_wins`, a continent and a zone with
  includes, false for a plain zone.
- `tests/pvp_mission_service_spec.lua`: own knockout and own retreat win log a duel row with the map id; a loss and
  a stranger's duel log nothing; missing globals log nothing.
- Platform parsing: a spec for `ParseDuelResult` with English globals stubbed, both message shapes, a realm suffix.
- `tests/view_model_pvp_spec.lua`: duel kind label/summary, preset, zone items order of the picker (if built in the
  view model; put the item list builder there so it is testable: `ViewModel.PvPZonePickerItems()`).

## Tasks

| ID | Specs | Route | Owner | Status |
|---|---|---|---|---|
| T1 | S2: 1.1–1.4 + tests | delegated (parallel unit, worktree) | Haiku | pending |
| T2 | S1: 2.1–2.6 + tests | delegated (parallel unit, worktree) | Sonnet | pending |
| T3 | S2: 1.5 picker + `PvPZonePickerItems` + tests | delegated after T1 | Haiku | pending |
| T4 | merge, full suite, luacheck, stylua | inline | parent | pending |

## Log

- L1 (2026-11-19, user, verbatim): "Quiero hacer que el apartado pvp tenga varias cosas: 1. Que se pueda poner como
  mision, ganar duelos 2. que en el selector de zonas del creador de misiones, salga un selecctor con las zonas de los
  mapas, que ademas tenga la opcion todo el mundo, kalimdor, reinoes del este y luego cada sitio por separado, por
  ejemplo loch modan incluye todo, incluido ironforge. Esto planificalo y mándalo implementar a subagentes haiku y
  sonnet"
- L2: Ironforge is in Dun Morogh; the "zone includes its cities" rule applies to the six capitals (see S2).
- L3: Zones keep the wire format (list of ≤5 map ids, continents allowed); duels need protocol minor 17.
