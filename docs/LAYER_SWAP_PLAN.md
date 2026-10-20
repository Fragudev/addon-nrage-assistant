# Layer swap plan

Implementation plan for a layer feature: each client detects its own layer, shares it with the guild, and a
member can ask to be moved to another layer by a guildmate who is on it. This document is written for the
implementing agent. Items marked **default** were not discussed explicitly and are open to review; items marked
**decided** were agreed with the guild officer who owns the addon.

**Status:** implemented in P0-P4 on branch `feature/layer-swap` (2026-10-20), built on the assumptions of section 1.1
without the in-game measurement; see the decisions log. Everything unmeasured is listed in `docs/API_NOTES.md`.

- Scope: detection + guild directory + swap request flow (decided 2026-10-20).
- Nothing about layering has been measured on the Forever client. Phase P0's measurement was meant to gate everything
  else; on 2026-10-20 it was decided to build P1-P4 first, so it is now a **must-verify-in-game before release**
  (section 9). If the layer cannot be read from creature GUIDs on Forever, the feature has to be removed.

---

## 0. Principles

### 0.1 How a swap works in game (assumed, measured in P0)

On a layered realm, a player who joins a group is moved to the layer of the group leader after a short delay, as
long as they are out of combat and not in an instance. Layer hopping has a cooldown. The addon never moves anyone
itself: it only finds a helper, lets the helper invite with a click, detects that the move happened and offers a
button to leave the group.

### 0.2 Rules inherited from the addon

- Client APIs only through `NrageAssistant/Core/Platform.lua`, each guarded for missing, error and secret value.
- Live-only messages, like `PVP_KILL`: never queued during the encounter lockdown, never saved, never part of the
  `SYNC_DATA` snapshot.
- Everything runs only while `ns.active` (access guard passed).
- Every user-facing string through `L()` with an `esES` entry in the same change; debug output stays English.
- Domain logic is pure and injected (`New(deps)`); frames are thin. Coverage gate stays at 80 %.
- Every action that invites or leaves a group is a **button the user clicks** (decided 2026-10-20), so it works
  even if those APIs need a hardware event on Forever.

### 0.3 Privacy (default)

The layer is coarse location data. It is kept in memory only, shared with the guild only, expires after
`LAYER_STATE_TTL`, and a **"Share my layer"** setting (on by default) stops publishing it. When sharing is off the
member can still request a swap (the request carries the target layer, not the current one). `docs/PRIVACY.md`
gets a section.

---

## 1. Layer detection

### 1.1 Where the layer comes from (to be measured in P0)

Creature GUIDs have the form `Creature-0-<serverId>-<instanceId>-<zoneUid>-<npcId>-<spawnUid>` (also `Vehicle-`).
On layered Classic realms `zoneUid` identifies the layer **within one continent**; `instanceId` is the map. So the
layer key is the pair `(instanceId, zoneUid)`; layers of different continents are never compared.

Readings come from `UnitGUID` on `target`, `mouseover` and `nameplateN`, on the events `PLAYER_TARGET_CHANGED`,
`UPDATE_MOUSEOVER_UNIT` and `NAME_PLATE_UNIT_ADDED`. Rejected readings: non-creature GUIDs (players, pets have
`Pet-`), secret or unreadable values, any reading while in an instance or battleground.

P0 must answer, and record in `docs/API_NOTES.md`:

1. Does `UnitGUID` on those units return a readable creature GUID on Forever, outside combat? In combat?
2. Is `zoneUid` stable for one layer and different between layers (two members on different layers compare)?
3. Does `zoneUid` change after a realm restart (expected: yes, hence the TTL)?
4. After joining a group led by someone on another layer: is the move automatic, how long does it take, is there a
   cooldown, and what blocks it (combat, instance)?
5. `C_PartyInfo.InviteUnit` / `InviteUnit` with a **multi-word name** (`Yonemon Gg`) and with the `sender` of
   `CHAT_MSG_ADDON`: does it invite the right character? Does it need a hardware event?
