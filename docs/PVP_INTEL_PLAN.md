# PvP intel plan

Implementation plan for **Intel**: enemy player detection and guild intelligence inside Nrage Assistant. The goal,
stated by the addon owner on 2026-11-06, is that a guild member running Nrage Assistant can **uninstall Spy
completely**. So this plan covers everything Spy (Forever) does, then adds what only a guild addon can do: a shared
Kill On Sight list, live sightings, bounties tied to the PvP seasons, and session reports.

This document is written for the implementing agents and must be executable without the conversation that produced
it. **Decided** items were agreed with the owner. **Default** items are proposals to implement as written.

**Status:** planned 2026-11-06, branch `feat/pvp-intel`, target release `v1.1.0`.

**Inspiration, not source.** Spy, Spy (Forever) and True Spy are All Rights Reserved. Their code was not read and no
code, text, sound or image may be copied from them. Only the behaviour listed on their public pages is used.

---

## 0. Principles

### 0.1 Rules inherited from the addon

- Client APIs only through `NrageAssistant/Core/Platform.lua`, each guarded for a missing API, an error and a secret
  value. A value that cannot be read is **unknown**, never guessed.
- Domain logic is pure and injected (`New(deps)` with `now`, `platform`, `send`...). Frames stay thin. Tests use fakes.
  The coverage gate stays at 80 %.
- Every received byte is hostile: strict parsing, size caps, no `|`, `:` or control characters in names, unknown
  fields dropped. **The sender comes from the client, never from the payload.** Authority comes from the receiver's
  own guild roster.
- Nothing is sent during the encounter lockdown (`C_ChatInfo.InChatMessagingLockdown`). Persistent records use
  `Sync/OutboundQueue.lua`; live data is dropped.
- Everything runs only while `ns.active`.
- Every user-facing string goes through `L()` with an `esES` entry in the same change. Debug output stays English.
- SavedVariables change only through a new idempotent migration in `Core/Store.lua`.
- `COMBAT_LOG_EVENT_UNFILTERED` stays off. Do not register it for any part of this feature.
- A protected action must never be attempted in combat: no `Show`, `Hide`, `SetPoint` or `SetAttribute` on a secure
  frame while `InCombatLockdown()` is true.
- New `.lua` files go in `NrageAssistant/NrageAssistant.toc` in dependency order.

### 0.2 Detection limits to state honestly in the UI and docs

- Range is about the nameplate range. A stealthed enemy, or one that never shows a nameplate, is not detected.
- **Enemy nameplates must be on.** The addon reminds the player once per session and offers a button to turn them on
  outside combat.
- A sighting position is the **reporter's** position, because the client gives no enemy coordinates.
- The client may hide unit data, mostly in instanced PvP. Those units are skipped.

### 0.3 Decided and default choices

| Topic | Choice | Status |
|---|---|---|
| Scope | Full Spy (Forever) parity plus guild KOS, sightings, bounties and reports | decided |
| Delivery | One PR, one commit per work unit, release `v1.1.0` | decided |
| Sharing sightings | **On by default** with a one-time login notice, like `Share my position` since schema v14; one switch turns it off | default |
| Who edits the guild KOS | Any member adds; the author, gm or cogm edits; the author, gm or cogm removes | default |
| Personal KOS | Separate local list, never sent; a row can be promoted to the guild list | default |
| Ignore list | Personal and local | default |
| Win | The victim of an honour kill credited to the player. Killing blows need the combat log, which is off | default |
| Loss | The killer from the death recap, else the fallback in 3.6 | default |
| Name form | The KOS, ignore and player keys drop any `-Realm` suffix and use `Validate.NameKey` | default |

### 0.4 Left out on purpose

These do not stop anyone from uninstalling Spy. Do not build them.

