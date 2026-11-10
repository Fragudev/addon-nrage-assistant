# Announcements, modules and PvP tracking plan

Implementation plan for four pieces of work:

- **Part A, Modules:** each player turns addon modules (Professions, Raid, PvP, ...) on and off for themselves.
- **Part B, Announcements:** a read-only board in the Guild group, an editor in the Admin group, and an optional
  popup to every member when an announcement is published.
- **Part C, PvP mission tracking:** make mission progress reliable and give officers more options per mission.
- **Part D, Rank mapping:** an Admin section that maps guild ranks to addon roles, so renaming a guild rank does not
  change anyone's permissions in the addon.

This document is written for the implementing agents (Sonnet / Haiku) and must be executable without the conversation
that produced it. **Decided** items were agreed with the addon owner. **Default** items are proposals to implement as
written, open to review. **Open** items need an answer from the owner before their phase starts.

**Status:** plan, iterating. Nothing implemented.

## Quick path

1. **Part D (Rank mapping)** first: every permission check (including who may post announcements) goes through it,
   and it is the riskiest change (security, item 2). It gets its own PR and an independent review.
2. **Part A (Modules)**: local only, no protocol. Part B registers itself as a module, Part C reads the PvP flag.
3. **Part B (Announcements)** after D. It can start in parallel with A if B's module registration lands last.
4. **Part C (PvP tracking)** is independent except for one module guard; it can run in parallel on its own branch.
   Its phase C0 (in-game measurements) gates the combat log work.

| Part | Branch | Schema migration | Protocol minor | Size forecast |
|---|---|---|---|---|
| D | `feat/rank-mapping` | 18 | 13 | ~800 lines with tests |
| A | `feat/modules` | none (settings default) | none | ~500 lines with tests |
| B | `feat/announcements` | 19 | 14 | ~1100 lines with tests |
| C | `feat/pvp-tracking` | 20 | 15 | ~1300 lines with tests |

Migration and minor numbers assume the merge order D → A → B → C. Whoever merges later renumbers to the next free
value; the numbers are not part of any contract yet.

## Decided and default choices

| Topic | Choice | Status |
|---|---|---|
| Announcements board | A Guild tab that only lists announcements; nothing to edit there | decided |
| Announcements editor | An Admin tab to create, edit and delete announcements | decided |
| Popup per announcement | A "Send popup" switch on each announcement in the editor | decided |
| Modules section | A section to turn addon modules on and off | decided |
| PvP | Review mission tracking and make missions more configurable | decided |
| Who posts announcements | Only the `gm` role (rank Emperador) and the `cogm` role (rank Comandante) | decided |
| Modules scope | Each player turns modules on and off for themselves; nothing is synced | decided |
| Rank mapping | An Admin section maps guild ranks to addon roles, so a guild rank rename does not affect the addon | decided |
| Rank mapping key | The rank index (stable across renames), with the rank name kept for display and drift checks | default |
| Who edits the mapping | The `gm` and `cogm` roles; a cogm cannot change their own rank's role | decided |
| Modules location | A "Modules" tab at the end of the Guild group, visible to everyone | default |
| Modules storage | Account-wide, in `db.global.settings.modules` (like the other settings) | default |
| Disabling a module | Hides its tabs at once; stops its trackers, alerts and popups; synced data keeps arriving | default |
| Enabling a module that never started this session | Needs `/reload`; the tab says so with a button | default |
| PvP kill log | Kept independent of the season, backfilled when the season arrives | default |
| Killing blows | Via the combat log, only after C0 proves it works on the client | default |

**Out of scope:** announcement comments or reactions, announcements to other guilds, scheduling an announcement for a
future date, a guild-wide module policy imposed by officers, editing the in-game guild ranks from the addon, custom
addon roles beyond the existing seven, rewriting the PvP points/claims economy.

---

## 0. Principles (inherited from the addon)

- Domain code is pure and tested with busted fakes; Platform is the only file that touches the WoW API.
- Every new message type gets a validator in `Sync/Protocol.lua` `VALIDATORS` and a branch in `Comm:HandleMessage`.
- Authority is always checked on the receiver with the role it reads from its own guild roster
  (`SyncRules.Authorize` / `AuthorizeGlobal`), never from the payload.