6. `C_PartyInfo.LeaveParty` / `LeaveParty`: available? Needs a hardware event?
7. Are `NAME_PLATE_UNIT_ADDED` and `nameplateN` units available and readable?

If question 1 or 2 fails, the feature cannot work (the code treats an unreadable GUID as "layer unknown").

### 1.2 Own layer: `LayerTracker` (`Domain/LayerTracker.lua`)

- Pure, `New(deps)` with `now`, `isInInstance`, `onChange`.
- `:Observe(guid)` parses through `LayerModel.Parse` and keeps the last readings.
- A new layer is **confirmed** after `LAYER_CONFIRM_READINGS` (default 2) readings with the same key from
  **different `spawnUid`s**, so one stale or odd NPC does not flip it.
- `:Current()` returns `{ map, layer, confirmedAt }` or nil. It goes to nil when entering an instance or after
  `LAYER_STATE_TTL` without readings.
- `:ResetSince(t)` drops readings older than `t`. The swap flow calls it when the group is joined, so only readings
  taken after the move count.
- `onChange(current)` fires only on a confirmed change.

### 1.3 Pure helpers: `LayerModel` (`Domain/LayerModel.lua`)

- `Parse(guid)` returns `{ kind, map, layer, npcId, spawnUid }` or nil, for `Creature`/`Vehicle` only. Never raises
  (the value may be secret: compare inside `pcall`).
- `Key(map, layer)`, `SameLayer(a, b)`, `Describe(map, layer)` (display label, see 4.1).

---

## 2. Guild directory: `LayerDirectory` (`Domain/LayerDirectory.lua`)

- Pure, `New(deps)` with `now`, `isMember(name)`.
- `:Apply(sender, state)` stores `{ map, layer, at }` per member, replacing the older one.
- `:Remove(sender)` when a member stops sharing.
- `:Groups(map)` returns the layers of a continent, each with its fresh members (younger than
  `LAYER_STATE_TTL`), sorted by member count. Members who left the guild roster are dropped.
- `:MembersOn(map, layer)` for the swap flow.
- In memory only.

Publishing (in `Init.lua`): on `LayerTracker.onChange`, and again every `LAYER_REPUBLISH_SECONDS` (default 300)
while the layer is known, so newcomers learn it. It is throttled to one message every `LAYER_PUBLISH_MIN_SECONDS`
(default 30, queue key `LY`). Turning sharing off sends one `LAYER_STATE` with `layer = 0` (meaning "forget me").

---

## 3. Swap flow: `LayerSwap` (`Domain/LayerSwap.lua`)

One pure state machine per client. It runs both sides, with injected `now`, `schedule`, `send`, `isLocked`,
`ownName`, `ownLayer`, `eligibility` and `onChange`. A client takes part in at most one swap at a time.

### 3.1 Flow (decided 2026-10-20: the request targets a layer, first helper wins)

| Step | Who | What | Message |
|---|---|---|---|
| 1 | Requester | picks a target layer in the Layers tab, clicks "Request swap" | `LAYER_SWAP stage=request {rid, map, layer}` |
| 2 | Every eligible member on that layer | gets a popup "*X* wants to join your layer", clicks "Help" | `LAYER_SWAP stage=offer {rid}` |
| 3 | Requester's client | takes the **first** offer received and announces it; later offers are ignored | `LAYER_SWAP stage=assign {rid, helper}` |
| 4 | Everyone else | popup closes ("someone else is helping") | — |
| 5 | Assigned helper | popup shows "Invite *X*", click invites | — (game invite) |
| 6 | Requester | accepts the normal game invite; the addon calls `LayerTracker:ResetSince(joinTime)` and shows "Target or mouse over any NPC to confirm the move" | — |
| 7 | Requester | when the confirmed layer equals the target: popup "Layer changed", button "Leave group" (decided 2026-10-20: never automatic) | `LAYER_SWAP stage=close {rid, outcome=done}` |