- True Spy threat score, hunter arrow, danger radar, spoken alerts, WeakAuras events, revenge contracts.
- Enemy cooldown, interrupt, diminishing return and healer tracking: not possible on Forever without the combat log.
- Spy's refinement of a skull-level estimate from the abilities an enemy casts: needs an unverified spell level table.
  A skull enemy shows as own level + 10, marked as estimated.

---

## 1. Parity checklist

Each row must exist when the feature is finished. The reviewer checks this table line by line.

| Spy (Forever) behaviour | Where |
|---|---|
| Detect through nameplates, target, focus and mouseover | P1 `IntelDetector` |
| Rescan visible enemies every second | P1 |
| Read level, class, race, guild and faction | P1 `Platform.GetEnemyDetails` |
| Skull level as own level + 10 | P1 |
| Nameplate reminder, once per session | P1, P4 |
| Nearby list; entries fade at half the delay and leave at the delay (1 to 15 minutes, or never) | P1, P4 |
| Last hour, Ignore and Kill On Sight lists | P1, P4 |
| Sounds and warnings for new enemy, chosen races, KOS, guild of a KOS player, stealth casts | P3 |
| Warning in a movable window or the top error area | P3, P4 |
| Announcements to self, party, guild, raid and Local Defense, off by default | P3 |
| KOS by Shift-click, right-click menu, command and target frame button | P3, P4 |
| KOS reasons from six categories or custom text | P1 |
| KOS shared across the characters of the account | P1 (`db.global`) |
| Statistics: every enemy met, with sort, search and filters; lifetime honourable kills | P1, P4 |
| Wins and losses | P3 |
| Sharing detections; received ones in Nearby and on the maps; guild sharing off in instances | P2, P4 |
| Map icons for all zones, same zone (default) or same continent | P4 |
| World map switches to the zone of a detection (optional) | P4 |
| Level and class in minimap tooltips, optionally feeding Nearby | P4 |
| Minimap button shows nearby and KOS counts | P4 |
| Runs in battlegrounds, arenas and world PvP; sanctuaries optional; excluded zones; never in dungeons and raids | P1 |
| Commands: show, hide, clear, reset, config, stats, kos, ignore, test, minimap, debug | P3 |
| English and Spanish | every phase |
| Moving from Spy: import of KOS and Ignore | P3 |

---

## 2. Data

Schema: `SCHEMA_VERSION` 15 → **16**. Migration `[16]` creates the tables below when missing, sets
`settings.intelShareNotice = true` once and leaves everything else untouched. It must be idempotent.

```lua
db.global.intel = {
  players = {  -- at most INTEL_PLAYERS_MAX; the oldest lastSeen goes first; pruned at login after INTEL_RETENTION_DAYS
    [key] = { name, class, race, level, levelEstimated, guild, faction,
              firstSeen, lastSeen, seen, wins, losses, lastMap, lastX, lastY },
  },
  kos = { [key] = { name, category, reason, addedAt } },   -- personal, never sent
  ignore = { [key] = { name, addedAt } },                  -- personal, never sent
  zones = { [mapId] = count },                             -- contacts per map, at most INTEL_ZONES_MAX
}
db.global.guildKos = {
  [key] = { name, category, reason, rev, updatedAt, updatedBy, addedBy, addedAt },
}
```

The removal mark of a guild KOS entry is the tombstone `K:<key>` in `db.global.sync.tombstones`.

KOS categories (`INTEL_KOS_CATEGORIES`): `gank`, `camp`, `corpse`, `objective`, `insult`, `other`. The labels are
ours. `reason` is optional free text, at most `INTEL_REASON_MAX` bytes, cleaned as blacklist reasons are.

Settings live in `db.global.settings.intel`, read through `Settings.Intel(db)`, which fills defaults and repairs
damaged values:

| Key | Default | Meaning |
|---|---|---|
| `enabled` | true | Master switch of detection |
| `share` | true | Send sightings |
| `removeMinutes` | 5 | Nearby delay, 1 to 15, or 0 for never |
| `sound` | true | Master switch of alert sounds |
| `alertNew`, `alertKos`, `alertKosGuild`, `alertStealth` | false, true, true, true | Which alerts fire |
| `alertRaces` | `{}` | Race tokens that always alert |
| `alertGuildReports` | true | KOS reported by a guildmate in the same zone alerts |
| `warnTarget` | `"window"` | `"window"`, `"error"` or `"none"` |
| `announce` | `"none"` | `"none"`, `"self"`, `"party"`, `"raid"` or `"guild"` |
| `inSanctuary` | false | Detect in sanctuaries |
| `inBattleground`, `inArena` | true, true | Detect in instanced PvP |
| `excludedZones` | `{}` | Map ids where detection is off |
| `mapMode` | `"zone"` | `"all"`, `"zone"`, `"continent"` or `"none"` |
| `mapFollow` | false | An open world map switches to the zone of a detection |
| `minimapTooltip`, `minimapFeed` | true, false | Minimap tooltip details; add those players to Nearby |
| `window` | `{ shown = true, locked = false, rows = 8 }` | The compact window |
| `targetButton` | true | The KOS button by the target frame |

Constants, added to `Core/Constants.lua` with a comment each:

```lua
INTEL_PREFIX = "NRAGEINT", INTEL_MAX_BYTES = 96, INTEL_PLAYERS_MAX = 5000, INTEL_RETENTION_DAYS = 180,
INTEL_ZONES_MAX = 200, INTEL_KOS_MAX = 500, INTEL_IGNORE_MAX = 500, INTEL_REASON_MAX = 100, INTEL_NAME_MAX = 40,
INTEL_KOS_SNAPSHOT_MAX = 200, INTEL_RESCAN_SECONDS = 1, INTEL_NAMEPLATE_UNITS = 40, INTEL_LAST_HOUR_SECONDS = 3600,
INTEL_REALERT_SECONDS = 300, INTEL_SHARE_ENEMY_SECONDS = 30, INTEL_SHARE_TICK_SECONDS = 2, INTEL_SHARE_QUEUE_MAX = 5,
INTEL_DIRECTORY_TTL = 120, INTEL_DIRECTORY_MAX = 200, INTEL_INBOX_MAX_PER_WINDOW = 30, INTEL_REDRAW_SECONDS = 1,
INTEL_LOSS_FALLBACK_SECONDS = 10, INTEL_SKULL_LEVEL_BONUS = 10, INTEL_ANNOUNCE_SECONDS = 300,
INTEL_STEALTH_SPELLS = { [1784] = true, [1785] = true, [1786] = true, [1787] = true, [1856] = true, [1857] = true,
                         [5215] = true, [6783] = true, [9913] = true, [20580] = true },
INTEL_CLASSES = { ... }, INTEL_RACES = { ... }, -- fixed order, file tokens; the wire uses the index, 0 is unknown
```

The stealth spell ids are Classic values to confirm on Forever (M9).

---

## 3. Phases

Implement in order. One writer at a time, on `feat/pvp-intel`. Each phase is one or more work-unit commits, with its
tests, its `esES` strings and its `.toc` lines. Commits use Conventional Commits with **no** `Co-Authored-By` or AI
attribution.

### 3.1 P1: detection and records (Sonnet)

**Files:** `Core/Constants.lua`, `Core/Store.lua`, `Core/Platform.lua`, `Domain/Settings.lua`, new
`Domain/IntelModel.lua`, `Domain/IntelService.lua`, `Domain/IntelDetector.lua`, `Core/Init.lua`.

`Platform` readers, each guarded and each returning nil when unreadable:

- `GetEnemyDetails(unit)` → `{ name, class, race, level, skull, guild, faction }`. Build on `GetEnemyPlayerInfo` and
  keep that function unchanged for the missions. `level` comes from `UnitLevel`; `-1` gives `skull = true`. `guild`
  comes from `GetGuildInfo(unit)`. A unit of the player's own faction is rejected, which excludes duels.