- LWW uses `SyncRules.Wins` (rev, then `updatedAt`, then sender name) and `ClampTimestamp`.
- New strings go through `L("English text")` and get an entry in `Locales/esES.lua` (the locale test fails otherwise).
- Migrations in `Core/Store.lua` are idempotent; bump `SCHEMA_VERSION` in `Core/Constants.lua`.
- A new tab touches: `ViewModel.TABS`, `TAB_ACTIONS`, `PermissionService` `ACTIONS`, `UI/Tabs/X.lua` with
  `UI.Register`, a redraw hook in `UI/Main.lua`, the `.toc`, esES, `docs/PROTOCOL.md` and `docs/USER_GUIDE.md`.
- Each part updates `docs/PROTOCOL.md`, `docs/USER_GUIDE.md`, `docs/CURSEFORGE_DESCRIPTION.md` (English) and the
  release notes.

---

# Part A: Modules (personal)

## A.0 Decided scope

Each player turns modules on and off for themselves. Nothing is synced and nobody else is affected: an officer who
turns off PvP only stops seeing PvP on their own client. Turning a module off never deletes data.

## A.1 Module registry: `Domain/ModuleRegistry.lua` (pure)

A static list. Each module:

```lua
{ id = "pvp", label = "PvP", tabs = { "pvp", "pvpadmin" }, steps = { "pvp", "pvpSeason" }, requires = {} }
```

| id | Tabs | Activation steps (`Init.lua` `ACTIVATION_STEPS`) | Notes |
|---|---|---|---|
| `professions` | professions | recipes | |
| `raid` | events, ready, raid, rules, roster | (none) | Event sync keeps running |
| `loot` | loot | lootPopup, votingFrame, bossLoot | requires `raid` |
| `pvp` | pvp, pvpadmin | pvp, pvpSeason | |
| `intel` | (the Intel sub-tab of PvP) | intel | requires `pvp` |
| `groups` | groups | lfg | |
| `layers` | (no tab today) | layer | |
| `map` | (no tab) | position | |
| `blacklist` | (no tab) | blacklist | |
| `announcements` | announcements | announcements | added by Part B; the Admin editor stays visible to gm/cogm |

Not toggleable (core): home, modules, ranks, installs, character, profile, purge, comm, minimap, roster, autoPublish,
selfTest.

Admin tabs: turning off a module hides its Admin tab too (`pvpadmin` with `pvp`), except the announcements editor,
which gm/cogm keep so they can still publish. A gm/cogm who turns off a module sees a one-line warning on the switch:
"You will stop seeing its admin section too".

Functions:

- `ModuleRegistry.List()` → ordered modules.
- `ModuleRegistry.ForTab(tabValue)` / `ForStep(stepName)` → module id or nil.
- `ModuleRegistry.IsEnabled(settings, id)` → false if `id` or any module in `requires` is off.
- Unknown ids in the settings are ignored (a newer version may have more modules).

## A.2 Storage (no migration)

```lua
db.global.settings.modules = { off = {} } -- off[id] = true; created lazily by Domain/Settings.lua defaults
```

Everything enabled by default, so existing users see no change. `SCHEMA_VERSION` does not change.

## A.3 Service: `Domain/ModuleService.lua`

- `ModuleService:IsEnabled(id)` (the single check everybody calls: `ns.modules:IsEnabled("pvp")`).
- `ModuleService:SetEnabled(id, enabled)`: writes the setting, fires `onChange`. Turning a module on also turns on
  the modules it `requires`; turning one off turns off the modules that require it (with the UI saying so).
- `ModuleService:NeedsReload(id)`: true when the module is on now but its activation steps were skipped at login.

## A.4 Wiring

- `ViewModel.tabVisible`: return false when `ModuleRegistry.ForTab(tab.value)` is off. This covers the sidebar and the
  minimap menu (both use `TabsFor`). `UI.ResolveTab` already falls back to "home".
- PvP sub-tabs: `PvPSubTabs` drops `intel` when the `intel` module is off.
- `Init.lua` `Activate()`: skip a step whose module is off; record it in `ns.skippedSteps`.
- Runtime switch-off: add an early `if not ns.modules:IsEnabled(id) then return end` at the entry of the PvP
  kill/honour handlers, mission tracking, LFG popup, layer popup, loot popup, voting frame, boss loot, intel alerts,
  blacklist alert, map pins, recipe scan, announcement popup.
