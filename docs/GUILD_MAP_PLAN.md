# Guild map plan

Implementation plan for showing guildmates on the minimap and the world map: each client that opts in shares its
map position with the guild, and every client draws a pin per guildmate. This document is written for the
implementing agent. Items marked **default** were not discussed explicitly and are open to review; items marked
**decided** were agreed with the guild officer who owns the addon.

**Status:** planned (2026-10-21), branch `feature/guild-map`.

- Inspiration: the GuildMap addon (Portalz, Devetik). **No code is copied from it** (decided 2026-10-21): its
  `GuildMap.lua` and `GuildMapUI.lua` are MPL 2.0 and `GuildMapMW.lua` is proprietary. Only the idea is reused.
- Rendering uses the HereBeDragons library (section 2), vendored from upstream, not from GuildMap's modified copy.
- Nothing here has been measured on the Forever client; section 9 lists what must be verified in game before release.

---

## 0. Principles

### 0.1 Rules inherited from the addon

- Client APIs only through `NrageAssistant/Core/Platform.lua`, each guarded for missing, error and secret value.
- Positions are **live only**, like `PVP_KILL` and `LAYER_STATE`: kept in memory, never saved, never queued during the
  encounter lockdown, never part of the `SYNC_DATA` snapshot.
- Everything runs only while `ns.active` (access guard passed).
- Every received byte is hostile: bounded size, strict parse, sender from the client event, never from the payload.
- Every user-facing string through `L()` with an `esES` entry in the same change; debug output stays English.
- Domain logic is pure and injected (`New(deps)`); frames are thin. Coverage gate stays at 80 %.

### 0.2 Privacy (default)

Sharing the position is **on by default**, so the guild map works without setup, and the player can turn it off. The settings are:

| Setting | Default | Effect |
|---|---|---|
| Share my position | on | publishes the own position to the guild |
| Show guildmates on the minimap | on | draws received positions on the minimap |
| Show guildmates on the world map | on | draws received positions on the world map |

Receiving and drawing do not require sharing (default). Switching sharing off sends one "forget me" message.
Nothing is sent from an instance or a battleground (no position is available there anyway). `docs/PRIVACY.md` gets
a row in the stored-data table and a short section.

---

## 1. What is shared

The message carries only the map and the coordinates. Name, class and level are **not** sent: the receiver already
has them from the local guild roster (`ns.guildRoster`) and from received profiles. The layer is not sent either: it
comes from `ns.layerDirectory`, which the layer feature already fills.

### 1.1 Transport: a separate prefix (decided 2026-10-21)

Positions do **not** go through the `NRAGE` prefix, AceComm, LibSerialize or LibDeflate:

- With 40 members sending every few seconds, the `(sender, id)` seen cache of the main inbox (`INBOX_SEEN_LIMIT =
  200`, one ring for all senders) would be evicted within seconds, weakening duplicate protection for real data.
- Four numbers do not need serialization or compression, and a strict text pattern is a smaller attack surface.

So: prefix `NRAGEPOS` (constant `POSITION_PREFIX`), registered after the access guard, sent on `GUILD` with
`ChatThrottleLib:SendAddonMessage("BULK", ...)` so it never delays real traffic (ChatThrottleLib is already vendored
with AceComm). Received only on `GUILD`; any other channel is ignored.

### 1.2 Wire format

```text
P1:<mapId>:<x>:<y>     a position; x and y are integers 0..10000 (zone coordinates times 10000)
P1:0                   "forget me"
```

- Whole message at most `POSITION_MAX_BYTES = 32` bytes, matched against `^P1:(%d+):(%d+):(%d+)$` or `^P1:0$`.
- `mapId` 1..`LAYER_MAP_MAX` (reuse the constant), `x`/`y` 0..10000. Anything else is dropped.
- A different leading version (`P2`, ...) is dropped silently; a future format adds a new tag.
- `PROTOCOL_MINOR` does not change (the `NRAGE` envelope is untouched); `docs/PROTOCOL.md` gets a section.

