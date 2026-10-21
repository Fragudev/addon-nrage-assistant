# PvP missions, seasons and rewards plan

Implementation plan for a PvP season system: admins define missions that award points, members claim them, an
admin or PvP officer approves each claim, the points build a season ranking in the PvP tab, and at the end of a
season the top 10 receive gold or item rewards that are handed over in game.

This document is written for the implementing agent. It must be executable without the conversation that produced
it. Items marked **decided** were agreed with the guild officer who owns the addon on 2026-10-20. Items marked
**default** were proposed and not objected to; they are open to review but should be implemented as written.

**Status:** implemented (2026-10-20). Every phase is merged into `main`: P1 in #133 (API in section 9), P2 and P3 in
#134 (API in section 10), P4 and P5 in #135. It was built on `main` at `695bbe1` (redesign #129, profile icons #130
and layer swap #131).

**Still open:** the in-game measurements M1–M5 (section 5, tracked in `docs/API_NOTES.md`) and a visual check of the
PvP tab in game. Until they are measured, every client read is guarded and a missing or unreadable value shows as
"not available on this client". The zone map ids, the enemy class and race lists and the battleground winner mapping
in `Core/Constants.lua` are Classic values to confirm on Forever.

**Visual reference:** the redesign mockup canvas (Design artifact "Nrage Assistant redesign",
https://claude.ai/artifact/U4aUo3uAXjK3jL4zpTi2eR, artboard "Ventana principal" → PvP, version 23 or later). Use
"Ver como" = `admin`, `pvpOfficer` and `member` to see each view. The mockup copy is Spanish because that is the
guild's language; in code every string goes through `L()` with an English key and an `esES` entry.

---

## 0. Principles

### 0.1 Rules inherited from the addon (must hold in every phase)

- Client APIs only through `NrageAssistant/Core/Platform.lua`, each guarded (`pcall`) for a missing API, an error
  and a secret value. A value that cannot be read is **unknown**, never guessed.
- Domain logic is pure and injected (`New(deps)` with `now`, `send`, `platform`...). Frames stay thin. Tests use
  fakes (see `tests/pvp_feed_spec.lua`, `tests/pvp_sync_spec.lua`). The coverage gate stays at 80 %.
- Every received byte is hostile (`docs/PROTOCOL.md`, "Principles"): whitelist validation in `Sync/Protocol.lua`,
  size caps, no `|` or control characters in text, unknown fields dropped.
- **The sender comes from the client, never from the payload.** Authority comes from the receiver's own guild
  roster (`PermissionService.RoleOf`) plus, for PvP officers, the receiver's own copy of the officer records.
- Nothing is sent during the encounter lockdown (`C_ChatInfo.InChatMessagingLockdown`). Persistent records are
  queued in `Sync/OutboundQueue.lua` like the other upserts; live-only data is dropped.
- Everything runs only while `ns.active` (access guard passed).
- Every user-facing string through `L()` with an `esES` entry in the same change; debug output stays English.
- SavedVariables changes go through a new idempotent migration in `Core/Store.lua` (`SCHEMA_VERSION` + 1; on
  `main` it is 11 today, use the next free number at implementation time, since other branches may bump it).

### 0.2 What "signed by an admin" means here

There is no cryptography. A record is "signed" by whoever **sent** it, as identified by the client, and it counts
only when the receiver's own roster says that sender may author it. When records are relayed in a snapshot, the
relay is trusted the same way `PVP_STATS` relays are today (`docs/PROTOCOL.md`, "Snapshot for late joiners"): the
`by` field of a relayed record is accepted **only inside a snapshot from a trusted relay** (admin, PvP officer or
raid leader, checked before decoding). On the guild channel, `by` is never read: it is always the sender.

### 0.3 Decisions (2026-10-20)

| # | Decision | Status |
|---|---|---|
| D1 | Every mission claim needs approval by an admin or PvP officer, including automatically detected ones | decided |
| D2 | Full scope: zone, count, distinct names, victim class/race (via a unit cache), battleground wins, manual missions | decided |
| D3 | Points live in an append-only ledger of grants; the ranking is derived from it on every client | decided |
| D4 | Missions are combinable criteria, not hard-coded per mission | decided |
| D5 | Seasons are manual: an admin sets name, start and end dates. Only one active season at a time | decided |
| D6 | The end date only blocks new claims; an admin closes the season with a two-click button. Pending claims expire on close | default |
| D7 | Closing produces a frozen final standing and a delivery list; history keeps every season's standings plus an all-time cumulative ranking | decided |
| D8 | Rewards are gold or items, defined per season in the PvP admin panel | decided |
| D9 | Rewards are given only at season close, by tier: 1st, 2nd, 3rd, 4th–6th (same prize each), 7th–10th (same prize each). Each player in a tier gets the full prize | decided |
| D10 | Points are never spent: the ranking is the season's earned total | decided |
| D11 | Tie-break: whoever reached the final total first (earlier time of their last counted grant), then name | default |
| D12 | At least 1 point to receive a prize; empty tiers stay empty | default |
| D13 | The addon never sends gold or mail. Delivery is done in game and marked "delivered" in the panel | default |
| D14 | Anti-abuse: one victim counts at most 3 times per server day across all missions; kills without honour (grey) never count | default |
| D15 | Manual missions (not detectable) are claimed with a note, or granted directly by an admin | default |
| D16 | UI: everything inside the PvP tab as sub-tabs: Temporada · Misiones · Estadísticas · Bajas recientes · Histórico · Admin | decided |
| D17 | "Estadísticas" merges today's "My stats" and kill "Ranking" behind a segmented control | decided |
| D18 | Same visual style as the redesign (ember theme, redesign UI kit) | decided |
| D19 | New assignable **PvP officer** flag (not a role): approves/rejects claims and marks deliveries. Admin only: seasons, missions, prizes, voiding grants, assigning officers | decided |
| D20 | An officer flag keeps its validity intervals; a grant counts if its author was admin or officer at the grant time. Removing the flag does not undo earlier grants; an admin voids any abusive one | default |
| D21 | Delivery order: the five phases of section 6 | decided |

### 0.4 Privacy (default)

The mission log stores victim names, zones and, when known, class and race, per character, for the active season
only. It is shared with the guild only inside a claim as evidence. Closing a season deletes the detailed kill log
and the detailed grants of that season and keeps only the final standing and the delivery list. Update
`docs/PRIVACY.md` in phase 2.

---

## 1. Domain model

All identifiers are 1–40 characters from `[A-Za-z0-9_-]` (same rule as message ids), generated with the existing
id helper used for events. Times are server time (`GetServerTime`), clamped with `SyncRules.ClampTimestamp`.
Character names follow the roster identity rules in `docs/API_NOTES.md` (full roster name, possibly multi-word).

### 1.1 Season

```lua
season = {
  id, name,             -- name: plain text, 1..40
  startsAt, endsAt,     -- server time; endsAt > startsAt
  state,                -- "active" | "closed"
  rev, updatedAt, updatedBy,
}
```

- At most one `active` season. Creating a season while another is active is refused locally and on receipt.
- A claim is accepted only for a kill/win with `startsAt <= at <= endsAt`, and only while `state == "active"`.
- After `endsAt` the client stops counting and the Missions sub-tab says the season has ended and is awaiting close.

### 1.2 Mission

```lua
mission = {
  id, seasonId, title, desc,       -- title 1..40, desc 0..100
  points,                          -- 1..1000
  goal = {
    kind,                          -- "kills" | "bg_wins" | "manual"
    count,                         -- 1..500 (ignored for manual; for distinct=class/race it is derived)
    zones,                         -- list of uiMapIds (0..5), empty = anywhere
    place,                         -- "any" | "world" | "bg"
    distinct,                      -- "none" | "name" | "class" | "race" | "class_race"
  },
  repeatKind,                      -- "once" | "daily" | "weekly"
  perPlayer,                       -- max approved claims per player per period, 1..10 (default 1)
  active,                          -- false = paused (hidden from members, no new claims)
  rev, updatedAt, updatedBy,
}
```

- `distinct = "class"`: one kill of each enemy class; the target is the set of enemy classes (constant
  `PVP_ENEMY_CLASSES`, the Horde classes for an Alliance guild). `"race"`: the set of enemy races
  (`PVP_ENEMY_RACES`). `"class_race"`: both sets must be complete; progress shows two bars.
- Zones are **uiMapIds**, not names, so they do not depend on the client locale. The admin picks zones from a
  constant list `PVP_MISSION_ZONES = { { mapId, nameKey } ... }` (capitals and contested zones) or adds "current
  zone". The list's map ids must be measured in phase 2 (section 5).
- Missions are never deleted, only paused (`active = false`): grants keep pointing to them.
- Period keys: `once` → `"all"`, `daily` → server day UTC (`YYYYMMDD`, same day boundary as PvP "Today"), `weekly`
  → ISO week UTC (`YYYYWww`).

### 1.3 Claim

```lua
claim = {
  id,            -- "<playerKey>:<missionId>:<periodKey>:<n>"  (n = 1..perPlayer)  → idempotent
  missionId, seasonId, periodKey,
  player,        -- always the sender
  at,            -- when the claim was made
  summary,       -- e.g. { done = 10, total = 10 } or { classes = 8/8, races = 4/4, unknown = 1 }
  evidence,      -- list (0..PVP_CLAIM_EVIDENCE_MAX) of { at, victim, mapId, place, class?, race? } or { at, bgWin = true, mapId }
  note,          -- 0..100, required for manual missions
}
```

- A claim is local state of the claimant (`char.pvpMissions.claims`) plus a pending entry in the queue of every
  approver client (`global.pvpSeason.queue`).
- The claimant re-announces its pending claims after login (with the existing login send delay) and then every
  `PVP_CLAIM_REANNOUNCE_SECONDS` (default 600) while any is pending, so an officer who logs in later still gets them.
- Evidence must fit one guild message: `PVP_CLAIM_EVIDENCE_MAX` (default 60) rows; for a larger count, the claim
  carries the first 60 matching kills plus the summary. A test builds the largest possible claim and asserts that it
  encodes under the guild message limit.

### 1.4 Grant, void, decision

```lua
grant  = { id, seasonId, player, missionId, points, at, by }   -- id = claim id, or a new id for a direct grant
void   = { grantId, seasonId, reason, at, by }                 -- admin only; reason 0..100
reject = { claimId, seasonId, reason, at, by }                 -- admin or officer
```

- Approving a claim = sending a grant whose `id` is the claim id. Two approvers approving the same claim produce
  the same id: the second is a no-op. That is what makes double approval harmless.
- `points` is copied from the mission at approval time (editing a mission later does not change past grants).
- A grant for a player the receiver's roster does not know is still stored (members leave), but it is shown with
  the name only.
- A rejection marks the claim rejected; a later grant with the same id still wins (an approver can change their mind).
- Grants are accepted when `by` is an admin, or a PvP officer whose validity covers `at` (section 1.6).

### 1.5 Prizes and deliveries

```lua
prizes = {
  seasonId,
  tiers = { ["1"] = rewards, ["2"] = rewards, ["3"] = rewards, ["4-6"] = rewards, ["7-10"] = rewards },
  rev, updatedAt, updatedBy,
}
rewards  = list (0..5) of { kind = "gold", amount = 1..100000 } | { kind = "item", itemId, name, count = 1..200 }
delivery = { seasonId, player, tier, delivered = bool, rev, updatedAt, updatedBy }
```

- The whole `prizes` record replaces the previous one (like `READINESS_RULES`).
- An item is added by pasting an item link; the addon extracts `itemId` and the item name (the link itself is not
  sent: `|` is not allowed on the wire). Display uses `GetItemInfo(itemId)` when available for the quality color.
- Prizes can be edited until the season is closed; the final standing copies the prizes into itself.

### 1.6 PvP officer

```lua
officer = { player, intervals = { { from, to? } ... }, rev, updatedAt, updatedBy }   -- at most 10 intervals
```

- Admin only. Toggling on opens an interval (`from = now`), toggling off closes it (`to = now`).
- `IsOfficerAt(player, at)` is true when any interval covers `at`. `IsOfficer(player)` = an open interval.
- The flag is independent of the addon role (`member`, `rl`, `council`); an admin never needs it.
- Keep it as its own `PVP_OFFICER` record, separate from the `MEMBER_UPSERT` role assignments of
  `Sync/RosterSync.lua` (redesign plan 3.4.2), so the role conflict rules stay untouched. Follow `RosterSync` for
  style, authority (`roster_manage` is the guild master; use the new `pvp_officer_assign`) and tests.

### 1.7 Final standing

```lua
final = {
  seasonId, name, startsAt, endsAt, closedAt, closedBy,
  standings = list (0..PVP_FINAL_STANDINGS_MAX = 100) of { pos, player, points, lastAt },
  prizes,   -- copy of the season's prizes
}
```

- Built by the closing admin from their ledger and sent as one record. Receivers store it as is: **the final
  standing is authoritative** over any grant they hold or receive later for that season.
- On close (and on receipt of a final), clients delete the season's grants, voids, rejections, the pending queue
  and the members' kill logs for that season, and create one `delivery` entry per player in tiers 1–10.

### 1.8 Ranking (derived, pure)

`PvPSeasonModel.Standings(grants, voids, officers, roleOf)`:

1. Keep grants of the season that are valid (author check of 1.4) and not voided.
2. Sum points per player; `lastAt` = the latest `at` among that player's counted grants.
3. Sort by points descending, then `lastAt` ascending (D11), then name.
4. Positions 1..N; tier of a position: 1, 2, 3, 4–6, 7–10, none. Players with 0 points are not ranked (D12).

Cumulative ranking (Histórico → Acumulado): sum of `points` over all finals; columns seasons played, podiums
(positions 1–3), points.

---

## 2. Detection (client side)

### 2.1 Kill log

- Source: the existing kill feed (`Domain/PvPFeed.lua`). Each own feed entry (honour kill, with victim name and
  place) is appended to `char.pvpMissions.kills` while a season is active and inside its dates:
  `{ at, victim, mapId, place, class?, race? }`.
- `mapId` from a new `Platform.GetPlayerMapId()` (`C_Map.GetBestMapForUnit("player")`), read when the kill is
  recorded. Unknown → `nil`: such a kill never matches a zone criterion.
- Kills without honour (grey) are not in the feed as honour kills and never count (D14).
- Cap: `PVP_MISSION_KILLS_MAX` (default 2000) per character; oldest dropped first.

### 2.2 Unit cache (victim class and race)

The combat log is disabled on this client (`PVP_COMBAT_LOG_ENABLED = false`), so the victim's GUID is not
available. The class and race come from a cache filled while the player sees enemies:

- Events: `PLAYER_TARGET_CHANGED`, `UPDATE_MOUSEOVER_UNIT`, `NAME_PLATE_UNIT_ADDED` (units `target`,
  `mouseover`, `nameplateN`). For a unit that is a player and an enemy (`UnitIsPlayer`, `UnitIsEnemy("player", u)`),
  store `name → { class = classFile, race = raceFile, seenAt }` (`UnitClass` / `UnitRace` second return, which do
  not depend on the locale).
- Name: the same form the kill feed produces for the victim. Which form that is (full multi-word name or first word)
  is measured in phase 3; the cache must key by exactly that.
- In memory only, `PVP_UNIT_CACHE_MAX` (default 500) entries, least recently seen dropped first, entries older than
  `PVP_UNIT_CACHE_TTL` (default 1 h) ignored.
- When a kill is logged, the cache fills `class`/`race` if it has the victim. Otherwise they stay unknown.

### 2.3 Battleground wins

- On `UPDATE_BATTLEFIELD_STATUS`, when `GetBattlefieldWinner()` returns a value for the current battleground, compare
  it with the own faction and log `{ at, bgWin = true, mapId }` once per battleground instance.
- Everything is unmeasured on Forever (section 5). If it cannot be read, `bg_wins` missions are hidden from the
  admin form's goal list and existing ones show "Not available on this client".

### 2.4 Progress (pure: `Domain/PvPMissionTracker.lua`)

`Progress(mission, kills, now, claims)` returns `{ bars = { { label, done, total } }, unknown, complete, evidence,
periodKey }`:

- Filter by season dates, current period, zones, place.
- Apply the per-victim cap (D14): a victim counts at most `PVP_VICTIM_DAILY_CAP` (default 3) times per server day,
  across all missions (the cap is applied to the log, before any mission filter).
- `distinct`: count distinct names / classes / races. Kills with unknown class/race count as `unknown` and are
  listed in the evidence so the approver decides (D2).
- `complete` when every bar is full. For `class`/`race`, `unknown` kills do not fill the bar; the member can still
  claim when the known ones plus the unknown ones could complete it (the approver decides). Show the note
  "N kills without a known class" from the mockup.
- `manual`: no bars; always claimable with a note while the period limit allows.

---

## 3. Permissions

Add to `PermissionService` (role-based) and a new officer check:

| Action | admin | PvP officer | rl / council / member |
|---|---|---|---|
| `pvp_claim` | ✓ | ✓ | ✓ |
| `pvp_claim_decide` (approve = grant, reject) | ✓ | ✓ | |
| `pvp_delivery_mark` | ✓ | ✓ | |
| `pvp_grant_direct` (grant without a claim, manual missions) | ✓ | | |
| `pvp_grant_void` | ✓ | | |
| `pvp_season_manage` (create, edit dates, close) | ✓ | | |
| `pvp_mission_manage` | ✓ | | |
| `pvp_prize_manage` | ✓ | | |
| `pvp_officer_assign` | ✓ | | |

- Officer actions: `PermissionService.CanPvP(role, isOfficer, action)`. `isOfficer` comes from the receiver's
  officer records, never from the message.
- Trusted relays for PvP snapshot data: admin, raid leader, current PvP officer.
- Today the only admin is the Guild Master (`RANK_ROLES` + `BETA_ADMIN_NAMES`); nothing here changes that.

---

## 4. Sync

### 4.1 New message types

Add each to `Sync/Protocol.lua` (validator), `docs/PROTOCOL.md` (a new "PvP seasons" section) and tests in
`tests/protocol_spec.lua`.

| Type | Channel | Author allowed | Payload | Conflict rule |
|---|---|---|---|---|
| `PVP_SEASON` | GUILD | admin | season (1.1) | `SyncRules.Wins` by `rev`; refuse a second active season |
| `PVP_MISSION` | GUILD | admin | mission (1.2) | `SyncRules.Wins` |
| `PVP_PRIZES` | GUILD | admin | prizes (1.5) | `SyncRules.Wins`, whole replace |
| `PVP_OFFICER` | GUILD | admin | officer (1.6) | `SyncRules.Wins` |
| `PVP_CLAIM` | GUILD | anyone (player = sender) | claim (1.3) | same id: keep the first, ignore replays |
| `PVP_REJECT` | GUILD | admin, officer | reject (1.4) | per claim id, latest `at` wins; a grant beats a reject |
| `PVP_GRANT` | GUILD | admin, officer (direct: admin) | grant (1.4) | append-only by id; replays are no-ops |
| `PVP_VOID` | GUILD | admin | void (1.4) | append-only by grant id |
| `PVP_DELIVERY` | GUILD | admin, officer | delivery (1.5) | `SyncRules.Wins` per (season, player) |
| `PVP_FINAL` | GUILD | admin | final (1.7) | first valid one per season wins; authoritative |
| `PVP_LEDGER_REQ` | GUILD | anyone | `{ seasonId, count, digest }` | — |
| `PVP_LEDGER_DATA` | WHISPER | trusted relay | `{ seasonId, page, pages, items }` | each item applied as if its `by` had sent it (0.2) |

Validation highlights: text caps as listed in section 1; `points` 1..1000; `zones` ≤ 5 integers; evidence ≤
`PVP_CLAIM_EVIDENCE_MAX`; `class`/`race` must be upper-case file tokens (`^%u+$`, as `PROFILE` does for class);
`player` and `by` validated like character names; a claim's `player` must equal the sender.

### 4.2 Ledger catch-up (late joiners)

The ranking must be complete, so grants are not capped like `PVP_STATS` in `SYNC_DATA`. Use a separate exchange:

1. After login (same delay window as `SYNC_REQ`) and when a season becomes active, the client sends
   `PVP_LEDGER_REQ` with the active season id, the number of grants+voids it holds, and a digest (a stable hash
   of the sorted ids, e.g. an Adler-32 or FNV-1a string hash implemented in Lua and unit tested).
2. A trusted relay whose own count/digest differ, after a random 1–10 s delay and at most once a minute per
   requester, whispers `PVP_LEDGER_DATA` pages: season, missions, prizes, officers, then grants, voids, rejects,
   deliveries and every `PVP_FINAL`. Page size so each encoded page fits the snapshot limit; a test asserts it.
3. The requester decodes only if the whisper comes from a trusted relay (checked before decompression, as
   `Comm` does for snapshots) and applies every item through the same validation and authority rules.

Pending claims are **not** relayed: like loot candidates, they belong to their author, who re-announces them
(1.3).

### 4.3 Storage

```lua
db.global.pvpSeason = {
  seasons   = { [seasonId] = season },
  activeId  = seasonId | nil,
  missions  = { [missionId] = mission },
  prizes    = { [seasonId] = prizes },
  officers  = { [player] = officer },
  grants    = { [seasonId] = { [grantId] = grant } },
  voids     = { [grantId] = void },
  rejects   = { [claimId] = reject },
  queue     = { [claimId] = claim },          -- pending claims seen by this client (approvers display them)
  finals    = { [seasonId] = final },
  deliveries = { [seasonId] = { [player] = delivery } },
}
db.chars[key].pvpMissions = { seasonId, kills = {}, claims = { [claimId] = { claim, state } } }
```

Caps (constants, receiver side): `PVP_GRANTS_MAX` 3000 per season, `PVP_QUEUE_MAX` 300, `PVP_MISSIONS_MAX` 50 per
season, `PVP_FINALS_MAX` 50 seasons, `PVP_OFFICERS_MAX` 20. Over a cap, refuse new records (never evict grants).

---

## 5. Measurements on the Forever client

Add a section "PvP seasons (to be measured)" to `docs/API_NOTES.md` and extend `/nrage debug pvp` (Core/PvPProbe.lua)
to log these. Each phase lists the ones it needs; a failed measurement disables only that criterion, with the
UI saying "Not available on this client".

| # | Question | Needed by |
|---|---|---|
| M1 | Does `C_Map.GetBestMapForUnit("player")` return a stable uiMapId (not secret) in cities and contested zones? Record the ids for Orgrimmar, Stormwind, Ironforge, Darnassus, Thunder Bluff, Undercity, Stranglethorn Vale, Hillsbrad Foothills, Alterac Mountains, Ashenvale, Arathi Highlands | phase 2 |
| M2 | Does the kill feed produce a victim name for honour kills (issue #92, questions 2, 6, 7)? Multi-word or first word? | phase 2 |
| M3 | Do `UnitClass` / `UnitRace` on `target`, `mouseover` and `nameplateN` return readable file tokens for enemy players? Does `GetUnitName(unit, true)` match the feed's victim name? | phase 3 |
| M4 | Do `NAME_PLATE_UNIT_ADDED` and `UPDATE_MOUSEOVER_UNIT` fire for enemy players without triggering the "blocked action" dialog? | phase 3 |
| M5 | Does `GetBattlefieldWinner()` return the winner after a battleground, and does `UPDATE_BATTLEFIELD_STATUS` fire then? | phase 3 |

---

## 6. Phases

One PR per phase, each green on `busted`, `luacheck`, `stylua --check` and the coverage gate. Each phase updates
`docs/PROTOCOL.md`, `docs/USER_GUIDE.md` and `esES` for what it adds.

### P1. Ledger, seasons, officers, permissions (no UI)

- `Domain/PvPSeasonModel.lua`: shapes, validation helpers, `Standings`, tiers, tie-break, cumulative ranking,
  officer intervals (`IsOfficerAt`).
- `Domain/PvPSeasonService.lua`: local actions (create/edit/close season, missions, prizes, officers, grant, void,
  reject, delivery) with permission checks, producing payloads; closing builds the final (1.7) and runs the cleanup.
- `Sync/PvPSeasonSync.lua`: `Apply` for every message type of 4.1, ledger catch-up (4.2), digest.
- `Core/Store.lua` migration for 4.3; `Core/Constants.lua` constants; `PermissionService` actions (section 3).
- Wiring in `Sync/Comm.lua` and `Core/Init.lua`.
- Interim admin commands until P4 (Members-tab toggle and panel): `/nrage pvp officer add|remove <name>`,
  `/nrage pvp season ...` for testing. Remove or keep as debug in P4.
- **Tests:** `pvp_season_model_spec.lua` (standings, ties, voids, officer intervals, zero points), `pvp_season_service_spec.lua`,
  `pvp_season_sync_spec.lua` (authority per type, relayed `by` only inside ledger data from a trusted relay,
  duplicate grant id, grant beats reject, final is authoritative, caps, second active season refused, digest and paging).
- **Done when:** two fake clients converge to the same standings from any delivery order of the same records.

### P2. Automatic missions (zone, count, distinct names) and claims

- M1 and M2 are measured later in game. Implement guarded: without a victim name no kill is logged; without a
  map id, zone criteria never match.
- `Platform.GetPlayerMapId`; kill log (2.1) fed from `PvPFeed`; `Domain/PvPMissionTracker.lua` (2.4) for
  `kind = "kills"`, `distinct = "none" | "name"`, zones and place; per-victim cap.
- Claims: create, send, re-announce, local states (pending, approved, rejected); approver queue.
- `docs/PRIVACY.md` update (0.4).
- **Tests:** `pvp_mission_tracker_spec.lua` (zones, place, periods daily/weekly/once, distinct names, victim cap,
  season dates, unknown mapId), claim idempotency, largest claim fits a guild message.

### P3. Unit cache, class/race, battleground wins, manual missions

- M3–M5 are measured later in game. Implement everything guarded; an unavailable source disables only its
  criterion, with "Not available on this client" in the UI.
- `Domain/PvPUnitCache.lua` (2.2) and its event wiring; `distinct = "class" | "race" | "class_race"` with
  unknowns in evidence; `bg_wins` (2.3); `manual` missions with a note and direct admin grants.
- Constants `PVP_ENEMY_CLASSES` / `PVP_ENEMY_RACES` (file tokens).
- **Tests:** `pvp_unit_cache_spec.lua` (LRU, TTL, enemy-only, secret values ignored), tracker tests for class/race
  bars and unknowns, battleground win logged once per instance.

### P4. UI: Temporada, Misiones, Estadísticas, Histórico (structure), Admin

- Build on the merged redesign: extend `UI/Tabs/PvP.lua` with the `Kit` components (see the other `UI/Tabs/*`), and
  put the new ViewModel functions in a new `UI/ViewModelPvP.lua` (following `ViewModelGuild.lua`, `ViewModelRaid.lua`),
  registered in the `.toc` and `tests/embeds_spec.lua` if that spec lists files.
- Sub-tab strip (D16), remembering the last sub-tab for the session; the Admin sub-tab only for admins and PvP
  officers; officers see only Aprobaciones and Entregas.
- Temporada: season card (name, dates, days left, own position, own points, points to the 3rd place), prizes
  strip, ranking table (position colored gold `#E6BA66` / silver `#C0C6CF` / bronze `#C9A27E`, tier chip, own row
  with the accent wash, dashed divider after position 10, footer with tie and minimum rules), empty state when no
  season is active.
- Misiones: one card per active mission (title, description, points, criteria chips, progress bars, Reclamar /
  Reclamar con nota / status chip, unknown-class note), footer rules.
- Estadísticas: segmented "Mis estadísticas / Ranking de bajas" around the existing views; the kill-counter reset
  moves to Admin → Temporada as "Contadores de bajas".
- Admin: segmented Aprobaciones (count) · Misiones · Temporada · Recompensas · Entregas.
  - Aprobaciones: claim rows with "Ver pruebas" (evidence table, unknown class in amber), Rechazar, Aprobar.
  - Misiones: table (title, criteria, points, status, Editar), "+ Nueva misión", "Clonar de otra temporada", and
    the mission form (title, description, goal, count, points, zones, place, distinct, repetition, per player, status).
  - Temporada: name, start and end date pickers, Guardar, two-click "Cerrar temporada" with the pending-claims warning.
  - Recompensas: one row per tier with reward chips (remove), "+ Oro", "+ Objeto" (paste a link).
- Members tab (admin view): a "PVP" toggle next to each member's role dropdown; read-only views show an
  "OFICIAL PVP" badge.
- `UI/ViewModel.lua` functions returning rows/structures (not text lines), each with tests in `view_model_spec.lua`;
  extend `ui_smoke_spec.lua` to draw every PvP sub-tab as admin, officer, member and no-roster.

### P5. Season close, rewards, deliveries, history

- Close flow end to end (D6, D7): the final record, cleanup, delivery list.
- Admin → Entregas: rows (position, player, tier, reward, "Entregada · <who> · <date>" or "Marcar entregada").
- Histórico: "Por temporada" (podium cards with delivery progress, "Ver clasificación completa" listing the final
  standing) and "Acumulado" (1.8).
- **Tests:** close with pending claims (expired), ties at a tier boundary, a season where fewer than 10 players
  scored, a grant received after the final (ignored), deliveries converge.

---

## 7. Out of scope

- Spending points or a reward shop (D10).
- Sending gold or mail from the addon (D13).
- Weekly point caps per player (not requested; add later if abuse shows up).
- Seasons for the Horde side (the guild is Alliance; enemy class/race sets assume Horde enemies).

## 8. Decision log

| Date | Decision |
|---|---|
| 2026-10-20 | Missions with admin approval (also automatic ones); full detection scope including the class/race unit cache |
| 2026-10-20 | Manual seasons with start/end dates; global history; ranking resets each season |
| 2026-10-20 | Gold or item rewards defined in the PvP admin panel, given at season close to tiers 1, 2, 3, 4–6, 7–10 |
| 2026-10-20 | All UI inside the PvP tab as sub-tabs, redesign style; mockup updated (canvas version 22) |
| 2026-10-20 | Assignable PvP officer flag (approvals and deliveries only); mockup updated (version 23) |
| 2026-10-20 | Delivery in five phases (section 6) |

---

## 9. P1 API (implemented)

What phase P1 left for P2 to P5 to build on. The files: `Domain/PvPSeasonModel.lua` (`ns.PvPSeasonModel`, pure),
`Domain/PvPSeasonService.lua` (`ns.PvPSeasonService`, local actions and reads), `Sync/PvPSeasonSync.lua`
(`ns.PvPSeasonSync`, receiving and catch-up), `Commands/PvPSeasonCommands.lua` (the interim `/nrage pvp ...`).
At runtime the service of this client is **`ns.pvpSeason`** (created in `Core/Init.lua` once the addon is active).
The ledger it works on is `ns.db.global.pvpSeason` (section 4.3); the per-character log is `char.pvpMissions`
(`{ seasonId, kills = {}, claims = {} }`, created by the migration and `Store.GetChar`; P2 fills it).

**Conventions.** Every service action returns `record, queued` (the record it made; `queued` is false when it was
saved here but could not be sent) or `nil, reason`. Reasons: `"forbidden"`, `"invalid:<field>"`, `"no_season"`,
`"closed"`, `"not_found"`, `"decided"`, `"unknown_mission"`, `"unknown_player"`, `"self_grant"`, `"unchanged"`,
`"inactive"`, `"out_of_season"`, `"limit"`, `"active_exists"`, `"stale"`, plus `PvPSeasonSync.Apply`'s. A record's
author (`by`, `updatedBy`, `closedBy`) is never in a payload. Times are server time. Players are full roster names.

### `ns.PvPSeasonModel` (pure)

| Function | Notes |
|---|---|
| `PeriodKey(repeatKind, at)` | `"once"` -> `"all"`, `"daily"` -> `"YYYYMMDD"` (UTC), `"weekly"` -> `"YYYYWww"` (ISO week, UTC); nil for anything else. Also `DayKey(at)`, `WeekKey(at)`, `IsPeriodKey(key)` |
| `Contains(season, at)` | `startsAt <= at <= endsAt` |
| `ClaimId(player, missionId, periodKey, n)`, `ParseClaimId(id)` -> `{ player, missionId, periodKey, n }` or nil, `IsClaimId(id)` | the claim id of 1.3 |
| `ValidateSeason`, `ValidateMission`, `ValidateClaim`, `ValidateGrant`, `ValidateVoid`, `ValidateReject`, `ValidatePrizes`, `ValidateTiers`, `ValidateOfficer`, `ValidateDelivery`, `ValidateFinal` `(fields)` | `clean` or `nil, "invalid:<field>"`; the wire validators too. A claim's `evidence` rows: `{ at, victim, mapId?, place = "world" \| "bg", class?, race? }` or `{ at, bgWin = true, mapId? }`, at most `PVP_CLAIM_EVIDENCE_MAX` (60). `summary` keys: `done, total, classes, classesTotal, races, racesTotal, unknown` (integers) |
| `Standings(grants, voids, officers, roleOf, seasonId?)` | `{ pos, player, points, lastAt, tier }` best first (1.8); `grants` is a map or a list of grants carrying `by`, `roleOf(name) -> role \| nil` |
| `Cumulative(finals)` | `{ pos, player, points, seasons, podiums }` over a map or list of finals |
| `TierOf(position)`, `TierRange(tier)`, `IsTier(tier)` | tiers `"1"`, `"2"`, `"3"`, `"4-6"`, `"7-10"` |
| `IsOfficerAt(officer, at)`, `IsOfficer(officer)`, `ToggleIntervals(intervals, on, now, keepFrom?)` | officer intervals (both ends included) |
| `GrantCounts(grant, officers, roleOf)`, `VoidCounts(void, roleOf)` | does the author count (admin; officer at the time of the grant, for a claim approval, not for themselves) |
| `FitFinal(final, fits)`, `Digest(tokens)`, `IsPlayer(name)`, `CleanText(text)` | helpers |

`PermissionService.CanPvP(role, isOfficer, action)` and the actions of section 3 (`pvp_claim`, `pvp_claim_decide`,
`pvp_delivery_mark`, `pvp_grant_direct`, `pvp_grant_void`, `pvp_season_manage`, `pvp_mission_manage`,
`pvp_prize_manage`, `pvp_officer_assign`) are in `Domain/PermissionService.lua`.

### `ns.PvPSeasonService` (`ns.pvpSeason`)

Reads (never nil, empty lists when there is nothing):

- `ActiveSeason()`, `Season(id)`, `Seasons()` (newest first), `Mission(id)`, `Missions(seasonId, includePaused?)`
  (by title; paused ones only with `includePaused`), `Prizes(seasonId)` (`{ seasonId, tiers, ... }`; the frozen copy,
  with `closed = true`, once the season is closed).
- `Standings(seasonId?)` (default: the active season; the final standing for a closed one), `StandingOf(player?, seasonId?)`
  (the row or nil), `Grants(seasonId?)` (`{ id, player, missionId, missionTitle, points, at, by, counts, voided }`, newest
  first), `Queue()` (claims waiting, oldest first), `Rejected()` (claims an approver rejected, with `rejectedBy`,
  `rejectedAt`, `reason`), `ClaimState(claimId)` -> `"approved" \| "rejected" \| "pending" \| nil`.
- `Final(seasonId)`, `Finals()` (newest first), `Deliveries(seasonId)` (`{ pos, player, tier, rewards, delivered,
  updatedBy, updatedAt }`), `Cumulative()`, `Officers()` (`{ player, active, since }`).
- `IsOfficer(name)`, `CanPvP(action)` (the local player, officer flag included), `IsApprover()`.

Actions (each checks the permission, validates, applies to the own ledger and sends):

- `CreateSeason({ name, startsAt?, endsAt })`, `EditSeason(seasonId, { name?, startsAt?, endsAt? })`,
  `CloseSeason(seasonId?)` -> `final, expiredClaims, queued` (builds the final from the grants held, copies the prizes,
  deletes the detail, makes the deliveries, then sends `PVP_FINAL` and the closed season).
- `UpsertMission({ id?, title, desc?, points, goal = { kind, count?, zones?, place?, distinct? }, repeatKind, perPlayer?,
  active? })` (an `id` of a mission held edits it, keeping the fields not given), `SetMissionActive(missionId, active)`,
  `SetPrizes(seasonId, tiers)`, `SetOfficer(player, on)`.
- **For detection (P2/P3): `SubmitClaim({ missionId, at?, n?, summary?, evidence?, note? })`** -> `claim, queued`. The
  player is always the local one and the period key comes from the mission, so the claim id is `ClaimId(own, mission,
  period, n or 1)`; a manual mission needs a `note`. It sends `PVP_CLAIM` and, for an admin, keeps the claim in the own
  queue. The re-announcement (1.3) just calls it again with the same fields: the same claim is the same id.
- `ReceiveClaim(payload, sender)` (what `Comm` does for a received `PVP_CLAIM`: it only stores it on an approver),
  `Approve(claimId)` (a grant with the claim id and the mission's points), `Reject(claimId, reason?)`,
  `DirectGrant(player, missionId, points?)`, `Void(grantId, reason?)`, `MarkDelivery(seasonId, player, delivered)`.
- `PvPSeasonService.ClearMissionLog(char.pvpMissions, seasonId)` empties the per-character log of a closed season;
  `ns.PvPSeasonClosed(seasonId)` (Init) calls it, and is the place to hook the kill log and claim state of P2.

Hooks the interface can define: `ns.UI.PvPSeasonChanged(messageType)` (called when a season record changes here or
arrives; until it exists `ns.UI.PvPChanged()` is called instead).

### Messages (`ns.PvPSeasonSync`, `Comm`)

`PVP_SEASON`, `PVP_MISSION`, `PVP_PRIZES`, `PVP_OFFICER`, `PVP_CLAIM`, `PVP_REJECT`, `PVP_GRANT`, `PVP_VOID`,
`PVP_DELIVERY`, `PVP_FINAL`, `PVP_LEDGER_REQ`, `PVP_LEDGER_DATA`: see `docs/PROTOCOL.md` ("PvP seasons"). `Comm` routes
them (`HandlePvPSeason`, `HandleLedgerRequest`, whispers in `HandleWhisper`), `Comm:RequestLedger()` asks for the
catch-up (at login and when a season becomes active), `Comm:Fits(messageType, payload)` says whether a payload fits
one guild message. `PvPSeasonSync.Apply(ctx, message, by)` is the single entry point for a validated record, for the
guild channel and for a catch-up item alike.

### What differs from the text above

- `PVP_CLAIM_EVIDENCE_MAX` is 60 as planned: a test encodes the largest claim the validator allows (60 rows of 40-byte
  victim names) and it fits the 4096-byte guild message.
- A rejected claim stays in the queue (marked by its `PVP_REJECT`) so an approver can still approve it; `Queue()` hides
  it and `Rejected()` lists it. Rejected claims make room first when the queue is full.
- An officer cannot approve their own claim (an admin can); the receivers apply the same rule.
- The ledger digest also covers officers, seasons, finals and deliveries, not only grants and voids, so a difference in
  any of them triggers a catch-up. Missions and prizes are sent only for the requested and the relay's active season.
- A mission or prize record is still taken after the final of its season (it may reach a client late); grants, voids and
  rejections are not.

---

## 10. Detection API (P2 and P3, implemented)

What phases P2 and P3 left for the interface (P4, P5). The files: `Domain/PvPMissionTracker.lua`
(`ns.PvPMissionTracker`, pure), `Domain/PvPUnitCache.lua` (`ns.PvPUnitCache`), `Domain/PvPMissionService.lua`
(`ns.PvPMissionService`). At runtime the service of this client is **`ns.pvpMissions`**, created in `Core/Init.lua`
(`StartPvP`) after `ns.pvpSeason`; it is nil if the feature cannot start, so the interface checks it.

```lua
ns.pvpMissions:Progress(missionId)    -- -> { bars = { { label, done, total } }, unknown = n, complete = bool,
                                       --      claimable = bool, periodKey, evidence = {...} } or nil (unknown mission / no active season)
ns.pvpMissions:Claim(missionId, note) -- -> claim or nil, reason   (builds evidence + summary, calls ns.pvpSeason:SubmitClaim)
ns.pvpMissions:ClaimState(missionId)  -- -> "none" | "pending" | "approved" | "rejected"  for the current period
ns.pvpMissions:Availability()         -- -> { kills = bool, zones = bool, classRace = bool, bgWins = bool }
```

- `bars[i].label` is an English key: `"Kills"`, `"Distinct players"`, `"Classes"`, `"Races"`, `"Victories"`. Show it with
  `ns.PvPMissionTracker.LabelText(label)` (it holds the `L()` calls, so a UI that passes `bar.label` to `L` itself would
  not get the Spanish text checked by `locale_spec`). `ns.PvPMissionTracker.ZoneName(mapId)` gives the translated name of
  a zone of `PVP_MISSION_ZONES` (nil for other ids).
- `Progress` also returns `couldComplete` (the unknown kills could fill the bars: the claim is allowed and the approver
  decides) and `nextN` (the number of the claim the next `Claim` would make). `unknown` counts the kills with an unknown
  class or race (for `class_race`, a kill missing either); show "N kills without a known class" when it is above 0.
  `claimable` is true when the mission is active, the season is running (inside its dates), the period still has a free
  claim (`nextN <= perPlayer`) and the bars are full or `couldComplete`. A manual mission has no bars, `complete` is
  true, and it is claimable while the period has room; `Claim` then needs a note.
- `evidence` rows are the ones `SubmitClaim` sends (`{ at, victim, mapId?, place, class?, race? }` or
  `{ at, bgWin = true, mapId? }`), at most `PVP_CLAIM_EVIDENCE_MAX`, in time order. A row without `class`/`race` is
  unknown (amber in the approver's table).
- `Claim` reasons: `"unknown_mission"`, `"no_season"`, `"inactive"`, `"limit"` (the period has no free claim),
  `"not_complete"`, plus those of `SubmitClaim` (`"invalid:note"`, `"out_of_season"`, ...). On success the second
  value is `queued` (false: saved here, not sent yet). The claim is kept in `char.pvpMissions.claims[claim.id] =
  { claim, state }`; a claim already sent is announced again after the login send delay and every
  `PVP_CLAIM_REANNOUNCE_SECONDS` while any is pending.
- `ClaimState` looks at the claims of the current period of the mission and gives the best state (approved, then
  pending, then rejected). The state follows the ledger: a received grant (`ClaimState` of `ns.pvpSeason`) makes it
  approved, a received rejection rejected, otherwise it stays pending.
- `Availability()`: `kills` = the kill feed has a victim name; `zones` = `GetBestMapForUnit` is readable right now;
  `classRace` = at least one of the unit events could be registered; `bgWins` = `GetBattlefieldWinner` exists and its
  event could be registered. A mission whose source is false shows "Not available on this client" (the criteria: zones
  need `zones`, `distinct = class|race|class_race` needs `classRace`, `bg_wins` needs `bgWins`, everything but `manual`
  needs `kills`).
- Whenever the log, a claim or a claim state changes, the service calls `ns.UI.PvPChanged()` (only if it exists, and
  that function is already throttled to one redraw per `PVP_REDRAW_SECONDS`). Decisions that arrive from the guild
  reach the interface through `ns.PvPSeasonChanged` as before.

### How it works

- **Kill log.** `PvPFeed` calls `deps.onHonorKill(entry)` once per own honour kill (also when the killing blow came
  first; a blow without honour never does). The service appends `{ at, victim, mapId, place, class?, race? }` to
  `char.pvpMissions.kills` while a season is active and the kill time is inside its dates; `at` is the server time of
  the feed entry, `mapId` is `Platform.GetPlayerMapId()` at that moment (nil when unreadable), `class`/`race` come from
  the unit cache. A battleground win is `{ at, bgWin = true, mapId }` in the same list. The log is capped at
  `PVP_MISSION_KILLS_MAX`, oldest dropped first, and belongs to one season (`char.pvpMissions.seasonId`): a record for
  another season starts a new log, and `ns.PvPSeasonClosed` empties it.
- **Unit cache.** `PLAYER_TARGET_CHANGED`, `UPDATE_MOUSEOVER_UNIT` and `NAME_PLATE_UNIT_ADDED` call
  `Platform.GetEnemyPlayerInfo(unit)` (enemy players only; name from `GetUnitName(unit, true)`, class and race as
  upper-case file tokens) and store it in memory (`PVP_UNIT_CACHE_MAX`, `PVP_UNIT_CACHE_TTL`). Each event is registered
  in `pcall`; the combat log stays disabled.
- **Battleground wins.** On `UPDATE_BATTLEFIELD_STATUS`, inside a battleground, when `Platform.GetBattlegroundWinner()`
  equals the own faction, a win is logged once; `PLAYER_ENTERING_WORLD` re-arms it, and a win already logged less than
  `PVP_BG_WIN_DEDUPE_SECONDS` ago (a reload inside the same battleground) is not logged again.
- **Cap and filters** are the order of 2.4: the per-victim cap first (3 per victim per UTC day, case-insensitive),
  then season dates, current period, kind, place and zones.

### What differs from the text above

- `PVP_ENEMY_CLASSES` has the eight Horde classes of Classic (no Paladin) and `PVP_ENEMY_RACES` the four races (Orc,
  Scourge, Tauren, Troll), upper-cased file tokens; change the lists in `Core/Constants.lua` if Forever has other Horde
  classes or races. The `uiMapId`s of `PVP_MISSION_ZONES` are the Classic ones and still **to be measured** (M1).
- A claim for the n-th place of a period (`perPlayer > 1`) is checked against the same period progress, not against
  n times the count: the approver sees the earlier claim in the queue. A rejected claim uses its place in the period.
- No change to `Core/Store.lua`: the claim table `char.pvpMissions.claims` and the kill list already exist from the
  schema-12 migration.
- `/nrage pvp claim` now goes through `ns.pvpMissions:Claim` (so it carries the evidence); without the service it
  falls back to `SubmitClaim`.