- `IsEnemyTargetingPlayer(unit)`, `GetZonePvPType()`, `GetInstanceKind()` returning `"none"`, `"pvp"`, `"arena"`,
  `"party"` or `"raid"`.
- `EnemyNameplatesEnabled()` and `EnableEnemyNameplates()`, the second refused in combat.
- `GetContinentMapId(mapId)`, walking `C_Map.GetMapInfo` parents.

`IntelModel` (pure): `Key(name)`, `CleanName(name)`, `ValidateKos(fields)`, `CategoryValid(value)`,
`DetectionAllowed(context, settings)`, `EncodeSighting(fields)`, `DecodeSighting(text)`.

`DetectionAllowed`: false in `party` and `raid` instances always; false in `pvp` or `arena` unless the setting allows
it; false in a sanctuary unless `inSanctuary`; false in `excludedZones`; false when `enabled` is off.

`IntelService` (pure, injected store and clock) owns the lists:

- `OnSeen(details, where)`: updates the player record, the zone count and the in-memory Nearby entry. It returns
  `{ isNew, record }` for the alerts. `isNew` is true when the player was not in Nearby.
- `Nearby(now)`: active entries with `faded = age >= delay / 2`. An entry older than the delay is dropped; a delay of
  0 keeps it. KOS first, then the most recent.
- `LastHour(now)`, `Stats(filter, sort)`, `AddKos`, `RemoveKos`, `AddIgnore`, `RemoveIgnore`, `IsKos(name)` (returns
  `"personal"`, `"guild"` or nil), `IsIgnored`, `ClearNearby`, `Reset`, `Prune(now)`.
- Filters of `Stats`: text on name and guild, `kos`, `wins`, `losses`, `category`. Sort keys: last seen, name, level,
  guild, wins, losses.

`IntelDetector` (pure, injected reader): `OnUnit(unit)` and `Rescan()`, which goes through `nameplate1` to
`nameplateN` plus `target`, `focus` and `mouseover`. Skull level is own level + `INTEL_SKULL_LEVEL_BONUS`, with
`levelEstimated = true`. It also remembers which enemies target the player, with a time, for the loss fallback.

`Core/Init.lua`: a `StartIntel` that runs once, with its own frame. It registers `NAME_PLATE_UNIT_ADDED`,
`PLAYER_TARGET_CHANGED`, `PLAYER_FOCUS_CHANGED` and `UPDATE_MOUSEOVER_UNIT` one by one through `TryRegisterEvent`, and
a `C_Timer` ticker every `INTEL_RESCAN_SECONDS`. The ticker does nothing while `ns.active` is false or detection is
not allowed. Set `ns.intel`. The mission unit cache keeps its own listeners.

### 3.2 P2: guild KOS and live sightings (Sonnet)

**Files:** new `Domain/GuildKosService.lua`, `Sync/GuildKosSync.lua`, `Sync/IntelSync.lua`, `Domain/IntelPublisher.lua`,
`Domain/IntelDirectory.lua`; `Sync/Protocol.lua`, `Sync/Transfer.lua`, `Sync/Comm.lua`, `Domain/PermissionService.lua`.

**Guild KOS.** Copy the *pattern* of `Sync/BlacklistSync.lua`, `Domain/BlacklistService.lua` and their wiring.
`grep -n -i blacklist` over `Sync/` shows every touch point, including snapshots and `Transfer.ApplyItems`.

- Messages `KOS_UPSERT` and `KOS_DELETE` in the `NRAGE` envelope, with validators in `Sync/Protocol.lua`. Persistent,
  so they go through the outbound queue.
- Payload: `key`, `name`, `category`, `reason`, `rev`, `updatedAt`. The author is the sender. A snapshot item may carry
  `addedBy` and `addedAt`, with the same rules as the blacklist.