### 1.3 Receiving

In order, cheapest first:

1. channel is `GUILD`, sender is a non-empty string, normalized with `platform.NormalizeName`, not the own key;
2. a dedicated `ns.Inbox` instance, rate only (`AllowRate`, never `MarkSeen`), `POSITION_INBOX_MAX_PER_WINDOW = 30`
   per `INBOX_WINDOW_SECONDS`;
3. the sender must be known to the local guild roster (`roleOf(sender) ~= nil`), like `layer_share`; add a
   `position_share` action to the permission table with the same rule;
4. strict parse (1.2); then `PositionDirectory:Apply(sender, record)`.

The whole handler runs in `pcall` (secret values during an encounter mean "drop silently"), like `Comm.Start` does.

### 1.4 Sending

`PositionPublisher` (pure, modelled on `LayerPublisher`):

- `Tick()` is called every `POSITION_TICK_SECONDS = 5`. It sends when sharing is on, a position is known, the lockdown
  allows sending, and either the position moved more than `POSITION_MIN_MOVE = 20` units (0.2 % of the zone) since the
  last send, the map changed, or `POSITION_HEARTBEAT_SECONDS = 20` passed since the last send.
- No position (instance, loading screen, unknown map) after a published one: send "forget me" once.
- `Forget()` when sharing is switched off: one "forget me", not throttled (privacy action).
- Never more than one message per `POSITION_TICK_SECONDS`.

---

## 2. HereBeDragons

### 2.1 License (checked 2026-10-21)

Upstream is https://github.com/Nevcairiel/HereBeDragons. The repository has no `LICENSE` file; the license is
declared in `HereBeDragons.toc` as `## X-License: BSD`, author Nevcairiel (h.leppkes@gmail.com). BSD is permissive:
it may be redistributed embedded in a proprietary addon, provided the copyright notice and the license terms are
kept. It is embedded by many published addons (TomTom, HandyNotes, ...).

Because there is no license file upstream, add `NrageAssistant/Libs/HereBeDragons/LICENSE.txt` stating: library name,
upstream URL, tag and commit, author and e-mail, "Licensed under the BSD license as declared by the upstream TOC
(`## X-License: BSD`)". Quote only what upstream declares: do not invent a copyright line or pick a specific BSD
variant that upstream does not state.
Add it to the license check in `tests/embeds_spec.lua`.

### 2.2 What to vendor

- Tag `2.18-release` (commit `90a7b2d8c065010dfb866e2b6bd56f5bc930029b`), files `HereBeDragons-2.0.lua` and
  `HereBeDragons-Pins-2.0.lua` only (`HereBeDragons-Migrate.lua` is for 7.x data, not needed). Its TOC lists
  interface 16001 and the code has a `WoWForever` (`WOW_PROJECT_CAMELOT`) branch.
- Download with `gh api 'repos/Nevcairiel/HereBeDragons/contents/<file>?ref=2.18-release' --jq .content | base64 -d`.
- No patch and no renaming: the LibStub names `HereBeDragons-2.0` / `HereBeDragons-Pins-2.0` are meant to be shared,
  and LibStub keeps the highest minor when another addon ships its own copy.
- Before committing, scan both files for `1 / ` and `/ 0` style divisions that could hit the Forever
  `Division by zero` behaviour noted for LibSerialize in `Libs/README.md`; report any in `docs/API_NOTES.md`.
- `embeds.xml`: add both files after CallbackHandler (HBD depends on it). Add a row to `Libs/README.md`.

---

## 3. Domain

### 3.1 `Domain/PositionModel.lua`

Pure functions, no client access:

- `Settings(db)` → `{ share = boolean, minimap = boolean, worldmap = boolean }`, stored in
  `db.global.settings.position`, damaged values fall back to the defaults of 0.2.
- `Encode(position)` → wire string or nil; `EncodeForget()`; `Decode(text)` → `{ map, x, y }`, `{ forget = true }`,
  or nil plus a reason (`too_long`, `bad_format`, `out_of_range`).