The requester is the only arbiter, so two helpers clicking at the same time cannot both invite.

### 3.2 Closing (default timeouts)

- No offer within `LAYER_REQUEST_TIMEOUT` (60 s): `close outcome=expired`; the requester sees "Nobody on that layer
  answered".
- Assigned, but no group joined within `LAYER_ASSIGN_TIMEOUT` (90 s): `close outcome=expired`.
- Joined, but no confirmed target layer within `LAYER_CONFIRM_TIMEOUT` (120 s): the popup says "Could not confirm
  the move" and still offers "Leave group"; `close outcome=unconfirmed`.
- Requester clicks "Cancel" at any step: `close outcome=cancelled`.
- A helper who closes the popup only stops showing it. If an assigned helper declines, the requester gets
  `close outcome=declined` from the helper and may request again.
- Every client also drops a swap after `LAYER_SWAP_MAX_AGE` (300 s) without messages, in case a `close` is lost.

### 3.3 Eligibility (default; `eligibility` dep, computed in `Init.lua` from Platform)

- **Requester:** not in a group, not in an instance or battleground, not in combat, not locked down. Its own layer
  must be known and different from the target, or unknown.
- **Helper:** layer confirmed and fresh, on the requested `(map, layer)`; not in an instance, not in combat, not
  locked down. Either not in a group, or group leader of a party (not a raid) with a free slot. The popup is only
  shown to helpers who are eligible when the request arrives; "Invite" re-checks.

### 3.4 Lockdown

Sends are live-only: during the lockdown `send` returns `false, "locked"`. The requester cannot request (button
disabled with a reason). An open popup waits and retries like the loot popup Controller (`RETRY_SECONDS`).

---

## 4. UI

### 4.1 Layers tab (decided 2026-10-20)

New tab `layers` in `ViewModel.TABS` (after `pvp`), `DrawLayers` in `UI/Main.lua`, all roles. The minimap menu
picks it up through `TABS`.

Content, built by a tested `ViewModel.LayersView(state)`:

- **Your layer:** label + continent, or "Unknown: target or mouse over any NPC". "In an instance" when relevant.
- **Share my layer** checkbox.
- **Layers on this continent:** one row per layer with the label, member count and names, plus a "Request swap"
  button. Your own layer has no button. Disabled buttons show the reason (in a group, in combat, a swap already
  running, locked down).
- **Current swap:** stage and a "Cancel" button, if one is running.

Label (default): `zoneUid` values are not readable as "layer 1/2/3", so the label is `#` plus the last 4 digits of
`zoneUid`. Your own layer is marked "(you)".

`UI.LayersChanged()` redraws the tab when it is open, with a debounce like `UI.PvPChanged`.

### 4.2 Swap popup: `UI/LayerPopup.lua`

Same split as `UI/LootPopup.lua`: a pure `Controller.New(deps)` that turns `LayerSwap` state into one view
(title, text, buttons, countdown), and a thin AceGUI frame. It is placed with `ns.UI.ApplyWindowStatus(frame,
"layerPopup", w, h)`. The same popup serves both sides:

| State | Requester sees | Helper sees |
|---|---|---|
| request | "Looking for someone on #1234…" [Cancel] | "*X* wants to join your layer" [Help] [Ignore] |
| assign | "*H* will invite you" [Cancel] | (assigned) "Invite *X*" [Invite] [Decline]; (others) closes |
| joined | "Target or mouse over any NPC to confirm" [Leave group] [Cancel] | closes on `close` |
| done | "Layer changed" [Leave group] | — |

A sound and a `RaidNotice_AddMessage` when a helper popup opens (reuse the blacklist alert helpers).

### 4.3 Redesign

Add a `3.N Layers (NEW tab)` entry to `docs/REDESIGN_PLAN.md` and a row for `LayerPopup` in its section 4, so the
redesign rebuilds the frames and keeps the Controller and ViewModel. Also update the mockup canvas in the same
change.