- Permissions: `kos_add = EVERYONE`, `kos_edit_any = GLOBAL_ONLY`, `kos_remove_any = GLOBAL_ONLY`. The author may edit
  and remove their own entry. The check runs on the receiver against the entry it holds.
- Conflicts and tombstones as in the blacklist, with marks `K:<key>`. `INTEL_KOS_MAX` is enforced.
- Snapshots shrink with the events, as the blacklist part does (`Comm.lua`, `maxBlacklist`), using
  `INTEL_KOS_SNAPSHOT_MAX`.
- Text export leaves the guild KOS out.

**Sightings.** A second strict text protocol like `Sync/PositionSync.lua`, with no envelope and no decoder.

```text
I1:<map>:<x>:<y>:<class>:<race>:<level>:<flags>:<name>
```

| Field | Rule |
|---|---|
| `map` | integer 1 to 9999 |
| `x`, `y` | integers 0 to 10000, the reporter's position |
| `class`, `race` | index into `INTEL_CLASSES` and `INTEL_RACES`, 0 is unknown |
| `level` | integer 0 to 100, 0 is unknown |
| `flags` | integer 0 to 3; bit 1 stealth, bit 2 estimated level |
| `name` | last field, 1 to `INTEL_NAME_MAX` bytes, no `|`, `:` or control character |

The whole text is at most `INTEL_MAX_BYTES`. Any other shape is `bad_format`.

`IntelPublisher` (pure):

- `Offer(details, where)` queues a sighting. An enemy is sent at most once per `INTEL_SHARE_ENEMY_SECONDS`, and again
  sooner only when it starts stealth. KOS enemies go first, and the queue holds `INTEL_SHARE_QUEUE_MAX`, dropping the
  oldest non-KOS item.
- `Tick()` sends at most one message per `INTEL_SHARE_TICK_SECONDS`. It sends nothing when `share` is off, during the
  lockdown, or for an ignored enemy.
- Channel: open world uses `GUILD`; a battleground uses the group channel (`Platform.GroupDistribution()`, `RAID` or
  `INSTANCE_CHAT`); arenas, dungeons and raids send nothing.

`IntelSync:Handle(text, channel, sender)` follows `PositionSync:Handle`, cheapest check first. Accepted channels are
`GUILD`, `RAID`, `PARTY` and `INSTANCE_CHAT`. It uses a dedicated `Inbox` with rate limit only, permission
`intel_share` (`EVERYONE`), and drops own messages. Register the prefix and the receiver in `Comm.Start`.

`IntelDirectory` holds received sightings in **memory only**: one entry per enemy, the newest wins,
`INTEL_DIRECTORY_TTL`, `INTEL_DIRECTORY_MAX`. It never writes player records. A received enemy on the player's own map
appears in Nearby with `source = sender`.

### 3.3 P3: alerts, results, commands and import (Sonnet)

**Files:** new `Domain/IntelAlerts.lua`, `Domain/IntelReport.lua`, `Domain/IntelImport.lua`,
`Commands/IntelCommands.lua`; `Core/Platform.lua`, `Core/Init.lua`, `Commands/Slash.lua`.

`IntelAlerts` (pure) receives a contact and decides `{ kind, sound, text, announce }`:

- Order: `kos`, `kosGuild`, `stealth`, `race`, `new`. Only the first match fires.
- An ignored enemy never alerts. The same enemy and kind alert again only after `INTEL_REALERT_SECONDS`.
- `kosGuild`: the enemy's guild equals the known guild of a KOS player.
- Delivery: `warnTarget` picks the movable warning (P4) or `UIErrorsFrame` through `Platform.ShowErrorText`. Each kind
  has its own `SOUNDKIT` choice, guarded.
- `alertGuildReports`: a guildmate's sighting of a KOS enemy on the same map alerts as `kos`, text naming the reporter.

