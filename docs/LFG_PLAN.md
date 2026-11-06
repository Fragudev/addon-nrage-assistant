# LFG plan

Implementation plan for **Groups**: a guild-only board where members post a party for a dungeon, a quest or anything
else, others apply with a role, and the leader invites them with a click.

This document is written for the implementing agents and must be executable without the conversation that produced
it. **Decided** items were agreed with the addon owner. **Default** items are proposals to implement as written, open
to review.

**Status:** implemented on branch `feat/lfg`, cut from `main` after `feat/pvp-intel` merged, for v1.2.0. In-game checks pending (section 10).
Section 12 corrects this plan against the code Intel left; where they differ, section 12 wins.

## Quick path

1. **P0:** measure the invite on the Forever client. This gates everything else (section 1).
2. **P1 to P3:** model and protocol, then the flow, then the wiring. All testable with fakes.
3. **P4:** the Groups tab and the popup.
4. **P5:** documentation and the in-game checklist (section 10).

## Decided and default choices

| Topic | Choice | Status |
|---|---|---|
| Audience | Guild members running the addon only; no public channel, no other guilds | decided |
| Group type | Parties of up to 5; raids stay in Events | decided |
| Persistence | None: posts live in memory, with republication and a time to live | decided |
| Invite | Always a button the leader clicks, never automatic | decided |
| Transport | The `NRAGE` prefix on `GUILD`, live only, like `LAYER_SWAP` | decided |
| Activity | A kind (`dungeon`, `quest`, `other`) plus a free text title; no dungeon catalogue in this version | default |
| Posts per member | One open post per sender; a new one replaces the old | default |
| Applications | One active application per member at a time | default |
| Applications are public | They travel on `GUILD`, so any addon user could read them | default |
| Who may post | Anyone not in a group, or the leader of a party with a free slot | default |
| Settings | None, so `SCHEMA_VERSION` does not change | default |

**Out of scope:** raids, a dungeon catalogue, level ranges per instance, announcing a post in guild chat, automatic
invites, saved history, and any use of `C_LFGList` or a native group finder.

---

## 0. Principles

### 0.1 Rules inherited from the addon

- Client APIs only through `NrageAssistant/Core/Platform.lua`, each guarded for a missing API, an error and a secret
  value. A value that cannot be read is **unknown**, never guessed.
- Domain logic is pure and injected (`New(deps)` with `now`, `schedule`, `send`...). Frames stay thin. Tests use fakes.
  The coverage gate stays at 80 %.
- Every received byte is hostile: strict validation, size caps, plain text only, unknown fields dropped.
  **The sender comes from the client, never from the payload.** Authority comes from the receiver's own guild roster.
- Nothing is sent during the encounter lockdown. These messages are live only: refused, never queued.
- Everything runs only while `ns.active`.
- Every user-facing string goes through `L()` with an `esES` entry in the same change. Debug output stays English.
- New `.lua` files go in `NrageAssistant/NrageAssistant.toc` in dependency order.
- Commits use conventional commits with no AI attribution.

### 0.2 Limits to state honestly in the UI and docs

- Only members running the addon see the board.
- A post disappears from the board up to `LFG_POST_TTL` after its leader logs out or reloads.
- A member who logs in sees existing posts at their next republication, up to `LFG_REPUBLISH_SECONDS` later.

---

## 1. P0: measure the invite (gate)

The flow is useless if the leader cannot invite. Two clients, one of them a character with a **multi-word name**.
Record each answer in `docs/API_NOTES.md`.

| # | Question | How to measure |
|---|---|---|
| 1 | Does `Platform.InviteByName` invite the right character for a multi-word name? (API_NOTES layer question 5) | The invite button of the layer swap popup; its result is in the layer probe log |
| 2 | Does it work with the `sender` of `CHAT_MSG_ADDON` as delivered? | `/nrage debug senders`, then invite that exact string |
| 3 | Does it need a hardware event? | The button click must work; note whether a timer-driven call fails |
| 4 | Do `IsGroupLeader`, `GetGroupSize`, `IsGroupMember` and `GROUP_ROSTER_UPDATE` behave as assumed? (layer question 8) | Form and leave a party with `/nrage debug layer status` and the probe log |

