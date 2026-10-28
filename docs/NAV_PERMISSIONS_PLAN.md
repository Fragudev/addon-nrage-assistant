# Navigation and permissions plan

Plan for the agents that implement the change (Haiku for mechanical slices, Sonnet for logic and sync). Every item is
**decided** unless marked **open** (waiting on the product owner) or **default** (the planner's choice; change it here
if the owner disagrees). Do not implement anything marked **open**.

**Status:** approved by the owner (2026-10-28). Ready for implementation, phase by phase.

Scope:

- Reorganise the sidebar into two groups: **Guild** and **Admin**.
- Replace the addon roles (member, rl, council, admin) with the guild ranks.
- Make readiness rules and Members management per roster.
- Hide (not delete) Profile and Blacklist; fold Layers and the profile header into Home.
- Move the current Raid tab to Admin; add a read-only "upcoming events" Raid tab to Guild.

## 0. Principles

### 0.1 Hide, do not delete

"Disappears for now" means the tab leaves `ViewModel.TABS`. Its file, domain services, sync handlers and SavedVariables
stay untouched so it can come back with a one-line change. Background behaviour (blacklist watcher, layer publisher,
profile publishing) keeps running.

### 0.2 Rules inherited from the addon

- The role of a sender is always computed by the receiver from its own guild roster, never read from a message.
- Every permission is checked twice: in the UI (what is shown) and in the domain/sync layer (what is accepted). UI
  gating alone is never enough.
- English is the key for every string (`L("...")`), Spanish goes to `Locales/esES.lua`.
- Roles and other compared or sent values are never translated.

## 1. Ranks (replaces the role model)

### 1.1 Rank → role

The addon role is the guild rank. Seven roles, in order of authority:

| Order | Role id   | Guild rank (es) |
|-------|-----------|-----------------|
| 0     | `gm`      | GM              |
| 1     | `cogm`    | CoGM            |
| 2     | `officer` | Oficial         |
| 3     | `rl`      | RL              |
| 4     | `roster`  | Roster          |
| 5     | `member`  | Miembro         |
| 6     | `alter`   | Alter           |

- `Constants.ROLE_SOURCE` goes back to `"rank"`. `ASSIGNABLE_ROLES` and the Role dropdown in Members are removed: the
  role is changed in the game, not in the addon.
- The rank maps to the role **by name**, through `Constants.RANK_ROLES` (`PermissionService.RoleForRank`, which already
  lowercases). The in-game rank names are exactly `GM`, `CoGM`, `Oficial`, `RL`, `Roster`, `Miembro`, `Alter`:

  ```lua
  RANK_ROLES = {
    gm = "gm", cogm = "cogm", oficial = "officer", rl = "rl",
    roster = "roster", miembro = "member", alter = "alter",
  },
  ```

  The name is trimmed before the lookup. An unknown rank falls back to `alter` (least privilege; today it falls back
  to `member`). Renaming a rank in game without updating this table demotes everyone in it to `alter`: note it in
  `docs/USER_GUIDE.md`.
- The guild master stays `gm` regardless of the mapping (rank index 0 / `IsGuildLeader()`), as today.
- `council` disappears as a role. The PvP officer flag disappears (see 4.5).

### 1.2 Roster scope

The roster stays an addon assignment (`db.global.members[key].rosterId`, one roster per player). The rank says
*what* a player can do, the roster says *where*. Helpers in `Domain/PermissionService.lua`:

- `Rank(role)` → order number from the table above, for `AtLeast(role, "rl")`-style checks.
- `IsGlobal(role)` → `gm` or `cogm` (sees and acts on every roster, can pick the roster in a selector).
- `Scope(role, ownRosterId)` → `"all"` | `"own"` | `"none"`.

### 1.3 Action matrix

Replaces `ACTIONS` in `PermissionService.lua`. `own` = only on the player's own roster; hidden when the player has no
roster.