Stealth: register `UNIT_SPELLCAST_SUCCEEDED`. Read the spell id through a guarded `Platform.ReadSpellEvent`, drop a
secret value, and act only on `nameplateN`, `target`, `focus` or `mouseover` units in `INTEL_STEALTH_SPELLS`.

Announcements: `Platform.SendChatLine(channel, text)`, guarded, nothing during the lockdown. Automatic ones go to
`self`, `party`, `raid` or `guild`, at most once per enemy per `INTEL_ANNOUNCE_SECONDS`, with party and raid skipped
when the player is not in one. **Local Defense only from a click**, because channel messages need a hardware event.

Wins: in `Core/Init.lua`, where `feed:OnHonorKill(victim, ...)` runs, also call `ns.intel:OnWin(victim)`.

Losses: on `PLAYER_DEAD`, `Platform.GetDeathKiller()` reads the death recap (`DeathRecap_GetEvents` and
`C_DeathRecap` variants, guarded; secret or missing gives nil). The killer must be a known enemy. The fallback is the
newest enemy that was targeting the player within `INTEL_LOSS_FALLBACK_SECONDS`, then the current enemy target. Store
the loss either way and count how many used the fallback for `debug`.

`IntelReport` (pure): `Session(service)` and `Season(service, season)` give contacts, wins, losses, new KOS, most seen
enemy, nemesis (most losses) and hottest zone. Session counters stay in memory.

`IntelCommands`, under `/nrage intel` (alias `/nrage spy`): `show`, `hide`, `clear`, `reset`, `config`, `stats`,
`kos <name> [category] [reason]`, `kos guild <name> ...`, `ignore <name>`, `test`, `minimap`, `import`, `debug`.
`reset` asks for confirmation. `test` fires a fake alert and sends nothing. `debug` is available in release builds and
prints: nameplates on or off, each event registered or refused, zone status, detections this session, sightings sent
and received, drop reasons, loss sources, and the saved record counts.

`IntelImport` (pure):

- `FromText(text)`: one name per line or comma separated, optional target list `kos` or `ignore`. Reachable from a
  text box in the UI.
- `FromSpy(globals)`: best effort read of the saved data of Spy when it is still loaded (`SpyPerCharDB.KOSData`,
  `SpyPerCharDB.IgnoreData`, `SpyDB.kosData`). Those names are **unverified**, so every table access is type-checked,
  and a missing or unknown shape imports nothing and says so. Only names are taken, each through `CleanName`. It never
  overwrites an entry that already exists.
- Both go to the personal lists and report `{ added, skipped }`.

### 3.4 P4: interface (Sonnet)

**Files:** new `UI/ViewModelIntel.lua`, `UI/Tabs/PvPIntel.lua`, `UI/IntelWindow.lua`, `UI/IntelTargetButton.lua`,
`Domain/IntelPins.lua`, `Domain/IntelMinimapTooltip.lua`; `UI/ViewModelPvP.lua`, `UI/Tabs/PvP.lua`, `UI/MapPins.lua`,
`UI/MinimapButton.lua`, `UI/Main.lua`.

**PvP tab.** A new sub-tab `Intel` (`ViewModel.PvPSubTabs`) with segmented views:
`Nearby · Last hour · KOS · Ignored · Statistics · Report`, plus a **Settings** card holding every setting of section 2.
Use the existing Kit controls; follow `UI/Tabs/PvP.lua` and its view model split. All decisions live in
`ViewModelIntel`, which is tested. The KOS view shows personal and guild badges, category, reason and author, with
add, edit, remove and promote actions that follow the permissions. It also holds the import box.

**Compact window** (`UI/IntelWindow.lua`), the replacement of the Spy window: movable, lockable, remembers place and
size in `settings.windows`, switches between Nearby, Last hour, Ignore and KOS, and has a clear button, a mute button
and a button that opens the tab. Rows show class colour, name, level, guild and age, KOS marks and a faded look.