**If question 1 or 2 fails, stop and report to the owner.** The fallback to discuss is a prefilled whisper through
`Platform.PrefillChat`, which is also unmeasured (API_NOTES, the "Ask" button).

---

## 2. How it works

```text
Leader                                   Applicant
Post()        --LFG_POST open-->         sees the post on the board
                                         Apply(role)
popup         <--LFG_APPLY apply--
Invite() (click)
              --LFG_APPLY accept-->      "invited" state
game invite                              accepts the game prompt
GROUP_ROSTER_UPDATE: member joined
needs[role] - 1
              --LFG_POST open, rev+1-->  (or closed `full` when no need is left)
```

### 2.1 Post states

| Event | Result |
|---|---|
| Leader closes it | `closed`, outcome `cancelled` |
| No need left, or the party reaches `LFG_PARTY_SIZE` | `closed`, outcome `full` |
| The poster stops being leader, or the party disbands after someone joined | `closed`, outcome `cancelled` |
| The party becomes a raid | `closed`, outcome `cancelled` |
| Older than `LFG_POST_MAX_AGE` | `closed`, outcome `expired` |
| Nothing received for `LFG_POST_TTL` (receiver side) | dropped from the board |

### 2.2 Application states (one client, one active application)

`applied` -> `invited` -> `joined`. It ends as `declined`, `withdrawn` or `expired`.

| Step | Timeout | On timeout |
|---|---|---|
| `applied` | `LFG_APPLY_TIMEOUT` | `expired`; the applicant may apply again |
| `invited` | `LFG_INVITE_TIMEOUT` | `expired`; the leader's row returns to a retry state |

An application also ends when its post closes or disappears.

### 2.3 Eligibility (a `deps.eligibility` rule, computed in `Init.lua` from Platform)

| Action | Refused when | Reason |
|---|---|---|
| Post | Locked; in a raid; in a group and not leader; party full; no need declared | `locked`, `raid`, `not_leader`, `full`, `no_needs` |
| Apply | Locked; already in a group; own post open; level known and below `minLevel`; role not needed; another application active; layer swap active | `locked`, `in_group`, `own_post`, `level`, `role`, `busy`, `swap` |
| Invite | Locked; not leader while in a group; party full; in combat | `locked`, `not_leader`, `full`, `combat` |

An unknown level does not refuse: the leader sees the applicant and decides.

### 2.4 Interaction with the layer swap

`LayerSwap` treats a group join as progress of the swap (`onJoined`), so a group formed through this board during a
swap would be read as the swap's group.

- The two flows exclude each other: Apply and Post refuse while `LayerSwap:Status()` is active and not final, and the
  swap eligibility in `Init.lua` refuses while an application or an open post is active (reason `lfg`).
- Joining a party may move the member to the leader's layer. Say so in the user guide; the addon does nothing about it.

---

## 3. Domain

### 3.1 `Domain/LfgModel.lua`: pure rules

Kinds and roles, `NewPost`, `RemainingNeeds`, `IsFull`, and the payload builders. Wire roles are `tank`, `heal` and
`dps`, converted from the profile through `ProfileService.NormalizeRole`. Needs plus current members can never exceed
`LFG_PARTY_SIZE`.

### 3.2 `Domain/LfgBoard.lua`: received posts

Modelled on `LayerDirectory`. In memory, keyed by the sender's `Validate.NameKey`, at most `LFG_BOARD_MAX` posts.

- Applying a post: a higher `rev` replaces, an equal `rev` only refreshes `lastSeen`, a lower `rev` is dropped.
- A different `pid` from the same sender replaces the old post.
- The receiver stamps `lastSeen` with its own clock. No timestamp is trusted from the payload.
- A `closed` post stays as a tombstone until `LFG_POST_TTL`, hidden from the board, so a late `open` with a lower
  `rev` cannot revive it.