| Action                 | gm/cogm | officer   | rl        | roster    | member | alter |
|------------------------|---------|-----------|-----------|-----------|--------|-------|
| `admin_view` (group)   | yes     | yes       | yes       | no        | no     | no    |
| `raidcheck_view`       | all     | own       | own       | own       | no     | no    |
| `loot_view`            | all     | own       | own       | own (read)| no     | no    |
| `loot_manage`          | all     | own       | own       | no        | no     | no    |
| `loot_apply`           | all     | own       | own       | own       | no     | no    |
| `events_view`          | all     | own       | own       | own       | no     | no    |
| `event_signup`         | all     | own       | own       | own       | no     | no    |
| `raid_manage`          | all     | own       | own       | no        | no     | no    |
| `members_view`         | all     | all       | own       | no        | no     | no    |
| `members_manage`       | all     | no        | own       | no        | no     | no    |
| `rules_view`           | all     | all       | own       | no        | no     | no    |
| `rules_edit`           | all     | no        | own       | no        | no     | no    |
| `pvp_admin`            | yes     | no        | no        | no        | no     | no    |
| member-level actions   | yes     | yes       | yes       | yes       | yes    | yes   |

Member-level actions (`edit_own_profile`, `layer_share`, `position_share`, `pvp_publish`, `pvp_claim`,
`recipes_publish`, `blacklist_add`) stay open to every rank. `loot_apply` is no longer one of them.

- `events_view` `own` also includes guild-wide events (`rosterId` nil), as `RosterService.Viewer` does today. A
  player of rank officer/rl/roster without a roster does not see the tab (same rule as Raid check).
- `raid_manage` covers today's `manage_events`, `record_attendance`,
  `manage_assignments` and templates; officer gets the same as rl, mirroring Loot.
- Officer sees Members and Roster rules for every roster, with the roster selector, read-only (Q3).
- `loot_manage` = open a session, vote and award. gm/cogm on any roster, officer/rl on their own; `roster` reads only
  (Q4). Replaces `loot_open`, `loot_vote`, `loot_award`.
- `loot_apply` (put yourself forward as a candidate) is ranks `roster` and above, on the event's roster, and only
  through the loot popup (`UI/LootPopup.lua`). Member and alter never get the popup and never appear as candidates
  (Q5).

## 2. Navigation

### 2.1 Groups and tabs

`ViewModel.TABS` / `ViewModel.NavGroups(role)` (`UI/ViewModel.lua:1031-1060, 1246-1265`). The unlabeled "me" group goes
away.

**Guild**

| Tab id        | Label        | Visible to                           |
|---------------|--------------|--------------------------------------|
| `home`        | Home         | everyone                             |
| `professions` | Professions  | everyone                             |
| `events`      | Raid         | `events_view` (scope not `none`)     |
| `ready`       | Raid check   | `raidcheck_view` (scope not `none`)  |
| `loot`        | Loot         | `loot_view` (scope not `none`)       |
| `pvp`         | PvP          | everyone (without the Admin sub-tab) |

**Admin** (whole group hidden without `admin_view`)

| Tab id     | Label        | Visible to       |
|------------|--------------|------------------|
| `raid`     | Raid         | `raid_manage`    |
| `rules`    | Roster rules | `rules_view`     |
| `roster`   | Members      | `members_view`   |
| `pvpadmin` | PvP          | `pvp_admin`      |

- Tab ids `ready`, `raid`, `rules`, `roster` keep their ids (only the label or group changes) so redraw hooks in
  `UI/Main.lua:135-232` and deep links keep working. `pvpadmin` and `events` are new: add their redraw hooks next to
  `pvp` and `raid` (events redraw on the same event-sync triggers as `raid`).
- Both groups have a tab labelled "Raid" (and "PvP"); the group header disambiguates. Ids stay distinct.
- Hidden: `profile`, `layers`, `blacklist`.
- `ViewModel.TabsFor(role, rosterId)` becomes the single gate. If the current tab stops being visible (rank changed,
  roster removed), fall back to `home`.