---

## 5. Protocol (`docs/PROTOCOL.md`)

`PROTOCOL_MINOR` 4 → 5. Older clients drop both types with `unknown_type`. GUILD channel only (the whisper path
stays `SYNC_DATA`-only). Permission action `layer_share` for every role in `PermissionService.ACTIONS`.

| Type | Payload | Notes |
|---|---|---|
| `LAYER_STATE` | `{ map: int 0..9999, layer: int 0..2^31-1 }` | `layer = 0` means "forget me". Queue key `LY`. |
| `LAYER_SWAP` | `{ rid: id, s: "request"\|"offer"\|"assign"\|"close", map?, layer?, helper?: name, o?: "done"\|"expired"\|"cancelled"\|"declined"\|"unconfirmed" }` | `rid` is made by the requester (`ownName` + server time + counter). Only the requester of `rid` may send `assign` and `close` (except `close o=declined` from the assigned helper), checked against the stored request's sender. `helper` is validated like a character name. |

Both are validated in `Sync/Protocol.lua` (`VALIDATORS`) and dispatched in `Comm:HandleMessage` to a new
`Sync/LayerSync.lua`. That file has `IsLayerMessage`, `Apply(ctx, message, sender, role)` and the payload
builders, and is modelled on `PvPSync`. The rate limit is the existing per-sender inbox limit. The names in the
payload are never trusted for identity: the actor is always the `sender`.

---

## 6. Debug probe: `/nrage debug layer start|stop|status|log|clear`

`Core/LayerProbe.lua`, same shape as `Core/PvPProbe.lua` (it reuses `PvPProbeLog` if it is generic enough,
otherwise a `LayerProbeLog`). While running it logs every GUID read (raw string and parsed fields), zone changes,
group events and the tracker's confirmed layer. `status` prints the current layer and the readings. It also logs
the result of calling the invite and leave APIs when the panel buttons are used. It is the tool for P0; add it to
the usage string in `Slash.lua` and to `ViewModel.HelpLines()`.

---

## 7. Files

| File | Change |
|---|---|
| `Core/Constants.lua` | `PROTOCOL_MINOR = 5`, `LAYER_*` constants above |
| `Core/Platform.lua` | `GetUnitGUID(unit)`, `InviteByName(name)`, `LeaveGroup()`, `IsGroupLeader()`, `IsInCombat()`, `GetNumGroupMembers` if missing; each guarded |
| `Core/LayerProbe.lua` (+ log) | new, TOC after `PvPProbe` |
| `Domain/LayerModel.lua`, `LayerTracker.lua`, `LayerDirectory.lua`, `LayerSwap.lua` | new, TOC after `BlacklistWatcher` |
| `Domain/PermissionService.lua` | action `layer_share` |
| `Sync/Protocol.lua`, `Sync/LayerSync.lua`, `Sync/Comm.lua` | validators, new sync module (TOC before `Transfer`), dispatch, `SendLayerState`, `SendLayerSwap`, callbacks |
| `Core/Init.lua` | `StartLayer()` from `Activate()`, guarded by a `layerStarted` flag: frame, events through `TryRegisterEvent`, wiring of the four domain objects, publishing ticker |
| `Core/Store.lua` | `settings.layer.share = true` default; bump `SCHEMA_VERSION` with a migration step only if settings defaults need one (check how `settings.minimap` is defaulted) |
| `UI/ViewModel.lua`, `UI/Main.lua`, `UI/LayerPopup.lua` | tab, view, popup (TOC after `LootPopup`) |
| `Commands/Slash.lua` | `debug layer` |
| `Locales/esES.lua` | every new `L()` string |
| `.luacheckrc` | new globals in `read_globals` |
| `NrageAssistant.toc` | new files in the places above |
| `docs/PROTOCOL.md`, `PRIVACY.md`, `API_NOTES.md`, `USER_GUIDE.md`, `REDESIGN_PLAN.md`, `README.md` | sections and rows |