- Sync `Apply` functions are NOT gated: data keeps arriving so turning a module back on shows current state, and this
  client keeps relaying data to others.
- Home: cards of a module that is off are hidden.
- `UI/Main.lua`: a `ModulesChanged` hook rebuilds the sidebar and redraws the current tab.

## A.5 UI: Guild tab "Modules" (`UI/Tabs/Modules.lua`, `UI/ViewModelModules.lua`)

- No gate: every player, last entry of the Guild group.
- One row per module: icon, name, one-line description, switch, and the tabs it controls.
- Dependencies: turning off `pvp` shows "Intel will be turned off too" before applying.
- After turning on a module that needs reload: an inline notice "Reload the interface to start X" + `ReloadUI` button.
- A "Turn all on" button at the bottom.

## A.6 Tests

- `module_registry_spec`: every tab in `ViewModel.TABS` is either core or owned by exactly one module; every
  `ACTIVATION_STEPS` name likewise; `requires` cascades; unknown ids ignored.
- `module_service_spec`: default all on, set on/off with cascade, `NeedsReload`.
- `view_model_spec`: an off module hides its tabs for every role, except the announcements editor; `ResolveTab`
  falls back.
- `init_spec`: an off module's step is skipped and listed in `ns.skippedSteps`.
- `ui_smoke_spec`: Modules tab draws; switching re-draws the sidebar.

## A.7 Phases

- **A1** registry + settings + service, with tests.
- **A2** wiring (tabVisible, Activate skip, runtime guards).
- **A3** Modules tab, locales, docs.

---

# Part B: Announcements

## B.1 Model: `Domain/AnnouncementModel.lua` (pure)

```lua
announcement = {
  id,            -- "<author>-<serverTime>-<n>"
  title,         -- 1..60 chars
  body,          -- 0..600 chars, plain text, newlines allowed
  author,        -- sender name, set by the receiver from the message sender
  createdAt, updatedAt, rev,
  popup,         -- boolean: show a popup to members
  popupRev,      -- bumped by "Send popup again"; a member sees the popup once per popupRev
  pinned,        -- boolean, pinned ones list first
  expiresAt,     -- nil = never; otherwise purged after this time
}
```

Limits (Constants): 30 live announcements, title 60, body 600, expiry choices: never, 1 day, 7 days, 30 days.
Functions: `Validate`, `Sort` (pinned first, then `createdAt` desc), `IsExpired(a, now)`, `NeedsPopup(a, seen, now)`.

## B.2 Storage (migration 19)

```lua
db.global.announcements = { items = {}, tombstones = {} } -- items[id] = announcement
db.global.announcementsSeen = {}                            -- seen[id] = popupRev already shown
```

`seen` is per account, so alts of the same player do not get the same popup twice. Expired items and tombstones are
purged in the existing `purge` activation step (tombstones kept 30 days, like events).

## B.3 Service: `Domain/AnnouncementService.lua`

- `Publish(fields)`, `Edit(id, fields)`, `Delete(id)`, `ResendPopup(id)`: require `announce_manage`; stamp rev; apply
  locally; send.