- If an old deep link opens a hidden tab (`UI.OpenTab("profile")`, etc.) or a tab the rank cannot see, it goes to `home`. Grep every `OpenTab(` and
  `SelectTab(` caller and repoint links to hidden tabs (e.g. Profile's "link to professions", Home cards that open Raid, which now point to `events` for everyone and `raid` only with `raid_manage`).

### 2.2 Roster selector

Shared Kit control used by Raid check, Loot, Raid (admin), Roster rules and Members: shown when the tab's view action
has scope `all` for the role (gm/cogm everywhere; officer on Members and Roster rules); otherwise the roster is fixed to
the player's own and shown as a label. The selector chooses what is **shown**; what can be **changed** still follows the
edit action's scope (officer picks any roster on Members/Roster rules but edits none). Default selection for gm/cogm: own roster if any, else the
first roster by name. Kept per tab in `UI.nav` (not persisted).

## 3. Guild group

### 3.1 Home

Order, top to bottom:

1. **Identity card** — the current Profile identity `StatGrid` (`ViewModel.IdentityStats`: name, class, level, item
   level). Moved, not copied: `Profile.lua` keeps calling the same view model.
2. **Specs card** — Main spec and Second spec dropdowns (today `Profile.lua:44-66`, `ProfileService.SetField` +
   `PublishService.PublishIfChanged`). Extract the card builder to a shared function so Profile can reuse it when it
   comes back.
3. **Layers** — the content of `UI/Tabs/Layers.lua` (own layer, guild directory, swap) as a section. Extract its draw
   body into a function that takes a parent; the `layers` tab is removed from `TABS`.
Nothing else. The current Home cards (readiness, sync status, next raid event, open loot sessions;
`UI/Tabs/Home.lua`, `UI/ViewModelHome.lua`) are removed from Home. Keep their view-model functions: Events
(3.4) reuses the next-event code; delete only what ends up with no caller.

Lost with Profile hidden: professions summary, main character, local notes, "Shared with the guild". **default** Not
moved to Home; they come back with Profile.

### 3.2 Raid check (was Readiness / Preparación)

- Label "Raid check" (es: decide in esES, **default** "Raid check").
- Rules come from the selected roster: `ReadinessRules.Current(rosterId)` (see 5.1).
- gm/cogm: roster selector, evaluates the player's own character against the selected roster's rules. officer, rl,
  roster: their own roster, no selector.
- Personal only for every rank, as today: no roster overview (Q7).

### 3.3 Loot

Unchanged behaviour (loot council), plus the scopes from 1.3 and the roster selector. `roster` rank renders read-only:
no open-session form, no vote, no award, and no apply row (`applyRow`, `UI/Tabs/Loot.lua:141, 311`). A roster player
applies only from the popup.

#### 3.3.1 Loot popup gating

`ViewModel.PendingLoot(events, actor, dismissed)` (`UI/ViewModel.lua:775`) does not look at the role today. It takes
the role and the actor's roster and returns nothing unless `loot_apply` allows it for the event's roster, so the popup
never opens for member/alter or for another roster's session. The receiver also rejects an apply from them
(`Sync/LootSync.lua` apply handler: `loot_apply` + `MayAct`), and `LootService.Apply` checks the same.

Loot sessions stay inside raid events (`event.loot`, `Domain/LootService.lua:1-12`); events are created in the Admin
Raid tab (4.0), so nothing changes in the model.

### 3.4 Raid (informative, `events`)

New file `UI/Tabs/Events.lua`. List of upcoming events the player can see (`RosterService.OwnViewer` +
`FilterEvents`), sorted by date, past events excluded. Everything is read-only except the player's own sign-up. No
links into the Admin Raid tab.

- **default** Each row: date and time, title, roster name (or "Guild"), sign-up count, and the player's own sign-up
  control (Sign up / Not going). Empty state: "No upcoming events".

#### 3.4.1 Self sign-up (new)

There is no self sign-up today: `event.attendance` (`Domain/EventModel.lua:9-18`) is recorded only by leaders
(`record_attendance`). Sign-up is the player's **intent**; attendance stays the leader's **record** of what happened.
They are kept apart so a player can never overwrite attendance.

- Store: `event.signups[characterKey] = {status, rev, updatedAt}`, `status` in `{"yes", "no"}`. No entry = not
  answered. Limit: reuse `EVENT_ATTENDANCE_MAX`.
- Domain: `EventService.SetSignup(ctx, eventId, status)` signs up **the actor's own character only** (no
  `characterKey` argument). Requires `event_signup` and the event visible to the actor's roster.