---

## 8. Tests

- `tests/layer_model_spec.lua`: parse creature, vehicle, player, pet, malformed, nil and secret-like (raising)
  values.
- `tests/layer_tracker_spec.lua`: confirmation needs two distinct spawns; one odd reading does not flip; instance
  clears; TTL; `ResetSince`.
- `tests/layer_directory_spec.lua`: apply, replace, forget (`layer = 0`), TTL, roster filtering, grouping by
  continent.
- `tests/layer_swap_spec.lua`, with the `env.advance` clock pattern from `pvp_feed_spec.lua`:
  - the happy path on both sides;
  - first offer wins, later offers ignored;
  - `assign`/`close` from someone other than the requester are rejected;
  - every timeout;
  - cancel and decline;
  - lockdown;
  - eligibility rejections;
  - a lost `close` cleaned up by `LAYER_SWAP_MAX_AGE`;
  - one swap at a time.
- `tests/layer_sync_spec.lua` (mirrors `pvp_sync_spec.lua`), plus cases in `protocol_spec.lua` (validators, bad
  enums, out-of-range ints) and `comm_spec.lua` (dispatch, GUILD only).
- `tests/layer_popup_spec.lua`: Controller states from 4.2, lockdown retry.
- `tests/view_model_spec.lua` (`LayersView` states, disabled reasons) and `tests/ui_smoke_spec.lua` (the tab draws
  for every role).
- `tests/locale_spec.lua` passes (every string translated, no unused entry).
- `tests/stubs/wow_api.lua`: only what the specs need.

CI must pass unchanged: `luacheck NrageAssistant tests`, `stylua --check NrageAssistant tests`,
`busted --coverage`, `tools/check_coverage.sh 80`.

---

## 9. Phases

Each phase is its own PR (conventional commit titles), so no PR goes far past ~400 changed lines.

| Phase | Scope | Done when |
|---|---|---|
| P0 | `LayerProbe`, `LayerModel`, the Platform getters, `/nrage debug layer`, API_NOTES rows marked "to measure" | probe merged; **an officer must verify 1.1 in game with two clients before release** and record the answers in API_NOTES (no longer a gate before P1, see the decisions log) |
| P1 | `LayerTracker`, `StartLayer()` with detection only, "Your layer" in a minimal Layers tab | own layer shows correctly in game |
| P2 | `LAYER_STATE`, `LayerSync`, `LayerDirectory`, publishing, the share setting, the layer list in the tab, PROTOCOL/PRIVACY docs | two clients see each other's layer |
| P3 | `LAYER_SWAP`, `LayerSwap`, invite/leave Platform calls, `LayerPopup`, request buttons | a full swap works in game between two clients |
| P4 | USER_GUIDE, REDESIGN_PLAN entry + mockup, README | docs merged |

Rules for the implementer: P1-P4 were built on the assumptions of section 1.1 (decided 2026-10-20). If a measured
answer contradicts this plan (for example, the invite needs a full `Name-Realm`, or the layer is not in `zoneUid`),
stop and report instead of improvising.

---

## 10. Decisions log

| Date | Decision |
|---|---|
| 2026-10-20 | Scope: detection, guild directory and swap requests |
| 2026-10-20 | A request targets a layer; every eligible member on it is asked; the requester's client assigns the first offer |
| 2026-10-20 | Leaving the group after the move is a button, never automatic |
| 2026-10-20 | UI: a new Layers tab plus a popup, also added to the redesign plan |
| 2026-10-20 | Plan only; implementation by a Sonnet 5.5 subagent once this plan is approved |
| 2026-10-20 | Build P1-P4 now on the assumptions of 1.1; P0's in-game measurement becomes a must-verify before release. Every unmeasured API is under "Assumed, not measured yet" in `docs/API_NOTES.md`, and every client call is guarded so a wrong assumption disables the feature quietly |