- `Apply(message, sender)`: authorize (`announce_manage` scope ≠ none on the receiver's roster), LWW, tombstones win
  over older revs, enforce the 30 cap by dropping the oldest unpinned.
- `MarkSeen(id)`, `Unread()` (count for the sidebar badge: items created after the last time the board was opened).
- `onChange` → UI redraw; `onPopup(a)` → popup queue (only when `a.popup` and `NeedsPopup`).

## B.4 Protocol (minor 14)

- `ANN`: the full announcement (minus `author`, which the receiver sets from the sender). Body max ~600 chars fits
  in AceComm multipart; keep the validator strict on types and lengths.
- `ANN_DEL`: `{ id, rev, updatedAt }`.
- Catch-up: add items and tombstones to `Transfer.BuildSnapshot` (`SYNC_DATA`). A gm/cogm who logs in also re-sends
  their own live announcements once, jittered, so a guild with no `raid_manage` leader online still converges.

## B.5 Popup: `UI/AnnouncementPopup.lua`

- Built on `PopupFrame.New` (movable card, position remembered).
- Content: title, author + date, body (scrolls past ~10 lines), buttons **"Got it"** (marks seen) and
  **"Open board"** (opens the Guild tab and marks seen).
- Plays `Platform.PlayAlertSound` once and shows a short `Platform.ShowRaidNotice` line "New guild announcement".
- Queue: one popup at a time; if several arrive, the card shows "1 of N" with next/prev.
- Not shown in combat: queued and shown on `PLAYER_REGEN_ENABLED`.
- On login, after catch-up: at most the 3 most recent unseen popup announcements younger than 7 days, older ones
  only count as unread on the board.
- Respects the `announcements` module flag (Part A).

## B.6 UI

**Guild tab "Announcements"** (`UI/Tabs/Announcements.lua`, `UI/ViewModelAnnouncements.lua`):

- No gate (every member). Sidebar badge with the unread count.
- A list of cards: pinned badge, title, author, relative date, body. Expired items are hidden.
- Empty state: "No announcements yet".

**Admin tab "Announcements"** (`value = "announceadmin"`, `TAB_ACTIONS.announceadmin = "announce_manage"`):

- Form: title, body (multi-line), switches **Send popup** (default on) and **Pin**, expiry selector.
- Buttons: Publish / Save changes / Cancel.
- List of existing announcements with Edit, Delete (confirm), and **Send popup again** (bumps `popupRev`).
- Counter "N of 30".

**Home (optional, last):** the newest pinned announcement as a one-line banner linking to the board.

## B.7 Permissions

`announce_manage = GLOBAL_ONLY` (`{ gm = ALL, cogm = ALL }`) in `PermissionService` `ACTIONS`. With today's ranks
that is Emperador (gm) and Comandante (cogm); after Part D it follows whatever ranks the mapping assigns to those two
roles. Officers see neither the Admin editor nor any publish control. The receiver's check uses the same action, so
an `ANN` from an officer is dropped.

## B.8 Tests

- `announcement_model_spec`: validation limits, sort, expiry, `NeedsPopup` with `popupRev`.
- `announcement_service_spec`: publish/edit/delete/resend, unauthorized sender dropped, LWW, tombstone vs older rev,
  cap of 30, `onPopup` fired only when `popup` and unseen.
- `protocol_spec`: `ANN`, `ANN_DEL` validators.
- `transfer_spec`: snapshot round trip includes announcements.
- `view_model_announcements_spec`: board order, badge count, admin form state.
- `ui_smoke_spec`: both tabs and the popup draw; popup queue in combat.

## B.9 Phases

- **B1** model, storage, service, protocol, snapshot, with tests.
- **B2** popup + queue + combat deferral.
- **B3** both tabs, badge, locales, docs. Register module `announcements` in the Part A registry.

---

# Part C: PvP mission tracking

## C.1 Problems found in the current code

| # | Problem | Evidence |
|---|---|---|
| P1 | Only honour kills count; no killing blows (combat log disabled) | `Constants.lua:168-172`, `Init.lua:227` |
| P2 | A second honour kill of the same victim within 5 s is merged in the feed and never reaches the mission log | `PvPFeed.lua:109-117, 143-148` |
| P3 | Kills are dropped while the client has no active season locally (no gm/cogm online to relay it yet); no backfill | `PvPMissionService.lua:39-45, 84-87` |
| P4 | The log is wiped when the season id changes | `PvPMissionService.lua:58-71`, `Init.lua:1237` |
| P5 | Victim class/race known only if targeted, moused over or nameplated in the last hour | `PvPUnitCache` |
| P6 | Enemy class/race lists are hardcoded Horde (assumes an Alliance guild) | `Constants.lua:288-289` |
| P7 | BG win only logged if `UPDATE_BATTLEFIELD_STATUS` fires with a winner while still inside | `PvPMissionService.lua:118-142` |
| P8 | Claims live only in online approvers' queues; a claimant never online with an approver stalls | `PvPSeasonSync.lua:313-315, 357-398` |
| P9 | Progress is local only; officers cannot see who is close to a goal | `char.pvpMissions` |
| P10 | `OnWorldEntered` handler not wrapped in `pcall` | `Init.lua:137` |
| P11 | The per-victim cap (3 per UTC day) is global, not per mission | `PvPMissionTracker.lua:55` |
| P12 | Docs drift: `PVP_BG_WIN_DEDUPE_SECONDS` mentioned but gone | `PVP_MISSIONS_PLAN.md:640-642` |

## C.2 Phase C0: in-game measurements (gate for C3)

Add to `docs/API_NOTES.md` and measure on the Forever client (with `/nrage debug` output):

- **M6:** `COMBAT_LOG_EVENT_UNFILTERED` `PARTY_KILL` fires with `sourceGUID == UnitGUID("player")` for a player kill
  in world PvP and in a BG, without taint or blocked-action dialogs.
- **M7:** `GetPlayerInfoByGUID(destGUID)` returns class and race for an enemy player (also from `UNIT_DIED`).
- **M8:** `UnitFactionGroup("player")` + the BG winner value mapping (closes M5).
- **M9:** `RequestBattlefieldScoreData` + `UPDATE_BATTLEFIELD_SCORE` → `GetBattlefieldWinner` non-nil at the end of
  each BG type (WSG, AB, AV).

If M6/M7 fail, C3 is dropped and P1/P5 stay documented limits.

## C.3 Phase C1: a reliable kill log (P2, P3, P4, P10)

- **Season-independent log.** Replace `char.pvpMissions = { seasonId, kills, claims }` with
  `char.pvpLog = { events = {}, version = 1 }` (migration 20 moves existing rows). Every honour kill, killing blow and
  BG result is logged with its timestamp regardless of season. Retention: 45 days and 3000 rows, oldest dropped.
- **Backfill.** `PvPMissionTracker.Progress` already filters by dates; progress for a season that arrives late is
  computed from the same log. Nothing is lost while waiting for `PVP_SEASON`.
- **Claims** move to `char.pvpClaims[seasonId]`, so changing season no longer wipes kills.
- **Log before merge.** `PvPFeed` merging stays for the feed display only; `Init.lua` calls the log writer directly
  from the honour handler, before the feed merge.
- **Dedupe by source.** An honour kill and a killing blow on the same victim within 3 s are the same kill: one row
  with `honor = true, blow = true`.
- Wrap `OnWorldEntered` and the BG status handler in `pcall` with the existing startup error reporter.

## C.4 Phase C2: faction and BG wins (P6, P7)

- Enemy class/race lists derived from `UnitFactionGroup("player")`: Constants get both lists, keyed by faction.
- BG result detection, in this order, first one wins per BG instance:
  1. `UPDATE_BATTLEFIELD_STATUS` with a winner (current path);
  2. `UPDATE_BATTLEFIELD_SCORE` after `RequestBattlefieldScoreData` (called on `PLAYER_REGEN_ENABLED` and every 30 s
     while in a BG);
  3. on leaving the instance, if a winner was seen at any point.
- Log `{ kind = "bg", result = "win" | "loss", bg = "wsg" | "ab" | "av", at }`. The instance key is
  `instanceId + start time`, replacing the `bgWinLogged` marker.

## C.5 Phase C3: killing blows and better victim data (P1, P5), only if C0 passed

- Platform: `Platform.OnPartyKill(handler)` reading `CombatLogGetCurrentEventInfo`, filtering `PARTY_KILL`, source =
  player, dest is a player GUID; also `UNIT_DIED` of player GUIDs seen damaged by the player in the last 10 s.
- `GetPlayerInfoByGUID` fills class and race; also feeds `PvPUnitCache` by name, so honour kills of the same victim
  get class/race too.
- Turn `PVP_COMBAT_LOG_ENABLED` into the `pvp` module's runtime behaviour (no constant).
- Performance: the CLEU handler returns on the first non-matching subevent; no allocations on the hot path.

## C.6 Phase C4: more configurable missions (P11 + new options)

New goal kinds (`goal.kind`):

| Kind | Counts | Notes |
|---|---|---|
| `kills` | honour kills (current) | renamed label "Honourable kills" |
| `blows` | killing blows | needs C3 |
| `any_kill` | honour kill or killing blow, once per kill | default for new missions when C3 is live |
| `kos` | kills of KOS players (current) | |
| `bg_wins` | BG wins (current) + new filter `bgs = { "wsg", "ab", "av" }` | |
| `bg_played` | BGs finished, win or loss | |
| `manual` | officer-approved (current) | |

New per-mission options (all optional, validated in `PvPSeasonModel`):

- `victimClasses`, `victimRaces`: multi-select filters (replaces "distinct" only as a filter; `distinct` stays).
- `victimCapPerDay`: per-mission cap per victim per day (default 3, 0 = no cap), replacing the global cap for that
  mission (P11).
- `minGuildInGroup`: the kill counts only if at least N guild members were in the party/raid at that moment (logged
  as `guildInGroup` on each row from the roster; 0 = off).
- `window`: optional start/end inside the season dates (a "weekend event" mission).
- `maxCompletions`: for daily/weekly repeats, the max times one member can complete it in the season (0 = no limit).
- `autoClaim`: when the goal is reached, the claim is submitted automatically (member gets a notice); default off.

Admin form (`UI/Tabs/PvPAdmin.lua`): group the new fields under an "Advanced" collapsible section so the simple
form stays as it is. Show a live summary line under the form ("Counts honour kills in Arathi Basin, 10 times,
max 1 per victim per day, 50 points, weekly").

**Presets:** a "Start from template" dropdown with 5 built-in presets (Weekly WSG wins, Daily 20 kills, KOS bounty,
Group up: 5 kills with 3 guildies, AV veteran) that fill the form.

## C.7 Phase C5: progress visibility and stalled claims (P8, P9)

- **Progress summary sync:** new `PVP_PROGRESS` message `{ seasonId, rows = { { missionId, count, goal } } }`, sent on
  `GUILD` at most once every 2 minutes and only when something changed; no evidence rows. Approvers store the latest
  per member in memory (and in `db.global.pvpSeason.progress`, last value per member, for offline viewing).
- **Admin view:** a "Progress" section in PvP admin: per mission, members sorted by progress, with "ready to claim".
- **Stalled claims:** the claimant re-sends pending claims when it sees a `HELLO` from a gm/cogm, not only every
  600 s; approvers persist the claim queue (`db.global.pvpSeason.queue`) and include it in `PVP_LEDGER_DATA` between
  gm/cogm so another approver can process it.
- **Member view:** the Missions sub-tab shows the progress bar per mission (already partly there), the active
  filters in plain words, "counts from DATE" and the state: in progress / ready to claim / claimed / approved.

## C.8 Protocol (minor 15)

- `PVP_MISSION` validator accepts the new goal kinds and options; older clients drop unknown kinds (they already drop
  unknown fields?: **verify** in `Protocol.lua` before changing; if they reject, gate new kinds behind minor ≥ 15 and
  show "needs addon update" for members on older minors in the Installed check).
- New `PVP_PROGRESS`.
- `PVP_LEDGER_DATA` gains a `queue` page.

## C.9 Tests

- `pvp_mission_service_spec`: kills logged without a local season and counted when the season arrives (backfill);
  season change keeps kills; two kills of the same victim within 5 s both counted; honour + blow dedupe.
- `pvp_mission_tracker_spec`: each new kind and option, `victimCapPerDay` per mission, `window`, `maxCompletions`,
  `minGuildInGroup`.
- `pvp_season_model_spec`: validators for the new fields and limits.
- `platform_spec`: CLEU parsing with fakes; faction-based enemy lists; BG result fallbacks.
- `pvp_season_sync_spec`: `PVP_PROGRESS`, queue in ledger pages, claim re-send on approver HELLO.
- `store_spec` / migration 20: old `pvpMissions` rows move to `pvpLog`.
- `ui_smoke_spec`: advanced section, presets, progress section.

## C.10 Phases

- **C0** measurements (owner, in game). Gates C3.
- **C1** reliable log + migration 20 (biggest value, no API risk).
- **C2** faction + BG detection.
- **C3** combat log (only if C0 passed).
- **C4** new kinds, options, presets, admin form.
- **C5** progress sync, admin progress view, stalled claims.
- Docs: fix P12 drift in `PVP_MISSIONS_PLAN.md`, `PROTOCOL.md` minor and relay drift (doc says minor 11 and lists
  rl/admin/officer as ledger relays; code is 12 and gm/cogm only).

---

# Part D: Rank mapping

## D.1 Problem

Today the role comes from the guild rank **name** through the hardcoded `Constants.RANK_ROLES`
(`PermissionService.RoleForRank`, `Core/Constants.lua:52-65`). Renaming a rank in the game turns its members into
`alter` (least privilege) until a new addon version ships. This happened in 2026-11 (the rename to Emperador,
Comandante, ...). `RoleForRank` / `RoleOf` / `OwnRole` already accept an optional `mapping`, but nobody passes one.

## D.2 Model: `Domain/RankMapModel.lua` (pure)

```lua
rankMap = {
  rev, updatedAt, by,
  ranks = { [rankIndex] = { role = "cogm", name = "Comandante" } }, -- rankIndex 1..9; 0 is always gm
}
```

- Key = **rank index**: renaming a rank keeps its index, so the role survives the rename. `name` is the name when the
  mapping was saved, used only for display and to detect drift.
- Index 0 is not stored: it is always `gm` (`IsGuildMasterIndex`).
- Roles allowed: `cogm`, `officer`, `rl`, `roster`, `member`, `alter` (`gm` cannot be assigned to another rank).
- `RankMapModel.Resolve(rankMap, rankName, rankIndex)`:
  1. index 0 → `gm`;
  2. a mapped index → its role;
  3. no mapping saved for that index (or no mapping at all) → today's name lookup in `Constants.RANK_ROLES`, so the
     addon keeps working exactly as now until the GM saves a mapping;
  4. otherwise `alter`.
- `RankMapModel.Drift(rankMap, currentRanks)` → list of `{ index, savedName, currentName }` where the names differ, plus
  indexes that appeared or disappeared (ranks added or removed in the game shift the indexes below them).

## D.3 Storage (migration 18)

```lua
db.global.rankMaps = {} -- [guildKey] = rankMap; guildKey = "<guild name>-<realm>"
```

Keyed by guild so the Guild Assistant fork and alts in other guilds never mix mappings. Empty by default: no change in
behaviour until the GM saves one.

## D.4 Authority (security: high-risk item 2)

- The `gm` and `cogm` roles edit the mapping (new action `ranks_manage = GLOBAL_ONLY`).
- **Sender check on the receiver, against the map it holds BEFORE applying the new one:** accepted when the sender's
  roster entry has `rankIndex == 0`, or when the sender's role resolved with the receiver's current map is `cogm`.
  The incoming map never authorizes itself.
- **Guards for a cogm sender** (validated on both sides, the receiver drops the whole message on any violation):
  - the row of the sender's own rank index must keep its current role (no self-promotion or self-demotion);
  - `gm` is never assignable (index 0 is fixed), so nobody can reach the guild master's role.
- What a cogm can still do, by design: make another rank `cogm`, or demote another `cogm` rank. The GM can always undo
  it, since the GM's role never depends on the map, and the footer shows who saved last.
- Reading the section: `admin_view` roles (they can see the mapping, not change it).
- LWW with `SyncRules.Wins`; timestamps clamped.

## D.5 Wiring

- `PermissionService.RoleForRank(rankName, mapping)` becomes `RoleFor(rankName, rankIndex, rankMap)` and delegates to
  `RankMapModel.Resolve`. `RoleOfEntry` and `OwnRole` pass `rankIndex`.
- A single provider `ns.rankMap()` returns the map of the current guild; `PermissionService` reads it by default, so
  the ~all existing callers of `RoleOf` / `OwnRole` do not change.
- When the map changes: recompute the own role, rebuild the sidebar (`RanksChanged` hook in `UI/Main.lua`), and re-run
  the access guard (`AccessGuard`, `Init.lua:1453`).
- `Platform.GetGuildRanks()` → `{ [index] = name }` from `GuildControlGetNumRanks` / `GuildControlGetRankName`
  (**verify** the index base on the client: M10 below).

## D.6 Protocol: `RANK_MAP` (minor 13)

- Payload `{ rev, updatedAt, ranks = { { i = 3, r = "officer", n = "Oficial" }, ... } }`, at most 9 rows, name ≤ 32
  chars, role in the allowed set.
- Sent on `GUILD` on save. Catch-up: added to `Transfer.BuildSnapshot` (`SYNC_DATA`), and the GM re-sends it once
  after login (jittered). Older clients drop the unknown type and keep using names (no harm).

## D.7 UI: Admin tab "Ranks" (`UI/Tabs/Ranks.lua`, `UI/ViewModelRanks.lua`)

- Gate: `TAB_ACTIONS.ranks = "admin_view"`; editing controls only for `ranks_manage`.
- One row per guild rank, in index order: index, current rank name, member count, a role dropdown.
  Row 0 shows "Guild master" and no dropdown; for a cogm, the row of their own rank is read-only too.
- First open with no saved map: the dropdowns are pre-filled from today's name lookup, so saving changes nothing.
- **Preview before saving:** "3 members change role: Name (officer → member), ...". Save is disabled while nothing
  changed.
- **Drift banner:** when `Drift` finds renamed ranks: "Rank 2 was renamed from Comandante to X; its role is kept".
  When ranks were added or removed: "Guild ranks changed; review the mapping" (in red), shown to every `admin_view`
  user.
- Footer: "Saved by NAME, DATE".

## D.8 In-game measurement

- **M10:** `GuildControlGetNumRanks()` and `GuildControlGetRankName(i)` (1-based) match the 0-based `rankIndex` of
  `GetGuildRosterInfo` / `GetGuildInfo` as `i - 1`. Check with `/nrage debug`.

## D.9 Tests

- `rank_map_model_spec`: index 0 always gm; mapped index wins over name; no map → name lookup (today's behaviour,
  pin it with the current `RANK_ROLES` cases); unmapped index → name lookup → `alter`; `gm` cannot be assigned;
  `Drift` for renamed, added and removed ranks.
- `permission_service_spec`: every existing role test still passes without a map; a rename with a map keeps the role.
- `rank_map_sync_spec`: accepted from rankIndex 0; accepted from a cogm (by the receiver's current map); dropped from
  an officer; dropped when a cogm changes their own rank's row; dropped when an incoming map would make its own
  sender cogm (no self-authorization); LWW; unknown guild key ignored.
- `protocol_spec`: `RANK_MAP` validator.
- `view_model_ranks_spec`: pre-fill, preview diff, drift banner, read-only for officers.
- `ui_smoke_spec`: Ranks tab for gm and officer.

## D.10 Phases

- **D0** M10 measurement.
- **D1** model, storage, `PermissionService` wiring, with tests (no UI, no sync: map only from tests).
- **D2** sync + snapshot + re-evaluation on change.
- **D3** Ranks tab, locales, docs (`USER_GUIDE.md`: "If you rename a guild rank").
- Independent review before merge (security change).

---

## Handoff per model

| Work | Model | Why |
|---|---|---|
| D1, D2 | Sonnet, then an independent review | Permissions and sync (security) |
| A1, B1, C1, C4 domain + tests | Sonnet | Sync, LWW, migrations, pure rules |
| C2, C3, C5 | Sonnet | Platform/API and protocol risk |
| A2 wiring | Sonnet | Touches every feature's entry points |
| A3, B3, D3 tabs, locales, docs | Haiku | Mechanical UI following existing tabs |
| B2 popup | Haiku, reviewed by Sonnet | Follows `LfgPopup` / `LayerPopup` |

Each phase ends with `busted`, `luacheck` and `stylua --check` green, and its in-game checklist items added to the
part's section in `docs/USER_GUIDE.md` or the release notes.

## In-game checklist (after implementation)

- A: turning off PvP hides PvP and PvP admin on that player's client only; other players still see it; turning it
  back on asks for reload.
- D: the GM renames a rank in the game; its members keep their addon role; the Ranks tab shows the rename banner.
  A cogm saves a change and other members receive it; the dropdown of the cogm's own rank is disabled; an officer
  has no edit controls.
- B: the GM or a cogm publishes with popup on; an officer has no editor; an online member sees the popup once; a member logging in later sees it on
  login; "Send popup again" shows it again; with popup off only the board updates.
- C: two kills of the same player in quick succession count twice; a kill made before the season reached the client
  counts after it arrives; a BG win is logged in WSG, AB and AV; killing blows count (if C3 shipped).

## Decisions log

- 2026-11-10: plan written. Part A scope (guild policy vs personal) left open.
- 2026-11-10: owner decisions: "Cada jugador puede activar o desactivar sus módulos." / "En los anuncios, que solo
  pueda mandarlos GM -> Emperador y CoGM -> Comandante" / "vamos añadir en admin una nueva sección que sirva para
  mapear los roles del addon con los de la guild, para que en caso de cambiar los de la guild, no afecte al addon".
  Part A made personal (no sync), `announce_manage` set to gm/cogm, Part D added and ordered first.
- 2026-11-10: rank mapping editors: "GM and CoGM". A cogm cannot change their own rank's row.