- **default** Open while the event status is `planned` or `open` and its start time has not passed; then locked.
- Sync: new `SIGNUP_UPSERT` in `Sync/EventSync.lua`. The receiver accepts it only when the payload's `characterKey` is
  the sender itself, the sender's rank (receiver's roster) has `event_signup`, and the event is visible to the sender's
  roster. Last-writer-wins per character (`SyncRules.Wins`). Snapshot carries signups. Protocol bump in
  `docs/PROTOCOL.md`; old clients ignore the message.
- Admin Raid tab: the Details/Attendance sub-tab shows each player's sign-up next to the attendance state, read-only.
  **default** Leaders do not edit sign-ups.
- **default** Reuse the view-model code the Home "next raid event" card already uses (`UI/ViewModelHome.lua`) instead of
  writing a second filter.

### 3.5 Professions

Unchanged.

### 3.6 PvP

Unchanged except the "Admin" sub-tab leaves `ViewModel.PvPSubTabs` (`UI/ViewModelPvP.lua:22-34`) and moves to 4.3.

## 4. Admin group

### 4.0 Raid (management, `raid`)

The current `UI/Tabs/Raid.lua` as it is (summary, details, attendance, assignments, templates, reports), moved to the
Admin group. Its existing roster selector (`Raid.lua:133, 319`) switches to the shared selector of 2.2 and the
`raid_manage` scope: gm/cogm any roster, officer/rl own roster only.

### 4.1 Roster rules (was Rules)

Per-roster readiness rule editor. Same editor UI as today (`UI/Tabs/Rules.lua`), operating on the selected roster's
list.

- gm/cogm: selector, full edit on any roster.
- rl: own roster, full edit.
- officer: every roster through the selector, read-only (controls disabled, not hidden).
- Existing rosters start with a copy of the current global list (migration, 5.1); new rosters start with
  `Constants.DEFAULT_RULES` (Q8).

### 4.2 Members

Same table as today minus the Role dropdown (rank comes from the game) and minus the PvP officer flag.

- gm/cogm: everything (create/rename/delete rosters, assign any player to any roster or none).
- officer: every roster through the selector, read-only.
- **default** rl sees its own roster plus players without a roster (it needs them to add anyone); no selector.
- rl: assign a player **to its own roster** and remove a player **from its own roster**. Cannot touch rosters
  themselves, cannot move a player who is already in another roster.
- **default** The rank column shows the guild rank as read from the roster (not editable).

### 4.3 PvP (admin)

The current `adminView` of `UI/Tabs/PvP.lua:1576` (approvals, missions, season, prizes, deliveries, moderate reset)
moves to a new tab file `UI/Tabs/PvPAdmin.lua`. Only gm/cogm. Extract, do not rewrite: move the functions and their
locals; PvP.lua keeps the player views.

### 4.5 PvP officer flag

With PvP admin restricted to gm/cogm, the officer flag (`pvp_officer_assign`, `CanPvP`, `pvpSeason.officers`) has no
user left. **default** Remove the UI and the `CanPvP` extension; leave the stored data and its sync handler accepting
nothing (no protocol bump needed). Flag it in the decisions log if the owner wants officers back.

## 5. Data and sync

### 5.1 Per-roster readiness rules

- New store key: `db.global.readinessRulesByRoster[rosterId] = {rev, updatedAt, updatedBy, rules}`. Old
  `db.global.readinessRules` kept read-only for the migration, then ignored.