- A sender the local roster does not know is refused when the roster is ready, as in `LayerDirectory`.
- `Query({ kind, role })` returns open posts, newest first.

### 3.3 `Domain/LfgService.lua`: the flow

One state machine per client covering both sides, modelled on `LayerSwap`.

```lua
-- deps = { now, schedule, send = { post, apply }, isLocked, ownName, newId, ownLevel,
--          eligibility = { post, apply, invite }, invite = function(name) -> ok, reason,
--          isGroupMember = function(name) -> boolean, groupSize = function() -> number,
--          isLeader = function() -> boolean, board = LfgBoard, onChange = function() (optional) }
```

| Method | Side | Notes |
|---|---|---|
| `Post(fields)`, `Update(fields)`, `Close()` | Leader | Own messages are never received, so each also applies the post to the board |
| `Invite(applicant)` | Leader | Called only from a button; sends `accept`, then calls `deps.invite` |
| `Decline(applicant)` | Leader | Sends `decline` |
| `Apply(pid, role, note)`, `Withdraw()` | Applicant | |
| `OnPost(sender, payload)`, `OnApply(sender, payload)` | Both | From `LfgSync` |
| `OnGroupChanged()` | Both | Detects joins, leader loss and disband |
| `Republish()` | Leader | Same `rev`, fresh message id, every `LFG_REPUBLISH_SECONDS` |
| `Status()` | Both | What the tab and the popup show |

Authority, always against the sender:

- `apply` and `withdraw` act only for the sender, and only on a post this client owns.
- `accept` and `decline` count only when the sender is the owner of `pid` on the local board **and** `to` is this client.
- At most `LFG_APPLICANTS_MAX` pending applicants per post; more are dropped. A repeated `apply` refreshes the row.

A `/reload` loses the post and the application. That is accepted: the time to live clears them on other clients.

---

## 4. Protocol

Minor **11** (`main` is at 10, from the Guild KOS messages). `MAJOR` does not change: an older client drops these as `unknown_type`.

| Type | Channel | Payload | Who may send it |
|---|---|---|---|
| `LFG_POST` | guild | `pid`, `rev`, `s` (`open` or `closed`); when open: `kind`, `title` (1 to 60), `needs{tank, heal, dps}` (0 to 4 each), `members` (1 to 4), optional `minLevel`, optional `note` (up to 100); when closed: `o` (`full`, `cancelled` or `expired`) | anyone; the owner is the sender |
| `LFG_APPLY` | guild | `pid`, `s` (`apply`, `withdraw`, `accept` or `decline`); `apply`: `role`, optional `note` (up to 100); `accept` and `decline`: `to` | anyone; the actor is the sender |

Validators go in `Sync/Protocol.lua` next to `validateLayerSwap`, using `isId`, `isInt`, `isText` (`Validate.Text`) and
`EventModel.IsCharacterKey` for `to`. An open post with no need above 0 is invalid.

`Sync/LfgSync.lua` copies the shape of `Sync/LayerSync.lua`: `IsLfgMessage`, `Apply(ctx, message, sender, role)`, and
`authorize(role, "lfg_use")`.

`Sync/Comm.lua`:

- `HandleLfg(sender, message)`, dispatched next to `HandleLayer`.
- `SendLfgPost(payload)` and `SendLfgApply(payload)`, refusing with `"locked"` like `SendLayerSwap`.
- `lfgService` and `onLfgChange`, set by `Init.StartLfg`, because the service is created after Comm.

`Domain/PermissionService.lua`: `lfg_use = EVERYONE`.

### Constants (default values)