- `Moved(a, b)` → true when the map differs or the distance in 0..10000 units is over `POSITION_MIN_MOVE`.
- `FromZone(x, y)` and `ToZone(ix, iy)` between the 0..1 client values and the 0..10000 integers (clamped, rounded).

### 3.2 `Domain/PositionPublisher.lua`

As 1.4. deps = `{ now, current = function() -> { map, x, y } or nil, enabled, canSend, send = function(text) -> ok }`.

### 3.3 `Domain/PositionDirectory.lua`

In-memory map `sender -> { map, x, y, at }`:

- `Apply(sender, decoded)`: a `forget` removes the sender; otherwise stores with `at = now()`. Bounded by
  `POSITION_DIRECTORY_MAX = 200` senders (refuse new ones when full, like the inbox).
- `Prune()`: removes entries older than `POSITION_TTL = 60` seconds. Returns true when something was removed.
- `List()`: the live entries.
- `onChange` callback after any change, used to redraw.

### 3.4 `Domain/PositionPins.lua` (view model)

Pure: given the directory list, the guild roster lookup, the profile lookup, the own layer, the layer directory, the
group membership predicate and the settings, returns the pins to draw:

```text
{ key, name, class, level, map, x, y, layer = n or nil, sameLayer = boolean or nil, age = seconds }
```

`x` and `y` here are 0..1 zone coordinates (converted with `PositionModel.ToZone`), which is what HereBeDragons takes.

- Members of the own party or raid are skipped: the client already shows them (default).
- A member who is no longer in the local guild roster is skipped.
- `sameLayer` is nil when either layer is unknown, so the UI draws it normally.

---

## 4. Platform

New guarded functions in `Core/Platform.lua` (each returns nil on missing API, error or secret value):

- `PlayerMapPosition()` → `{ map, x, y }` (0..1) from `C_Map.GetBestMapForUnit("player")` and
  `C_Map.GetPlayerMapPosition(map, "player"):GetXY()`; nil inside an instance (`IsInInstance()`) or when either
  call returns nil.
- `IsGroupMember(name)` → `UnitInParty(name) or UnitInRaid(name)`, false on error.
- `RegisterPrefix` already exists; reuse it for `POSITION_PREFIX`.

Add stubs for these in `tests/stubs/wow_api.lua` and list every one as unmeasured in `docs/API_NOTES.md`.

---

## 5. Sync

### 5.1 `Sync/PositionSync.lua`

`PositionSync.New(deps)` with deps `{ platform, inbox, roleOf, directory, now }` and
`PositionSync:Handle(text, channel, sender)` implementing 1.3; returns true or false plus the reason, like
`Comm:HandleMessage`, so it is testable without the client.

### 5.2 Start-up (in `Core/Init.lua`, next to `StartLayer`)

`StartPosition()` runs once, after `Comm.Start()` and the layer start, only while `ns.active`:

1. register `POSITION_PREFIX`;
2. a frame on `CHAT_MSG_ADDON` filtered by prefix, calling `PositionSync:Handle` inside `pcall` when `ns.active`;
3. `C_Timer.NewTicker(POSITION_TICK_SECONDS, ...)`: `publisher:Tick()`, `directory:Prune()`;
4. the send function: `ChatThrottleLib:SendAddonMessage("BULK", POSITION_PREFIX, text, "GUILD")`;
5. `ns.SetPositionShare(share)` like `ns.SetLayerShare`: on → `Tick()` at once, off → `Forget()`;
6. on `PLAYER_LEAVING_WORLD`, nothing is sent (the TTL clears the others' pins).

---

## 6. UI

### 6.1 `UI/MapPins.lua`

The only file that touches HereBeDragons. It receives `hbdPins` injected (default `LibStub("HereBeDragons-Pins-2.0",
true)`); if the library is missing it does nothing.

- A pool of pin frames for the minimap and one for the world map, reused, never more than `POSITION_DIRECTORY_MAX`.
- `Redraw(pins, settings)`: removes all icons with `RemoveAllMinimapIcons(ref)` / `RemoveAllWorldMapIcons(ref)` and
  adds one per pin with `AddMinimapIconMap(ref, frame, map, x, y, true, true)` and
  `AddWorldMapIconMap(ref, frame, map, x, y, HBD_PINS_WORLDMAP_SHOW_CONTINENT)`, only for the maps enabled in the
  settings. `ref` is the addon table.
- Pin: 12 px on the minimap, 14 px on the world map, the class icon from
  `Interface\GLUES\CHARACTERCREATE\UI-CHARACTERCREATE-CLASSES` with `CLASS_ICON_TCOORDS`, and a thin border in the
  class colour (`RAID_CLASS_COLORS`). Fallback when the class is unknown: a grey dot. Alpha 0.5 when `sameLayer ==
  false` (default).
- Tooltip on enter: name in class colour, "Level %d", "Layer %d" (green when `sameLayer`), "%d s ago". No click
  actions in this version.
- Redraws are coalesced: at most one per second, triggered by the directory `onChange`, the settings, the layer
  directory changes and `GROUP_ROSTER_UPDATE`.

### 6.2 Settings

In the settings section of `UI/Main.lua`, next to the minimap button switch, three checkboxes for the settings of
0.2, using the existing kit controls. "Share my position" calls `ns.SetPositionShare`. Every label through `L()` with
`esES` entries.

---

## 7. Constants

Add to `Core/Constants.lua`, with a comment block like the layer one:

```text
POSITION_PREFIX = "NRAGEPOS", POSITION_MAX_BYTES = 32, POSITION_TICK_SECONDS = 5, POSITION_HEARTBEAT_SECONDS = 20,
POSITION_MIN_MOVE = 20, POSITION_TTL = 60, POSITION_DIRECTORY_MAX = 200, POSITION_INBOX_MAX_PER_WINDOW = 30
```

Update `tests/constants_spec.lua` if it checks the table.

---

## 8. Phases

Each phase ends green on the three checks of the README (luacheck, busted with coverage >= 80 %, stylua --check).
The implementing agent does not commit; the owner reviews and commits (conventional commits, no AI attribution).

| Phase | Content | Specs |
|---|---|---|
| P1 | vendor HBD (section 2), constants, Platform functions and stubs | `embeds_spec`, `platform_spec` |
| P2 | `PositionModel`, `PositionPublisher`, `PositionDirectory`, `PositionPins` | one spec each |
| P3 | `PositionSync`, permission action, Init wiring | `position_sync_spec`, `permission_service_spec` |
| P4 | `MapPins`, settings checkboxes, locale | `map_pins_spec` with a fake `hbdPins`, `locale_spec` |
| P5 | docs: `PROTOCOL.md`, `PRIVACY.md`, `API_NOTES.md`, `USER_GUIDE.md`, `Libs/README.md` | — |

Spec cases that must exist: decode rejects too long, wrong tag, non-digits, out-of-range map and coordinates; a
forget removes the entry; TTL prune; directory refuses new senders when full; publisher sends on move, on heartbeat,
not when unchanged, not when sharing is off, not when locked, forget once when the position disappears; sync drops
other channels, own messages, unknown senders and rate-limited senders; pins skip group members and members not in the
roster; `MapPins` does nothing without the library and only draws on the enabled maps.

---

## 9. Must verify in game before release

- `C_Map.GetBestMapForUnit` and `C_Map.GetPlayerMapPosition` return values on Forever in the open world, and nil in
  instances.
- HereBeDragons 2.18 draws minimap pins correctly on Forever (rotation, zoom, indoors).
- `ChatThrottleLib` "BULK" traffic on `NRAGEPOS` with 20+ members does not delay `NRAGE` messages.
- `CLASS_ICON_TCOORDS` and the class icon texture exist on Forever.

Record the results in `docs/API_NOTES.md`.

---

## 10. Decisions log

- 2026-10-21: feature approved; no code from GuildMap; HereBeDragons vendored from upstream (BSD); separate prefix
  for positions.