- Store migration (next schema version in `Core/Store.lua`): copy the global record into every existing roster.
- `ReadinessRules.Current(rosterId)` → that roster's rules, `DEFAULT_RULES` when missing, `{}` when `rosterId` is nil.
- `Sync/ReadinessRulesSync.lua`: message carries `rosterId`. Accept when the sender is gm/cogm, or rl and the sender's
  roster (from the receiver's records) equals `rosterId`. Last-writer-wins per roster (`SyncRules.Wins`). Snapshot
  carries every roster's record. Roster deletion tombstones its rules.
- Protocol bump in `docs/PROTOCOL.md`; old clients must ignore the new message, new clients ignore the old global one.

### 5.2 Member assignment by RL

`Sync/RosterSync.lua` member upsert/delete today require `roster_manage` (admin). New rule, checked on the receiver:

- gm/cogm: accept anything.
- rl: accept only if the sender's roster (receiver's records) is the target roster **and** the player's previous
  roster is either none or that same roster. Roster create/rename/delete stay gm/cogm.
- Same check in `RosterService.Assign/Unassign` and `Commands/RosterCommands.lua`.

### 5.3 Role-dependent sync elsewhere

Every `Can(role, …)` caller listed in the mapping (EventService, LootService, BlacklistService, TemplateService,
PvPSeasonService, Comm.lua, Transfer.lua, VotingFrame) must be re-pointed to the new actions. Map:

| Old action                    | New                                   |
|-------------------------------|---------------------------------------|
| `roster_manage`               | `members_manage` (+ scope for rl)     |
| `roster_view_all`             | `IsGlobal(role)`                      |
| `rules_edit`                  | `rules_edit` (+ scope for rl)         |
| `loot_open/vote/award`        | `loot_manage` (+ scope)               |
| `loot_apply` (was everyone)   | `loot_apply` (roster and above, + scope) |
| `manage_events` and raid ones | `raid_manage` (+ scope)               |
| `moderate`, `blacklist_remove`, `blacklist_edit_any`, `pvp_*` admin | gm/cogm |

## 6. Files

| File | Change |
|------|--------|
| `Core/Constants.lua` | `ROLE_SOURCE="rank"`, new role table, drop `ASSIGNABLE_ROLES` |
| `Domain/PermissionService.lua` | new roles, ACTIONS, `Rank`, `IsGlobal`, `Scope`; drop `CanPvP` officer extension |
| `Domain/RosterService.lua` | rl-scoped Assign/Unassign, `MayAct` for new roles |
| `Domain/ReadinessRules.lua` | `Current(rosterId)` |
| `Core/Store.lua` | migration to per-roster rules |
| `Sync/ReadinessRulesSync.lua`, `Sync/RosterSync.lua`, `Sync/Comm.lua` | scoped authorization |
| `UI/ViewModel.lua`, `UI/ViewModelHome.lua`, `UI/ViewModelPvP.lua` | TABS, groups, TabsFor, PvPSubTabs, PendingLoot gating |
| `UI/Main.lua` | redraw hook for `pvpadmin`, fallback to home |
| `UI/Tabs/Home.lua` | identity, specs, layers |
| `UI/Tabs/Profile.lua`, `UI/Tabs/Layers.lua` | extract reusable builders |
| `UI/Tabs/Readiness.lua`, `Loot.lua`, `Rules.lua`, `Members.lua` | selector + scopes |
| `UI/Tabs/PvP.lua` → `UI/Tabs/PvPAdmin.lua` | move admin view |
| `UI/Tabs/Raid.lua` | shared selector + `raid_manage` scope |
| `UI/Tabs/Events.lua` (new) | upcoming events + own sign-up |
| `Domain/EventModel.lua`, `Domain/EventService.lua`, `Sync/EventSync.lua` | sign-ups (3.4.1) |
| `NrageAssistant.toc` | add `PvPAdmin.lua`, `Events.lua` |
| `Locales/esES.lua` | new labels |
| `docs/PROTOCOL.md`, `docs/USER_GUIDE.md` | protocol and guide |