Row clicks follow the Spy controls:

| Input | Action |
|---|---|
| Left click | Target the player |
| Shift + left click | Toggle personal KOS |
| Ctrl + left click | Toggle Ignore |
| Right click | Menu: remove, KOS, guild KOS with category, Ignore, announce (including Local Defense) |

Targeting needs a secure frame, so:

- Create a fixed set of `SecureActionButtonTemplate` overlays once, outside combat, one per row, always shown.
- Each has `type1 = "macro"`, `macrotext1 = "/targetexact <name>"`, empty modified clicks, and a `PostClick` handler
  for the other inputs. The visible rows are separate plain frames.
- Attributes, size and position change **only outside combat**.
- In combat the order is frozen through a pure function `IntelWindow.FreezeOrder(boundNames, rows)`: a bound name keeps
  its slot, a name that left stays greyed in it, and a new name takes a free slot, shown as not clickable until
  combat ends. A secure button must never target a name other than the one drawn over it.
- Resizing the row count is refused in combat.

**Warning.** A movable frame in the same file, used when `warnTarget = "window"`. It shows the alert for a few seconds
and has no secure parts.

**Target frame button** (`UI/IntelTargetButton.lua`): a plain button parented to `UIParent` and anchored to
`TargetFrame`, never parented to it. It shows when the target is an enemy player and toggles personal KOS. Add a
guarded `Menu.ModifyMenu` entry on enemy player menus when the client has it.

**Map pins.** `Domain/IntelPins.lua` builds the pins from own Nearby entries and `IntelDirectory`, filtered by
`mapMode`, like `PositionPins`. `layer` comes from the reporter's layer, so pins dim on another layer. `UI/MapPins.lua`
stays the only file touching HereBeDragons: add a second pool for enemy pins, with a red border and a KOS mark, and a
tooltip with name, level, reporter and age. `mapFollow` calls a guarded `Platform.ShowWorldMap(mapId)` only when the
world map is already open.

**Minimap.** `MinimapButton` tooltip adds nearby and KOS counts. `Domain/IntelMinimapTooltip.lua` parses tooltip lines
(pure, tested); a guarded `GameTooltip` hook, active only when the owner is `Minimap`, adds level and class of known
enemies. With `minimapFeed` it also adds them to Nearby. A secret or unreadable line does nothing.

**Notices.** The share notice (`settings.intelShareNotice`) prints once at login, like the position one. The nameplate
reminder shows once per session, in chat and as a banner in the Intel sub-tab with a button to enable them.

### 3.5 P5: bounties (Sonnet)

**Files:** `Domain/PvPSeasonModel.lua`, `Domain/PvPMissionTracker.lua`, `Domain/PvPMissionService.lua`,
`UI/ViewModelPvP.lua`, `UI/Tabs/PvPAdmin.lua`, `UI/Tabs/PvPIntel.lua`.

- `GOAL_KINDS` gains `kos`. `validateGoal` accepts an optional `target`, a name cleaned with `IntelModel.CleanName`, and
  keeps it only for this kind.
- A kill in the mission log gets `kos = true` when the victim is on the **guild** KOS at that moment. The flag is saved
  with the kill and travels in the claim evidence, so later KOS changes do not alter it.
- `Progress`: kind `kos` counts those kills and, when `target` is set, only that victim. Zones and place apply as for
  `kills`. The claim and approval flow does not change: an admin still approves every claim.
- The admin mission form adds the kind and an optional target. In the KOS view, admins get **Create bounty**, which
  opens the form prefilled.
- The Missions sub-tab shows the target. The Intel window marks a target with an open bounty.
- Older clients drop a mission of an unknown kind, so the release notes tell everyone to update.

### 3.6 P6: documents and locale audit (Haiku)