| Constant | Value | Meaning |
|---|---|---|
| `LFG_PARTY_SIZE` | 5 | Maximum party |
| `LFG_REPUBLISH_SECONDS` | 120 | Leader resends an open post |
| `LFG_POST_TTL` | 360 | Three missed republications |
| `LFG_POST_MAX_AGE` | 3600 | A post closes itself after an hour |
| `LFG_BOARD_MAX` | 50 | Posts kept |
| `LFG_APPLICANTS_MAX` | 10 | Pending per post |
| `LFG_APPLY_TIMEOUT` | 120 | Waiting for the leader |
| `LFG_INVITE_TIMEOUT` | 60 | Waiting for the join |
| `LFG_LEVEL_MAX` | 100 | Upper bound of `minLevel` validation only |
| `LFG_REDRAW_SECONDS` | 1 | Throttle of `UI.LfgChanged` |

Load: one small message per open post every two minutes, well inside the general inbox limit of 60 per sender per
minute. No new inbox limit is needed.

---

## 5. Client wiring

`Core/Init.lua` gets `StartLfg`, modelled on `StartLayer` and added to the startup table after `layer`:

- Builds `LfgBoard` and `LfgService`, and injects them into `ns.comm`.
- Registers `GROUP_ROSTER_UPDATE` and `PLAYER_ENTERING_WORLD` with `platform.TryRegisterEvent`, calling `OnGroupChanged`.
- Runs the republication timer and a board sweep, only while `ns.active`.
- Adds the exclusion of section 2.4 to the swap eligibility.

No new Platform function should be needed: `InviteByName`, `IsGroupLeader`, `IsInGroup`, `IsInRaid`, `GetGroupSize`,
`IsGroupMember`, `GetLevel` and the lockdown check already exist.

---

## 6. UI

Follow `docs/NRAGE_STYLE_GUIDE.md` and use the kit. Frames only build what the ViewModel returns.

### 6.1 Groups tab: `UI/Tabs/Groups.lua`, `UI/ViewModelGroups.lua`

Add `{ value = "groups", text = L("Groups"), icon = "users", group = "guild" }` to `ViewModel.TABS`, after `pvp`. It
stays out of `TAB_ACTIONS`, so everyone sees it, and the sidebar and the minimap menu pick it up from `TabsFor`.

| Area | Content |
|---|---|
| Header | "New group" button, or the own post with Edit and Close |
| Filters | Kind and role, kept in `UI.nav` for the session |
| Board | Title, kind, leader, roles needed, members, minimum level, note, age, and an Apply button with its refusal reason |
| Own application | State, time left and Withdraw |
| Applicants (leader) | Name, role, note, Invite and Decline |
| Empty state | Plain text saying only addon users appear |

All received text goes through `ViewModel.Escape`.

Add `UI.LfgChanged = throttledRedraw(...)` in `UI/Main.lua`, redrawing `groups` and `home`.

**Members indicator:** each post and the own post show five diamonds, filled for the current members. Use the kit's
`diamond` icon, `accent` for a member and a dim token for a free slot, with a text alternative in the tooltip
("3 of 5 members").

**Sidebar counter:** the Groups entry shows the number of open groups on its right, own post included, and nothing
when it is 0. The sidebar has no badge today, so:

- `Kit/Shell.lua`: add an optional `badge` text to the nav items (`{ value, text, icon, badge }`) and a way to update
  it without rebuilding the sidebar.
- `ViewModel.NavGroups`: takes the open count and sets `badge` on the `groups` item.
- `UI.LfgChanged` also refreshes the badge, on every tab.
- Other nav items have no badge and must look exactly as they do now.

### 6.2 Popup: `UI/LfgPopup.lua`

Modelled on `UI/LayerPopup.lua`, with its `Controller` kept apart from the frame so it can be tested with fakes.

- Leader: a new applicant, with Invite and Decline.
- Applicant: accepted or declined, as a short notice.
- It never appears during a lockdown; it retries like the layer popup.

### 6.3 Home (optional, last)

A card with the number of open groups that links to the tab.

---

## 7. Files