## 7. Tests

- `tests/permission_service_spec.lua`: full matrix of 1.3, one case per cell, including "no roster → none".
- `tests/roster_service_spec.lua`, `tests/roster_sync_spec.lua`: rl assigns to own roster, rl rejected on other roster,
  rl rejected moving a player out of another roster, officer rejected.
- `tests/readiness_rules_spec.lua` + new `readiness_rules_sync_spec` cases: per-roster storage, rl scope, migration.
- `tests/store_spec.lua`: migration copies the global list.
- `tests/event_service_spec.lua`, `tests/event_sync_spec.lua` (or the existing event specs): own sign-up accepted;
  sign-up for another character rejected; member/alter rejected; other roster rejected; locked after start.
- Loot specs: member/alter apply rejected in service and sync; roster applies on own roster only; `PendingLoot` empty
  for member/alter and for another roster's session.
- `tests/view_model_spec.lua`: `TabsFor`/`NavGroups` per rank and with/without roster; Admin group hidden for
  roster/member/alter.
- `tests/ui_smoke_spec.lua`: update `ALL_TABS` and the file load list; draw every tab for every rank.
- `tests/support/roles.lua`: fakes for the seven ranks.
- `locale_spec` keeps passing.

## 8. Phases

Each phase is one PR, CI green before the next.

1. **Ranks** (Sonnet): Constants, PermissionService, every `Can` caller, tests. No UI change beyond removing the Role
   dropdown.
2. **Navigation** (Haiku): TABS, groups, TabsFor, hidden tabs, deep-link fallbacks, PvP admin extraction to
   `PvPAdmin.lua`, Raid moved to Admin, new `Events.lua` list (no sign-up yet), smoke tests.
3. **Home** (Haiku): identity, specs, layers; remove the old cards.
4. **Per-roster rules** (Sonnet): store, migration, sync, Roster rules tab, Raid check reads by roster.
5. **Members by RL** (Sonnet): scoped assignment in domain and sync, Members UI.
6. **Event sign-up** (Sonnet): 3.4.1 model, service, sync, Events and Admin Raid UI.
7. **Loot and Raid scopes** (Sonnet): shared selector, read-only Loot for `roster`, `raid_manage` scope.

## 9. Open questions

None. Q1–Q8 are answered in the decisions log.

## 10. Decisions log

- 2026-10-28: sidebar split into Guild and Admin; Profile, Raid, Blacklist hidden; Layers and profile header move to
  Home; Readiness renamed Raid check; Rules renamed Roster rules and made per roster; Members and PvP admin move to
  Admin; roles become the seven guild ranks (owner).
- 2026-10-28 (Q1): current Raid tab moves to Admin; Guild gets a read-only Raid tab listing upcoming events. Loot keeps
  living inside events (owner).
- 2026-10-28 (Q1 follow-up): the Guild Raid tab lets a player sign up or not; everything else read-only. Only
  gm/cogm/officer/rl/roster see it (owner).
- 2026-10-28 (Q2): rank → role by name; names GM, CoGM, Oficial, RL, Roster, Miembro, Alter (owner).
- 2026-10-28 (Q3): officer sees Members and Roster rules for every roster with the selector, read-only (owner).
- 2026-10-28 (Q4): gm/cogm/officer/rl open, vote and award loot within their scope; roster reads only (owner).
- 2026-10-28 (Q5): only ranks roster and above can apply for loot, and a roster player only through the popup; the
  Loot tab is read-only for them (owner).
- 2026-10-28 (Q6): Home shows only identity, specs and layers; the old cards go (owner).
- 2026-10-28 (Q7): Raid check stays personal for every rank (owner).
- 2026-10-28 (Q8): existing rosters copy the global rules; new rosters start with `DEFAULT_RULES` (owner).