- Audit: every `L("...")` used by the new files has an `esES` entry. Use neutral Spanish.
- `docs/USER_GUIDE.md`: an **Intel** section, the sub-tab count, the commands and the note that Spy can be removed.
- `docs/PROTOCOL.md`: `KOS_UPSERT`, `KOS_DELETE` and the `NRAGEINT` prefix.
- `docs/PRIVACY.md`: what is stored and sent, including that a sighting reveals the reporter's position to the guild,
  and how to switch it off. Check the *Your map position* section against the `v14` default and correct it if stale.
- `docs/API_NOTES.md`: the measurements of section 5.
- `README.md` and `docs/CURSEFORGE_DESCRIPTION.md` (always English): the feature.
- `release-notes/v1.1.0.md`, following `release-notes/README.md`, player-facing. Include the recipe crafter fix of
  #167, which is not in a release yet. Add the `⚠️ Good to know` lines: saved data moves to a new format, and everyone
  should update for bounties.

---

## 4. Tests

Each new domain and sync module gets `tests/<module>_spec.lua`. At least:

| Area | Cases |
|---|---|
| Store | v15 to v16 keeps data, runs twice with the same result |
| Settings | defaults, damaged values repaired, range of `removeMinutes` |
| IntelModel | name cleaning, realm suffix, accented capitals, every `DetectionAllowed` branch, sighting round trip, every malformed sighting (extra field, range, `|`, too long) |
| IntelService | fade at half delay, removal, delay 0, KOS first, caps, retention, filters and sorts |
| IntelDetector | secret values skipped, same faction skipped, skull level, rescan of every unit kind |
| GuildKosSync | authority for add, edit and remove, tombstones, stale, limit, snapshot origin |
| IntelSync | channel, sender, rate, permission, own message |
| IntelPublisher | throttles, KOS priority, lockdown, instance kinds, switched off |
| IntelAlerts | order, ignore, re-alert time, each kind |
| Results | win from the feed, loss from recap, both fallbacks |
| IntelImport | text forms, damaged Spy tables, duplicates |
| ViewModelIntel, IntelPins | views, permissions, map modes, layers |
| FreezeOrder | bound names keep slots, leavers stay, newcomers take free slots |
| Missions | `kos` validation, progress with and without target, flag kept after the KOS changes |

Commands, from the repository root:

```bash
luacheck NrageAssistant tests
busted --coverage
luacov
tools/check_coverage.sh 80
stylua --check NrageAssistant tests
tools/package.sh ci-local
```

Use the Lua 5.1 tree named in the task. The `~/.luarocks` copies run on Lua 5.5 and fail.

---

## 5. In-game measurements

None of this can be proven in CI. Record each in `docs/API_NOTES.md` as *not measured yet*.

| Id | Question |
|---|---|
| M3, M4 | Already open: are enemy names, class and race readable, and do the unit events fire without the blocked action dialog? |
| M6 | Are `UnitLevel` and `GetGuildInfo` readable on enemy players? |
| M7 | Does `/targetexact` from a secure button work, outside and inside combat? |
| M8 | Do the death recap functions name the killer? |
| M9 | Does `UNIT_SPELLCAST_SUCCEEDED` fire for enemy nameplates with a readable spell id, and are the stealth ids right? |
| M10 | Does `NRAGEINT` work on `GUILD`, and on the group channel in a battleground? |
| M11 | Is minimap tooltip text readable? |
| M12 | Does `Menu.ModifyMenu` exist, and does it stay free of taint? |
| M13 | Does `FromSpy` find the saved data of Spy (Forever) when both addons are loaded? |

**Until M3, M4 and M6 pass in game, do not tell the guild that Spy can be removed.**

---

## 6. Definition of done

- Every row of section 1 exists and every test area of section 4 is covered.
- All commands of section 4 pass.
- No new `COMBAT_LOG_EVENT_UNFILTERED` use and no client call outside `Platform.lua`, except frame work in `UI/`.
- `v1.1.0` notes are in the PR. The tag is lightweight and pushed after the merge.