| File | Change |
|---|---|
| `Domain/LfgModel.lua`, `LfgBoard.lua`, `LfgService.lua` | New |
| `Sync/LfgSync.lua` | New |
| `UI/ViewModelGroups.lua`, `UI/Tabs/Groups.lua`, `UI/LfgPopup.lua` | New |
| `Core/Constants.lua` | `LFG_*`, `PROTOCOL_MINOR` |
| `Core/Init.lua` | `StartLfg`, swap exclusion |
| `Sync/Protocol.lua`, `Sync/Comm.lua` | Validators, handler, senders |
| `Domain/PermissionService.lua` | `lfg_use` |
| `UI/ViewModel.lua`, `UI/Main.lua`, `UI/ViewModelHome.lua` | Tab, redraw, sidebar count, optional card |
| `UI/Kit/Shell.lua` | Optional `badge` on nav items |
| `Locales/esES.lua` | Every new string |
| `NrageAssistant.toc` | Domain files after `IntelDetector`, `LfgSync` before `Transfer`, `ViewModelGroups` after `ViewModelLayers`, the tab after `Layers`, the popup after `LayerPopup` |
| `docs/PROTOCOL.md`, `USER_GUIDE.md`, `API_NOTES.md`, `PRIVACY.md`, `CURSEFORGE_DESCRIPTION.md`, `README.md` | Section 9, phase P5 |

---

## 8. Tests

| Spec | Must cover |
|---|---|
| `lfg_model_spec` | Needs limits, `IsFull`, role conversion |
| `lfg_board_spec` | `rev` ordering, refresh, replacement by a new `pid`, tombstones, time to live, the cap, unknown sender, filters |
| `lfg_service_spec` | Each state and timeout; every eligibility refusal; forged `accept` from a non-owner; `accept` for another client; `apply` on a post this client does not own; a `send` that fails; a post closed while applied; swap exclusion |
| `lfg_sync_spec` | Routing and `lfg_use` |
| `protocol_spec` | Valid and invalid payloads of both types, `\|` and control characters, oversized text, unknown fields dropped, open post with no needs |
| `view_model_groups_spec` | Rows, refusal reasons, escaping, leader and applicant views, members diamonds, `NavGroups` badge (a count, and none at 0) |
| `lfg_popup_spec` | Controller: lockdown retry, no duplicate popups |
| `constants_spec` | Protocol minor |

---

## 9. Phases

One commit per work unit, tests with the code. Each phase ends with lint and the full test suite passing.

| Phase | Work | Done when |
|---|---|---|
| **P0** | Section 1, in game | `API_NOTES.md` has the answers; the owner confirms going on |
| **P1** | `LfgModel`, constants, protocol validators, permission | Model and protocol specs pass |
| **P2** | `LfgBoard`, `LfgService` | Board and service specs pass, against fakes only |
| **P3** | `LfgSync`, Comm, `StartLfg`, swap exclusion, TOC | Addon loads; two clients exchange a post |
| **P4** | ViewModel, tab, popup, `esES`, optional Home card | Full flow works from the UI |
| **P5** | `PROTOCOL.md` (types and minor), `USER_GUIDE.md` (section 0.2 limits, layer note), `API_NOTES.md`, `PRIVACY.md` (what is shared), CurseForge description in English, README | Section 10 checked |

---

## 10. In-game checklist

Three clients where possible, one with a multi-word name.

- [ ] A post reaches the other clients and shows the right roles.
- [ ] Someone logging in sees it within `LFG_REPUBLISH_SECONDS`.
- [ ] Apply shows the popup; Invite sends the game invite to the right character.
- [ ] A joined applicant lowers the need; the last one closes the post as `full`.
- [ ] Decline, Withdraw and both timeouts behave as in section 2.
- [ ] Leader logout: the post leaves the board within `LFG_POST_TTL`.
- [ ] Losing the leader, disbanding and converting to raid close the post.
- [ ] During an encounter lockdown nothing is sent, the buttons say why, and popups wait.
- [ ] A layer swap and an application cannot run at once.
- [ ] A client on an older protocol minor ignores the messages without errors.

---

## 11. Decisions log

| Date | Decision |
|---|---|
| 2026-11-06 | Scope agreed with the owner: guild-only board, parties of 5, in memory, leader clicks to invite, on the `GUILD` channel. |
| 2026-11-06 | Start after `feat/pvp-intel` merges. |
| 2026-11-06 | The owner approved the look in the canvas (artboard "Grupos (LFG)", https://claude.ai/artifact/U4aUo3uAXjK3jL4zpTi2eR), including the sidebar counter and the members diamonds. |
| 2026-11-06 | The owner asked to implement and release as v1.2.0. P0 was not run first: the invite stays unmeasured in `API_NOTES.md` and is the first item to check in game. |
| 2026-11-06 | Implemented for v1.2.0; in-game checks pending, section 10 not ticked. The code differs from this plan in these ways: the Groups filters are kept in `UI/Tabs/Groups.lua` for the session, not in `UI.nav`; `LFG_SWEEP_SECONDS` (15) and `LFG_POPUP_RETRY_SECONDS` (5) were added; the service also exposes `CanPost`, `CanApply`, `CanInvite`, `IsLocked`, `IsBusy`, `Sweep` and `Dismiss`. |
| 2026-11-06 | `Invite` calls the game first and sends `accept` only after the game accepted (section 3.3 gave the reverse order). A refused invite therefore tells the applicant nothing. |

---

## 12. Corrections after Intel

Checked against `main` after PR #168. Intel changed neither the sidebar, the tab list nor the envelope dispatch.

| Topic | What to do |
|---|---|
| Minor pins | `tests/protocol_spec.lua` and `tests/roster_sync_spec.lua` pin the minor, not `constants_spec`. Update both to 11 |
| `docs/PROTOCOL.md` | Says "currently 9" and stops at minor 9. Fix the number and describe minors 10 and 11 |
| Intel messages | They use their own prefix and receiver. `HandleLayer` stays the model, not Intel |
| Inbox | LFG messages share the 60 per minute budget of all envelope traffic. No new limit |
| Permissions | Add `lfg_use` to the `MATRIX` in `tests/permission_service_spec.lua` |
| Startup | The table is `ACTIVATION_STEPS` in `Init.lua`. Add `{ name = "lfg", run = StartLfg }` after `intel`, with a once-guard as in `StartLayer` |
| Lockdown | `isLocked` is `not ns.lockdown:CanSend()`, as in `StartLayer` |
| Events | `StartLfg` uses its own frame. Do not add logic to `layerFrame` |
| Swap exclusion | The rules are in `LayerSwap.Eligibility` (`Domain/LayerSwap.lua`), not `Init.lua`. Wrap `requester` and `helper` in `StartLayer` with a late-bound check of `ns.lfgService`, which starts later |
| Swap active | `FINAL` is local to `LayerSwap.lua`. Add a small public helper instead of comparing stage strings elsewhere |
| Roles | `ProfileService.NormalizeRole` returns `Tank`, `Heal`, `Dps`, or nil. `LfgModel` maps them to the wire roles |
| Names | `Validate.NameKey` keeps a realm suffix. Comm already normalizes the sender. `LfgBoard` takes an optional `isMember` as `LayerDirectory` does |
| Own level | `Platform.GetLevel` is unguarded. The `ownLevel` dep must use `pcall` and accept only a plain number |
| Sidebar | `Kit.Sidebar` passes fields to `Kit.NavRow`, also used by `VotingFrame.lua`. The badge is optional there. The refresh must run on every tab, so it cannot depend on the `shown()` of `throttledRedraw` |
| Tab tests | `tests/view_model_spec.lua` (tab set, order, the `vm.TABS[8]` index) and `tests/ui_smoke_spec.lua` (`ALL_TABS`, its loader list) |
| TOC | Domain `Lfg*` after `IntelMinimapTooltip`; `LfgSync` after `IntelSync`; `ViewModelGroups` after `ViewModelIntel`; `Tabs\Groups` after `Tabs\Layers`; `LfgPopup` after `LayerPopup` |
