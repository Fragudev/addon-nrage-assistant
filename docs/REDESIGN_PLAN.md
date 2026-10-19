# UI redesign plan

This is the working plan for replacing the stock AceGUI look with a modern, flat, dark UI. It is written so that an implementation agent can pick it up later with no other context. The plan is iterated with the project owner tab by tab. A section marked **pending review** has not been agreed yet: do not implement it until its decisions are filled in.

- **Visual reference (approved):** the Design canvas at https://claude.ai/artifact/U4aUo3uAXjK3jL4zpTi2eR (artboard "Ventana principal"). It is kept in sync with the decisions in this plan.
  - Artboard "Ventana principal" mocks every tab of the main window and the header settings popover.
  - A "Ver como" tweak switches between admin (GM), raid leader, member and member without a roster, to show what each role sees.
  - Artboard "Ventanas secundarias" mocks the loot popup, the voting window, the export modal and the minimap menu.
  - When the mockup and the text disagree, the text in this plan wins.
  - The canvas is private to the owner: an implementing agent without access works from this text.
- **Inspiration:** EllesmereUI (warm near-black ground, left sidebar, accent bar on the selected row) and Polestar (token-driven theme, 1px pixel borders, Fira Sans/Inter). Copy techniques only. EllesmereUI is "all rights reserved", and Polestar's textures are GPL-3.0. Polestar's fonts are SIL OFL 1.1 and may be reused with attribution.
- **Scope order:** (1) agree the look *(done)*; (2) review each feature/tab and record what changes *(done 2026-10-19)*; (3) implement following the phases in section 5.

---

## 0. Cross-cutting principles

### 0.1 Synchronization is automatic (decided 2026-10-19)

Sharing data between members never depends on a user action. The UI may have a **Save** action for local edits, but sync is never a button.

What is already automatic today (verified in code):

| Mechanism | Where |
|---|---|
| Hello on login | `Sync/Comm.lua`, `SendHello` after a random delay |
| Snapshot request on login | `Sync/Comm.lua`, `RequestSync` after `SYNC_LOGIN_REQUEST_DELAY_*`; admins also resend the readiness rules |
| Profile publish after login, then every `PUBLISH_CHECK_SECONDS` (300 s) if what would be shared changed | `Core/Init.lua`, `StartAutoPublish`, which calls `PublishIfChanged` |
| Profile publish right after a declared field is saved | `UI/Main.lua` `DrawProfile`, which calls `PublishIfChanged` |
| Outbound queue flushed every second, and paused during encounter lockdown | `Sync/Comm.lua` |
| Raid, loot, PvP, blacklist and rules changes sent when they are made | the respective `*Commands` and `*Sync` modules |

Changes required by this principle:

1. **Remove the manual sync controls from the UI.** Remove "Request a sync" (Home, and the minimap right-click menu entry built in `ViewModel` around line 737) and "Publish now" (Profile).
   - Keep `/nrage` slash commands that request a sync or publish, as a troubleshooting fallback that is not advertised in the UI.
   - Update `docs/USER_GUIDE.md` accordingly.
2. **Publish profile changes when they happen, not up to 5 minutes later.** Gear, level and profession changes are only picked up by the 300 s ticker today.
   - Register `PLAYER_EQUIPMENT_CHANGED`, `PLAYER_LEVEL_UP` and `SKILL_LINES_CHANGED`, plus any other event that changes a shared field.
   - On those events, debounce a few seconds, then run `ProfileService.Refresh` followed by `PublishIfChanged`.
3. **Never lose a change made inside the publish cooldown.** `PublishIfChanged` returns `cooldown` for a change made inside `PUBLISH_COOLDOWN_SECONDS`. Schedule one retry for when the cooldown ends (a single pending timer, not one per change) instead of waiting for the next tick. Unit-test this with the existing fakes.
4. **Show sync state, never sync actions.** The header pill and the Home sync card show what is happening:
   - ready
   - paused during an encounter
   - N messages queued
   - last snapshot
   - members with the addon
   - incompatible peers as warnings
5. Lockdown rules are unchanged: everything automatic still defers while `InChatMessagingLockdown()` is true.

---

## 1. Design system

### 1.1 Color tokens (base "ember", approved)

| Token | Value | Use |
|---|---|---|
| `bg` | `#121010` | window ground, content area |
| `panel` | `#191614` | cards |
| `side` | `#0D0C0B` | header bar and sidebar |
| `control` | `#231F1C` | buttons, dropdowns |
| `input` | `#0B0A09` | edit boxes |
| `border` | white @ 0.08 | every 1px border and divider |
| `text` | `#F3EFEA` | primary text |
| `dim` | `#F3EFEA` @ 0.68 | secondary text, labels, inactive nav |
| `muted` | `#F3EFEA` @ 0.50 | captions, section labels, hints |
| `accent` | `#3FA7FF` (Alliance blue) | selection bar, primary buttons, switches, progress, focus |
| `onAccent` | `#0A0C10` | text and knobs on accent fills |
| `success` | `#5BD69A` | passed checks, "sync ready" dot |
| `warning` | `#F5B84C` | pending or partial |
| `danger` | `#F07272` | failed checks, destructive confirm |
| hover wash | white @ 0.05 to 0.08 | hover on nav rows and buttons |
| selected wash | white @ 0.07 | selected nav row |
| status chip ground | status color @ 0.14 | round icon chips, badges |

Keep the accent one token, so it can become user-selectable later. The mockup offers Alliance blue, gold `#E6BA66`, teal `#0CD29D` and bronze `#C9A27E`.

### 1.2 Typography

- **Font:** Fira Sans Regular, Medium and SemiBold. Ship the `.ttf` files in `NrageAssistant/Media/Fonts/` with `OFL.txt`, and credit them in the README.
- No outline. Use a soft 1px shadow only where text sits over art.
- **Sizes:**

| Size (px) | Weight | Use |
|---|---|---|
| 22 | semibold | page title |
| 18 | semibold | hero value (e.g. readiness state) |
| 15 | semibold | window title |
| 14–15 | medium | stat values |
| 13 | regular | body and controls |
| 12 | regular | secondary lines and buttons |
| 11 | semibold, caps, letter-spacing ~0.1em | section labels in `muted` |
| 10 | — | sidebar group labels ("GUILD", "ADMIN") |

### 1.3 Metrics

| Element | Metrics |
|---|---|
| Window | 1000 × 640 default, resizable, position and size saved (keep `UI.ApplyWindowStatus` semantics) |
| Header | 52 px: logo (30 px high), title, version badge, sync status pill, close button (32 px) |
| Sidebar | 200 px wide, 14 px vertical padding, 8 px side padding |
| Nav row | 36 px high, 16 px icon, 10 px gap; selected = 3 px accent bar at the left (inset 8 px top and bottom) plus the selected wash |
| User card | pinned at the sidebar bottom: initial avatar, character name, rank · addon role |
| Content | 26 px top, 30 px sides; 20 px between blocks; scrolls vertically |
| Card | `panel` fill, 1px `border`, 18 × 20 px padding, 12–16 px internal gap, square corners |
| Controls | button 28–30 px (secondary) or 34 px (primary); inputs and dropdowns 32 px; switch 34 × 18 with a 14 px knob |
| Divided list rows | 13 × 20 px padding, 1px `border` between rows |

### 1.4 Shared patterns (every tab uses these)

1. **Page header:** title (22px) plus a one-line description in `dim`. A badge or summary chip may sit on the right.
2. **Card with section label:** an uppercase muted label, then the content.
3. **Key/value row:** label in `dim` on the left, value on the right.
4. **Stat block:** a small muted caption over a 14–15px value, laid out in a 3–4 column grid.
5. **Status chip:** a 22px (list) or 40px (hero) circle in the status color at 0.14, with a stroke icon (check, cross, dash, exclamation).
6. **Divided list:** rows inside one card, each with a status chip, a name plus a sub-line, and a value on the right.
7. **Data table:** a header row in muted caps, clickable to sort, with a ▲/▼ mark. Body rows use subtle alternate striping (black at 0.1/0.2, as in EllesmereUI) and highlight the own row with the accent wash. This replaces the colored `|c..|r` cells.
8. **Sub-navigation (Raid, PvP):** a horizontal tab strip under the page header with a 2px accent underline on the selected tab. This replaces nested AceGUI `TabGroup`s.
9. **Master/detail (Raid, Loot):** a list column on the left (selected row uses the same bar and wash as the nav) and a detail area on the right.
10. **Action feedback:** today `actionMessage` is printed as a plain line. It becomes an inline banner at the top of the content: tinted with success, warning or danger at 0.12 and a matching left icon, dismissible, cleared on tab change.
11. **Destructive two-click confirm:** keep the current behavior (first click arms, second confirms). The armed state turns the button `danger`-filled with "Confirm…" text.
12. **Empty state:** a centered icon, a one-line title and a muted hint inside a card.
13. **Buttons:** secondary = `control` fill with a 1px border; primary = `accent` fill with `onAccent` text; ghost = accent text link ("See details →").

---

## 2. Implementation approach (for the kit phase)

- **Own widget kit, no AceGUI for these windows.** Create `NrageAssistant/UI/Kit/`:
  - `Theme.lua` holds the tokens above and font objects.
  - `Pixel.lua` holds the 1-physical-pixel helper and a four-texture border, as in Polestar's `Theme.Pixel` and `Theme.Border`.
  - The widgets: Window, Sidebar/NavRow, Card, SectionLabel, Label, KeyValue, StatGrid, Button (secondary/primary/ghost/danger), Switch, Checkbox, Dropdown, EditBox, ScrollArea, TabStrip, Table, ListRow, Banner, EmptyState.
  - Build everything from `CreateFrame` plus solid textures (`SetColorTexture`), with no backdrop templates and no art files except the logo and stroke icons.
- **Keep the thin-UI architecture.** `ViewModel` stays the source of text and decisions. `Main.lua` keeps its Draw-per-tab structure but calls the kit. Where the kit needs structured data (rows, stats, statuses), add ViewModel functions that return tables instead of pre-formatted lines, and unit-test them in `tests/view_model_spec.lua`.
- **Tests:** `tests/ui_smoke_spec.lua` currently fakes AceGUI. Replace that with a fake of the kit's API so every tab is still drawn for every role and the buttons are still pressed.
- **Kit API shape:** keep it close to what Main.lua already calls (`AddChild`, `SetText`, `SetCallback`, `SetValue`, `SetList`, `SetRelativeWidth`/`SetFullWidth`). Then the migration is mostly mechanical and the fake stays simple.
- **Icons:** draw simple stroke icons as small white TGAs (our own, 32 px) tinted at runtime: home, user, check-circle, calendar, gem, swords, ban, users, list, close, chevron, check, cross, dash, alert.
- **Platform constraints (WoW Forever, Midnight rules):** these are insecure frames shown out of combat only. The existing lockdown guards for popups stay as they are. Nothing new touches secure templates.
- **Libraries:** AceGUI stays embedded until every window has moved. Then remove it from `embeds.xml`, the TOC and `Libs/`.

---

## 3. Main window: per-tab plan

Each tab lists what it does today (from `UI/Main.lua`), then the redesign, then the decisions from the feature review.

### 3.1 Home (`DrawHome`): **layout approved (mockup), feature review pending**

**Today:**
- logo header with "Nrage Assistant <version>"
- your readiness summary line
- sync status lines (`Comm:Status`: ready or paused, queued messages, last snapshot, peers seen, incompatible peers)
- the last action message
- "Your role" line (identity, guild rank, addon role) with a "Request a sync" button
- Settings: "Show the minimap button" checkbox and "Reset the button position"

**Redesign (mockup):** a 2×2 card grid.
- *Your readiness:* hero status chip, state word, "N of M requirements met", accent progress bar, "Missing: …" and a ghost link to the Readiness tab.
- *Sync:* key/value rows (status with dot, queued messages, last snapshot, members with the addon), then a secondary "Request a sync" button. Incompatible peers show as warning rows.
- *Your role:* a three-column stat grid: character, rank, addon role (role in accent).
- *Settings:* a minimap switch row, and a "Button position" row with a "Reset" button.

**Feature review decisions (2026-10-19):**
- **Add a "Next raid event" card.** It shows the nearest upcoming event: title, local start date and time, and status badge. A ghost link opens it in the Raid tab with that event selected. If no event is upcoming, use the empty-state pattern ("No upcoming events"). Source: `db.global.events` through a new ViewModel function, e.g. `ViewModel.NextEvent(events, now)`, unit-tested; it must ignore past and cancelled events.
- **Add an "Open loot sessions" card.** It lists the open sessions across events: item icon and name, event title, and candidate count. A ghost link opens the Loot tab on that event. Empty state: "No open loot sessions". Source: `LootService.Sessions` through a new ViewModel function, e.g. `ViewModel.OpenLootSessions(events)`, unit-tested.
- **Move the settings out of Home.** The minimap switch and "Reset button position" leave Home and go behind a **gear icon button in the window header**, next to the close button. It opens a small settings popover (or panel) in the theme, holding the same two controls. It should be easy to add more settings there later (e.g. the accent color).
- **Language selector: Spanish / English.** It goes in the same settings popover as the minimap controls, reached from the header gear, so it is available from every tab. The choice is a dropdown: "Automatic (game language)", "Español" or "English".
  - Store it account-wide as `db.global.settings.language` = `"auto" | "es" | "en"`, default `"auto"`, which keeps today's behavior (`Locale.LanguageFor(GetLocale())`).
  - **Technical constraint (verified in `Core/Locale.lua` and `UI/ViewModel.lua`):** many strings are translated when their file loads, e.g. `ViewModel.TABS = { { text = L("Home") } … }` and `RULE_CHECK_TEXT`. SavedVariables are only available at `ADDON_LOADED`, after every file has run. So neither a live switch nor a reload alone would translate those tables.
  - The implementer must therefore:
    - (a) call `Locale.Use` from the saved setting at `ADDON_LOADED`, before any UI is built;
    - (b) turn every load-time `L(...)` held in module-level tables into lazy lookups (store the English key and translate when drawing, or wrap the table in a function);
    - (c) add a test that switches the language and checks that the tab names and rule texts follow.
  - With (b) done, the window can simply redraw after a change, so no `ReloadUI` is needed. Chat output and anything sent over the wire stay as they are today (English or untranslated, per the Locale header comment).
- **The Sync card is read-only.** Drop the "Request a sync" button from the mockup's sync card (principle 0.1).
- **Resulting Home grid:** readiness, sync, next raid event and open loot sessions as a 2×2 grid, "Your role" no longer has a card of its own: it is merged into the sidebar user card (character, rank · addon role), as the updated mockup shows.
- The mockup (version of 2026-10-19) reflects these Home and Profile decisions and the header settings popover.

### 3.2 Profile (`DrawProfile`): **layout approved (mockup), feature review pending**

**Today:**
- profile description lines (`ProfileService.Describe`)
- declared details: main spec and second spec dropdowns (ROLES; the second is optional), main character, notes (local only)
- "Shared with the guild" description with the privacy notes
- "Publish now"
- status message

**Redesign (mockup):**
- stat grid card: class, level, item level, professions
- "Your declared details" card in a 2-column form: two dropdowns, two inputs; notes hint "stays on this computer"
- "Shared with the guild" card: text on the left, primary "Publish now" on the right
- save and publish results go to the banner

**Feature review decisions (2026-10-19):**
- **New card order. This supersedes the mockup's stat grid and form layout:**
  1. **Line 1, identity stat grid (4 columns):** Name (character name without the ruleset suffix if `Platform.GetIdentityKey` adds one), Class (in the class color is fine), Level, Item level.
  2. **Line 2, specs:** two dropdowns side by side: "Main spec" (required) and "Second spec" (optional, empty by default, placeholder "None"). Same `ProfileService.ROLES` list and save-on-change behavior as today.
  3. **Line 3, professions, on a line of its own:** primary professions (up to 2) and secondary professions (cooking, fishing, first aid, and whatever the client returns) as chips or stat blocks: name, skill / max. Group primary first, then secondary, with a muted caption for each group. Data comes from `Platform.GetProfessions()`, which already returns `{ name, skill, max }`. Check in the client that it includes the secondary professions on Forever, and record the result in `docs/API_NOTES.md`. A "See recipes →" ghost link opens the Professions tab (section 3.10).
  4. **Then:** the remaining declared details (main character and notes), then the "Shared with the guild" card.
- **Save the text fields on focus loss.** "Main character" and "Notes" save when the edit box loses focus (`OnEditFocusLost`) as well as on Enter. Save only if the text differs from the stored value, so tabbing through does not re-save or re-publish. Escape restores the stored value without saving. The dropdowns already save on change. The save path stays `ProfileService.SetField`, then `PublishService.PublishIfChanged`, as today. The kit's EditBox must expose a focus-lost callback with the current text.
- **Show when the profile was last published.** The "Shared with the guild" card shows a muted line under the text: "Last published: <relative time>" (e.g. "3 min ago"), or "Not published yet" when there is none. The data already exists: `character.publish.at` (server time), set by `PublishService.Publish`. Add a ViewModel formatter, e.g. `ViewModel.LastPublished(at, now)`, unit-tested for: nil, under a minute, minutes, hours, and days.
- **No "Publish now" button** (principle 0.1). The "Shared with the guild" card becomes informational: what is shared, the privacy note, and "Shared automatically · Last published: …". A change made inside the cooldown is published when the cooldown ends (principle 0.1, item 3), so no cooldown UI is needed.
- **No Save button.** Decided: edits save on focus loss (text fields) or on change (dropdowns), as described above. Each successful save triggers the automatic publish. A short "Saved" confirmation goes to the banner, or appears as a transient check next to the field.

### 3.3 Readiness (`DrawReady`): **layout approved (mockup), feature review pending**

**Today:**
- action message
- `ReadinessService.Describe` lines
- "Confirm by hand" dropdowns (READY_STATUSES) for manual rules

**Redesign (mockup):**
- page header with a summary badge ("N of M met", colored by state)
- one divided list card with one row per rule: status chip, rule name, rule detail and measured value; failing values in `danger`, pending in `warning`
- a manual rule row carries its status dropdown inline on the right instead of a separate section

**Feature review decisions (2026-10-19):**
- **Refresh automatically, with no button.** Today the checklist is evaluated only when the tab is drawn, so an expired flask still shows as passed. While the Readiness tab (or the Home readiness card) is on screen:
  - re-run `ProfileService.Refresh` and the evaluation on `UNIT_AURA` (player only), `PLAYER_EQUIPMENT_CHANGED`, `PLAYER_LEVEL_UP` and `SKILL_LINES_CHANGED`
  - throttle the redraw like `UI.PvPChanged` does (at most one per interval, the last one wins)
  - stop listening when the tab is hidden
- Readiness is not shared with the guild today (`PublishService.Describe`: "enchants and buffs stay on this computer"), so this refresh is local and sends nothing.

### 3.4 Raid (`DrawRaid`): **pending review**

**Today:**
- left column: "New event" input, Export and Import buttons, a list of event buttons ("> " marks the selected one)
- right pane: a sub-tab group (`ViewModel.RaidSubTabs`, filtered by role) with these sub-tabs:
  - summary (`RaidEventLines`)
  - details: rename, status dropdown, start date text "YYYY-MM-DD HH:MM", two-click delete
  - attendance: recorded members with a state dropdown each, then a search box, a "Record as" dropdown and up to 8 match buttons
  - assignments: a list with Remove; member dropdown, encounter field and Add
  - templates: suggested "Apply" buttons, a saved templates dropdown with Apply and Delete, "Save as…"
  - reports: scope "this event" or "all events", then report lines
- Export and Import open the transfer window (multiline edit box)

**Redesign (approved 2026-10-19):** master/detail. The left column is the event list. The right side is the event header (title, date, status badge), then a sub-navigation strip, then the sub-tab content built from cards and tables. Sub-tabs stay role-gated through `ViewModel.RaidSubTabs` and `RaidActions`, unchanged.

**Feature review decisions (2026-10-19):**
1. **Date and time picker.** Replace the "YYYY-MM-DD HH:MM" text input everywhere (the Details sub-tab and the new event form).
   - The picker is a small month calendar popover (previous/next month, today highlighted, past days muted but selectable) plus hour (00–23) and minute (00/15/30/45) dropdowns. Show the result as "Thu 23 Oct · 20:30" in local time.
   - Keep `raid:SetEventStart` as the single write path. Either convert the picker values to the string format it already parses, or add a sibling that takes a timestamp; unit-test the conversion around a DST change.
   - Build the calendar as a kit widget (DatePicker), so it can be reused elsewhere.
2. **Event list (left column).**
   - Each row shows the title, the local date and a status badge for `EVENT_STATUSES` (planned, open, closed, cancelled), with the colors: planned = accent, open = success, closed = muted, cancelled = danger.
   - The selected row uses the nav selection style.
   - A segmented filter "Upcoming / Past" sits on top, defaulting to Upcoming. Past means the start date is in the past, or the status is closed or cancelled.
   - **"+ New event"** (shown only when `actions.events`) opens an inline form card: title (required), date and time (picker), status (default planned), and Create/Cancel. It replaces "type a title + Enter". On success, the new event is selected, as today.
3. **Export / Import stay**: they are backup and migration, not sync (see USER_GUIDE "Moving data around"). They move to a "⋯" overflow button at the top of the list. Import keeps its current role gate. The transfer window is restyled (section 4).
4. **Attendance.**
   - The recorded members show as a table: name, a state dropdown (`ATTENDANCE_STATES`), and when it was recorded if available. The search to add members stays (filter box, "Record as" dropdown, up to `ATTENDANCE_MATCHES_MAX` match buttons).
   - **New: "Fill from current group".** It marks every member of the player's current raid or party who is not recorded yet as `present`, in one action. It goes through the same `raid:SetAttendance` path, so every change is validated and synced as usual. Members already recorded are never overwritten.
   - Only shown when the role may edit attendance and the player is in a group. The result goes to the banner ("12 members marked present").
   - It needs `IsInRaid`, `GetNumGroupMembers`, `GetRaidRosterInfo` and `UnitName("partyN")`, which are listed in `docs/API_NOTES.md` as **not measured yet**: measure them on Forever first, behind `Platform` with `pcall`. Group names must be matched to guild member keys the same way the roster does; unit-test the matching.
5. **Assignments.**
   - Grouped by encounter: one card per encounter, rows "member — task", each with a remove icon button.
   - The add form is a member dropdown plus an encounter combo: a dropdown of encounters already used in this event plus a "New encounter…" option that turns into a text input. Then an optional task and Add.
   - Same `raid:AddAssignment` / `RemoveAssignment` calls.
6. **Templates.** Suggested templates (`TemplateService.Suggest`) show as small cards with the template name and an "Apply" button. The saved templates dropdown with Apply and Delete, and the "Save this event's assignments as…" input, stay in one "Templates" card below. Delete uses the two-click confirm.
7. **Delete event.** A danger-styled button at the bottom of the Details sub-tab, with the existing two-click confirm (pattern 1.4.11).
8. **Reports.** A segmented "This event / All events" control in place of the scope dropdown. The output becomes a data table instead of lines. This needs a ViewModel function that returns rows and columns instead of `ReportLines` strings, unit-tested; keep `ReportLines` if the slash command still uses it.

#### 3.4.1 Raid rosters (NEW feature, agreed 2026-10-19, details pending)

**Goal:** the guild runs several raid rosters (teams). Admins assign each player to a roster. A player only sees the raid information of their own roster. Admins can see any roster and switch between them with a roster selector.

**Agreed so far:**
- **Roster definitions:** admins create, rename and delete rosters (id + name).
- **Membership:** admins assign each player to a roster. The data is synced automatically to the guild (principle 0.1), with revisions and tombstones like the other synced records. The receiver checks that the sender is an admin, as for the readiness rules.
- **Events belong to a roster:** an event gets a `rosterId`, set in the new-event form (a dropdown, required whenever rosters exist).
- **Visibility:**
  - Raid tab, Home "Next raid event" and Loot event selection show members only the events of their own roster.
  - Admins get a **roster selector** (a dropdown in the Raid page header, and in Loot) that defaults to their own roster and offers "All rosters".
  - **A player with no roster sees no events (decided 2026-10-19).**
    - The Raid tab shows an empty state: "You are not in a roster yet. An admin has to assign you one."
    - The Home "Next raid event" card and the Loot event selection show the same notice.
    - Legacy events without a `rosterId` (see Migration) are visible to members who have a roster, not to members without one.
- **Security limitation, documented on purpose:** this is a *visibility filter in the UI*, not access control. Raid data still travels over the GUILD addon channel, and every member with the addon receives all of it (see `docs/PRIVACY.md`). Real confidentiality would need per-member WHISPER delivery of each roster's data, which is a protocol redesign and out of scope unless the owner asks for it. `docs/PRIVACY.md` and `docs/USER_GUIDE.md` must state this.
- **Migration:** existing events have no `rosterId`. They stay visible to everyone until an admin assigns them; the admin UI offers this in the event Details. Old clients that do not know `rosterId` must not drop or corrupt it: check that `Sync/Protocol.lua` validation tolerates the new optional field, and bump the protocol version if needed.
- **Permissions (confirmed 2026-10-19): only admins manage rosters.** That covers creating, renaming and deleting rosters, and assigning both members and raid leaders to them. Nobody else, raid leaders included, can change roster definitions or membership.
  - Add `roster_manage = { admin = true }` and `roster_view_all = { admin = true }` to `PermissionService`.
  - The receiver rejects any roster change whose sender is not an admin.

#### 3.4.2 Addon roles assigned by admins (NEW, agreed 2026-10-19)

**Context:** the guild ranks are not defined yet. So, for now, addon roles are **assigned inside the addon by admins**, not derived from the guild rank.

**Current behavior (verified):**
- `PermissionService.RoleOf` / `OwnRole` map the guild rank name through `Constants.RANK_ROLES`: gm and officer → admin, council → council, rl → rl, the rest → member.
- `BETA_ADMIN_NAMES` force admin.

**Agreed changes:**
- **Admins assign roles.** Admins assign each guild member one of the addon roles `member`, `rl` or `council`, plus their roster (section 3.4.1).
  - Assignments are synced automatically (principle 0.1) as admin-signed records with revisions and tombstones.
  - Receivers accept them only from a sender who is an admin.
  - Unassigned members are `member`.
- **Role resolution, both for the own role and for a sender's role on the receiver:**
  1. If the guild rank maps to `admin` in `RANK_ROLES`, or the name is in `BETA_ADMIN_NAMES` → `admin`. This is the root of trust and must not depend on synced data.
  2. Otherwise → the admin-assigned role, if any.
  3. Otherwise → `member`.
  - While this mode is active, `RANK_ROLES` entries for non-admin roles (council, rl) are ignored. Keep the mapping code, so it can be switched back once ranks exist: a constant such as `ROLE_SOURCE = "assigned" | "rank"`.
- **Where admins assign:** the Members (Roster) tab gets an admin-only view. Each member row has a **Role** dropdown and a **Roster** dropdown, which save on change and sync automatically. Members see the same table read-only, without these controls. This answers roster question 5 for membership. Roster definitions (create, rename, delete) go in a small "Rosters" card on the same tab, admin-only.
- **Tests:**
  - `PermissionService` resolution order (rank admin beats an assignment, an assignment beats the default, beta admin)
  - rejection of role and roster records from non-admins
  - tombstones that remove an assignment
- **Docs:** update `docs/USER_GUIDE.md` (who can do what) and `docs/PROTOCOL.md` (the new record types).

**Decided (2026-10-19): the Guild Master is the only admin for now.** This will be revisited once the guild ranks are defined.
- **Admin is determined ONLY by the guild rank, never by a player or character name.** Remove every name-based admin check from the resolution path (the beta list included). Nobody is admin because of who they are, only because they hold the GM rank.
- **Identify the GM by rank index, not by rank name** (the names are not defined yet). The GM is always `rankIndex == 0` in `GetGuildRosterInfo`; `GuildRoster` entries already carry `rankIndex`. For the own role, use the own roster entry's `rankIndex`, or `IsGuildLeader()` if available on Forever (measure it first and note it in `docs/API_NOTES.md`). `Platform.GetOwnGuildRank` currently returns only the name (`GetGuildInfo`); extend it to return the rank index too (the third return value of `GetGuildInfo("player")`).
- So step 1 of the resolution order above becomes: `rankIndex == 0` → `admin`. Officers are no longer admins via `RANK_ROLES` while `ROLE_SOURCE = "assigned"`.
- **`admin` cannot be granted from the addon.** The Role dropdown offers only member, rl and council. A received assignment carrying `admin` is rejected.
- **Beta admin list:** `BETA_ADMIN_NAMES` ("Yonemon Gg") also forces admin today. To keep "the GM is the only admin" true, set `BETA_ADMIN_ENABLED = false` when this ships (issue #25 tracks removing it). Confirmed by the owner: that character is the GM, so nothing is lost. Disable the list, and close issue #25 or update it.
- Tests: rank index 0 → admin; any other index with any rank name → the assigned role or member; an `admin` assignment record rejected; beta list disabled.

**Pending review questions:**
1. ~~Can a player belong to more than one roster?~~ **Decided: one roster per player at most.** Store membership as `memberKey -> rosterId`. Assigning a player to another roster moves them.
2. ~~Do raid leaders see and manage only their roster?~~ **Decided: only their own roster.**
   - A raid leader sees only their roster's events and has no roster selector.
   - They can create and edit events, attendance, assignments and templates only for that roster. New events get the raid leader's `rosterId` automatically.
   - **Receiver-side check:** the receiver already checks the role on every raid change (`EventService`). It must also check that an `rl` sender's roster (from the synced membership) equals the event's `rosterId`, and reject the change otherwise. Admins pass for any roster. Add tests in `event_sync_spec.lua` for an rl editing another roster's event (rejected) and an admin doing it (accepted).
   - A raid leader with no roster can manage nothing until an admin assigns them.
3. ~~What does a player with no roster see?~~ **Decided:** no events, only the notice (see Visibility).
4. ~~Do templates, reports and loot sessions follow the event's roster?~~ **Decided: yes.**
   - **Templates** get a `rosterId` too. A template is listed, suggested and applied only within its roster. `rl` users save and see only their roster's templates; admins see the ones of the selected roster. Existing templates without a roster behave like legacy events.
   - **Reports** only count events of the selected roster: the own roster for members and rl, the selector for admins ("All rosters" allowed for admins).
   - **Loot sessions** belong to their event, so they inherit its roster.
     - The **loot popup (`UI/LootPopup.lua`) only appears for members of that roster.** Other guild members do not get it, and their client ignores the session for prompting.
     - Applying, voting and awarding are limited to members of the roster (the receiver checks the applicant's roster), plus admins.
     - The **voting window** only opens automatically for `rl` and `council` of that roster, and for admins.
     - Council is a role, not per roster: a `council` member with roster X votes only on roster X's sessions.
   - Receiver-side checks mirror these rules; add sync tests.
5. ~~Where do admins manage rosters?~~ **Decided:** in the Members tab (see 3.4.2).

### 3.5 Loot (`DrawLoot`): **pending review**

**Today:**
- event dropdown
- "Open the voting window" (voters)
- "Open a session": item link field and Open (openers)
- sessions list (`ViewModel.LootSession`); per open session:
  - apply: spec field, upgrade field, and Apply as main/off/other
  - council: candidate dropdown, Vote, award reason, Award, Close without awarding
- privacy note
- show or hide the minutes

**Redesign (approved 2026-10-19).** Roster rules from 3.4.1 apply throughout: only the events of the own roster; admins get the roster selector; loot sessions belong to their event's roster.

**Feature review decisions (2026-10-19):**
1. **Event selector in the page header.**
   - It defaults to the most recent event of the roster that has an open session, otherwise the most recent event.
   - Admins also see the roster selector, as in Raid.
   - Members without a roster see the "no roster" notice instead.
2. **Open a session** (`loot_open`: council and admin).
   - The item link field shows a live preview as soon as a link is pasted or shift-clicked: icon, name in its quality color, tooltip on hover. "Open" (primary) is enabled only when `LootCommands.ParseItem` succeeds.
   - **Optional, gated by API measurement:** when the player loots a boss, a "Last boss loot" strip lists that corpse's items, each with its own "Open" button.
     - Candidates: `LOOT_OPENED`, `GetNumLootItems`, `GetLootSlotLink`, and/or `ENCOUNTER_LOOT_RECEIVED`.
     - Measure them on Forever first and record them in `docs/API_NOTES.md`. If they are unavailable or return secret values, ship without the strip.
3. **Session cards**, one per session, newest first.
   - Header: item icon, item name in its quality color, event and encounter, status badge (open = success, closed = muted), and the time left while open (the countdown the popup already has).
   - **Candidates table:** name, response (main = success, off = warning, other = accent, matching the voting window), spec, upgrade, votes.
   - **Row actions:** `loot_vote` users get "Vote" on each row; `loot_award` users get "Award" on each row.
   - "Award" expands an inline reason input under that row, with "Confirm award" (primary) and "Cancel". This replaces "pick a candidate in a dropdown, then press a button".
   - "Close without awarding" is a secondary button in the card footer, with a two-click confirm.
   - A closed session collapses to one line: item → winner (response), plus the reason.
4. **Applying from the tab** (`loot_apply`, own roster only).
   - Main spec / Off spec / Other / Pass are segmented buttons, the same choices as the popup.
   - **The spec is no longer typed:** it comes from the declared main or second spec in Profile. Main uses `role`; off uses `role2` when set, else `role`. A muted line says "Spec: Tank (from your profile)".
   - The upgrade field stays optional.
   - Same `loot:Apply` call; the `spec` parameter is filled from the profile.
5. **The voting window** keeps opening automatically for that roster's `rl` and `council` members and for admins (3.4.1). Restyle it with the same candidates table and row actions (section 4).
6. **Minutes:** a collapsible "Minutes" card at the bottom, collapsed by default. Its table has the columns item, winner, response, reason and date. This needs a ViewModel function returning rows instead of the `LootMinutes` lines; keep the lines version if a slash command uses it.
7. **The privacy note** ("Addon messages are not private: anyone with the addon can read votes") becomes muted footer text.

### 3.6 PvP (`DrawPvP`): **pending review**

**Today:** three sub-tabs.
- mine: `PvPStats` lines
- ranking: period dropdown (total or today); a sortable table (name, rank, world, BG, total, killing blows, updated), with the own row green and capped at `PVP_RANKING_ROWS_MAX`; admin-only reset of one member's counters with a two-click confirm
- feed: recent own kills since login

**Redesign (approved 2026-10-19).** PvP is guild-wide: rosters do not apply.

**Feature review decisions (2026-10-19):**
1. **Sub-navigation strip:** My stats · Ranking · Recent kills. Remember the last sub-tab for the session, as today.
2. **My stats.** Two stat grids, "Today" (server day, UTC, as today) and "Total".
   - Each grid holds honourable kills (open world, battleground, total), killing blows, and the PvP rank.
   - A figure the client cannot provide (`honorAvailable` / `blowsAvailable` false) shows "Not available" in `muted` in its cell, instead of a sentence.
   - This needs a ViewModel function returning structured values instead of the `PvPStats` lines.
3. **Ranking.**
   - The shared data table: name, rank, world, BG, total, killing blows (column only when available), updated.
   - Sortable headers with ▲/▼, using the existing `NextSort` and `PVP_FIRST_DESCENDING`.
   - A "Total / Today" segmented control replaces the period dropdown.
   - A search box filters by name.
   - **The own row is highlighted with the accent wash**, not green text.
   - **Top 3 by the current sort:** the position number is colored gold `#E6BA66`, silver `#C0C6CF` and bronze `#C9A27E`. Add a position column if one is not there yet.
   - Keep the `PVP_RANKING_ROWS_MAX` cap with the "Showing N of M" footer, and keep the note on where the counters come from, as muted footer text.
4. **Recent kills.**
   - A divided list: time, killer → victim, place (world or battleground), and a "Killing blow" badge when it was one.
   - Empty state: "No kills yet". Unavailable state: "The kill feed is not available on this client" (the existing text).
   - Same data source (`ns.pvpFeed`); it needs a ViewModel function returning rows instead of lines.
5. **Admin reset (the `moderate` action; the GM only, per 3.4.2).**
   - A separate "Admin" card at the bottom of the Ranking sub-tab, with a member dropdown and a danger button with the two-click confirm (pattern 1.4.11).
   - Same `comm:ResetPvP` call. The result goes to the banner.

### 3.7 Blacklist (`DrawBlacklist`): **pending review**

**Today:**
- "Add a player": name, reason (max `BLACKLIST_REASON_MAX`), Add
- the list as cells (name, reason, "added by, date") with Remove for GM and officers
- notes on who can add or remove and the group warning

**Redesign (approved 2026-10-19).** The blacklist is guild-wide: rosters do not apply.

**Feature review decisions (2026-10-19):**
1. **The "Add a player" card is one inline row:** name, reason, Add (primary). Everyone can add (`blacklist_add`), as today.
   - The reason input shows a live character counter "n / `BLACKLIST_REASON_MAX`", which turns `warning` near the limit.
   - Validation errors (`BlacklistService.Validate`) go to the banner.
2. **The list is a data table:** name, reason, added by, date, and an actions column. A search box above filters by name or reason.
   - **Edit the reason** (pencil icon) for the member who added the entry, or for the GM (`blacklist_edit_any`).
     - The logic already exists: re-adding a listed player updates their reason, guarded by `BlacklistService.CanEdit`.
     - The pencil turns the reason cell into an inline input with Save and Cancel, which calls `commands:Add(name, newReason)`. Show the pencil only when `CanEdit` is true for the own character and role.
   - **Remove** (GM only, `blacklist_remove`): a trash icon with the two-click confirm (pattern 1.4.11). Same `commands:Remove`.
3. **New: an "In your group" badge.** Rows for listed players who are in the current party or raid get a `danger` badge "In your group" and are sorted first.
   - The data comes from what `BlacklistWatcher` already computes: `BlacklistService.Match(entries, members)` over the group members. Expose that list for the UI.
   - Recompute on `GROUP_ROSTER_UPDATE` while the tab is visible (throttled like `UI.BlacklistChanged`).
4. **Alert sound setting.** The alert (chat line, raid warning, sound) stays as it is.
   - New switch in the header settings popover: "Blacklist alert sound", stored in `db.global.settings.blacklistSound`, default on.
   - When off, the alert still prints and shows the raid warning, but plays no sound. Gate only the `PlaySound` call in the alert path (`Core/Init.lua` around `Platform.ShowRaidNotice`).
   - Unit-test the setting's default and its persistence.
5. **The notes become muted footer text:** "Everyone can add a player. Only the GM can remove one." and "You are warned once when a listed player is in your group." Update the wording, since admin now means GM (3.4.2).

### 3.8 Roster (`DrawRoster`): **pending review**

**Today:** plain lines from `ViewModel.Roster`: profiles received, with stale ones labeled.

**Redesign (approved 2026-10-19):** see also the admin controls in 3.4.2.

**Feature review decisions (2026-10-19):**
1. **The whole guild, not only addon users.**
   - The table lists every guild member from `ns.guildRoster` (bounded by `GUILD_ROSTER_MAX`), merged with the received profiles (`db.global.roster`).
   - Members with no received profile show in `muted` with a "No addon" badge, and only the fields the guild roster provides (name, class, level). This lets the GM assign roles and rosters to everyone.
   - Merge by the same name key the roster and permissions use. This needs a ViewModel function returning rows instead of the `ViewModel.Roster` lines; unit-test the merge, the stale flag and the no-addon flag.
2. **Columns:**
   - name
   - class (in the class color)
   - level
   - item level
   - main spec
   - second spec
   - roster
   - role
   - updated
   Profiles older than `ROSTER_STALE_SECONDS` (7 days) get the `warning` "Stale" badge in the updated column. Nothing received is ever shown as verified (keep that rule). Sortable headers.
3. **Search and filters:** name search; quick filter chips for roster (each roster plus "No roster", visible to admins, and to rl for their own roster), spec (Tank / Healer / DPS, from `ProfileService.ROLES`), and "With addon only".
4. **Row detail:** clicking a row expands it inline to show professions (primary and secondary, with skill), main character and the time of the last received profile. Only one row is expanded at a time.
5. **GM controls** as in 3.4.2: Role and Roster dropdowns on each row (not on the GM's own row), and the Rosters card at the top with the counts per roster, "No roster" and "+ New roster". Everyone else sees the same table read-only.

### 3.9 Rules (`DrawRules`, admins only): **pending review**

**Today:**
- revision line
- the rule list (label, summary) with Remove
- "Add a rule": kind dropdown, name, details (hint depends on kind), Add rule, "Use the starting list"
- explanatory notes

**Redesign (approved 2026-10-19).** The tab sits under the "ADMIN" sidebar group, which only the GM sees (`rules_edit`, admin = GM per 3.4.2). Rules are guild-wide: rosters do not apply.

**Feature review decisions (2026-10-19):**
1. **Header:** "Revision N" (from `ReadinessRules.Describe`) plus a muted "Sent to the guild automatically". There is no send button: every change already goes out through `comm:SetReadinessRules`, and admins resend on login.
2. **Rule list:** a divided list, one row per rule, showing:
   - the kind (its `RULE_CHECK_TEXT`)
   - the name (`ReadinessService.LabelText`)
   - a readable summary (`ViewModel.RuleSummary`, e.g. "level 60 or more")
   - an **Automatic** badge (accent) or a **Manual** badge (warning), from `evidenceMode`: observed means automatic; manual covers `field` and `confirm`
   - **New: edit a rule in place (pencil).** It opens the same per-kind form as "Add a rule", prefilled.
     - Saving replaces the rule at the same position and keeps its `id`, so the manual confirmations members already gave stay attached.
     - Add a `ViewModel.ReplaceRule(rules, id, rule)` helper (unit-tested: position kept, id kept, unknown id rejected), then call `SaveRules`.
   - **Delete:** a trash icon with the two-click confirm, same `WithoutRule` + `SaveRules`.
3. **Per-kind controls for adding or editing.** They replace the single free-text "Details" field:

   | Kind | Controls |
   |---|---|
   | level / ilvl | a number input (min 1) |
   | enchants | toggle chips for the enchantable slots (`ViewModel.ENCHANT_SLOTS`: head, shoulders, back, chest, wrist, hands, legs, feet, main hand…) |
   | buff | a text input for spell names and/or ids, comma-separated (same parsing) |
   | profession | a profession dropdown plus a minimum skill number input |
   | field | a dropdown of `Constants.MANUAL_FIELDS` |
   | confirm | no extra control |

   - Keep `ViewModel.RuleFromInput` as the single validation path. The form builds the same `details` string it expects, or `RuleFromInput` gains a structured variant (unit-tested).
   - Validation errors (`RULE_ERRORS`) show **under the offending field**, with the error color on that field's border, and also in the banner.
4. **"Use the starting list"** is a secondary button with the two-click confirm (pattern 1.4.11). The armed text warns that it replaces every current rule. It calls `SaveRules(Constants.DEFAULT_RULES)` as today.
5. **A "See how members see it →" ghost link** opens the Readiness tab.
6. The explanatory notes become muted footer text.

### 3.10 Professions (NEW tab): **approved 2026-10-19**

**Goal:** the addon knows which recipes every member with the addon has learned. A search box finds a recipe and lists who can craft it.

**Agreed so far (2026-10-19):**
- **Its own sidebar entry, "Professions"** (in the GUILD group), open to every member.
- **Recipe scan (own character).** Learned recipes are read from the profession API when the player opens a profession window. Candidates: `TRADE_SKILL_SHOW` / `TRADE_SKILL_LIST_UPDATE`, then `C_TradeSkillUI.GetAllRecipeIDs()` and `C_TradeSkillUI.GetRecipeInfo(id).learned`. Mainline only lists recipes while that window is open, so the addon keeps the last scan per profession in the character's saved data and asks the player (a muted hint) to open each profession once.
  - **Not measured yet:** which of these APIs Forever exposes, and whether secondary professions scan the same way. Add rows to `docs/API_NOTES.md` and measure them in the client before building on them.
  - Everything goes through `Core/Platform.lua` behind `pcall`, like the other APIs.
- **Automatic sync (principle 0.1).** Each member publishes their recipe list per profession whenever a scan changes it, with no button.
  - Send recipe IDs, not names (the names are localized and much larger), with a revision per profession, as the profile and PvP records do.
  - **Size:** a profession can have hundreds of recipes, and `MAX_ENCODED_BYTES` is 4096 per message. The design must either (a) add a dedicated message type, chunked within the existing limits, or (b) carry the lists in the snapshot path (`SYNC_MAX_ENCODED_BYTES` 32 KB), with deltas for changes.
  - Either choice needs an update to `docs/PROTOCOL.md`, validation of every received ID list (type, count cap, duplicates), receiver-side caps on stored members, and tests mirroring `pvp_sync_spec.lua`.
  - Received lists are stored in `db.global` keyed by member and profession, with the same staleness rules as the roster.
- **Privacy.** Learned recipes become shared data, so update `docs/PRIVACY.md` and the "Shared with the guild" text in Profile.

**Page layout (proposal):**
- page header with a search input (matches the recipe name as the client localizes it from the ID, and falls back to the ID)
- profession filter chips
- a results table: recipe (with its item icon and tooltip), profession, members who know it (names, the online ones first or highlighted), last update
- empty states: "No recipes shared yet" and "Open your professions once so the guild can see your recipes"
- a "My professions" card with the last scan time for each profession

**Feature review decisions (2026-10-19):**
1. **Search and filters (revised 2026-10-19).**
   - A search box matches the recipe name, localized from the ID at display time and cached per session. It runs on a short debounce over the in-memory index, never on every keystroke against the saved data.
   - **The profession filter is a single dropdown, not chips:** "All professions" (default) or one profession. It lists only the professions that have shared recipes.
   - The "Connected only" toggle stays as a separate button next to it.
2. **Results table.** Recipe (item icon, name in the item quality color, game tooltip on hover), profession, and the members who know it.
   - **Online members first, with a `success` dot**, then the rest in `muted`.
   - A "Connected only" filter chip hides offline crafters.
   - Online state comes from the guild roster: `GetGuildRosterInfo` returns `isOnline` (9th value), but `Platform.GetGuildRosterEntry` does not expose it today. Add it, and keep it in `GuildRoster` entries.
3. **"Ask" button per crafter.** It opens the chat edit box prefilled with a whisper to that member, e.g. "/w Name Could you craft me [item link]?". **The player sends it with Enter; the addon never sends a whisper on its own.** Candidate API: `ChatFrame_OpenChat(text)` or `ChatFrameUtil.OpenChat`. Measure it on Forever and record it in `docs/API_NOTES.md`. Disable the button for offline members.
4. **Reagents are not synced.** The game tooltip on the recipe or item shows them, so the synced payload stays IDs only.
5. **Members without the addon do not appear**, since their recipes are unknown.
6. **"My professions" card** at the top: each own profession with the time of its last scan, and a hint "Open this profession's window so the guild sees your latest recipes" when it has never been scanned or the skill changed since the last scan.

Everything in "Agreed so far" above still applies: the scan on opening the window, automatic sync, the size limits, privacy, and the client APIs to measure first.

---

## 4. Secondary windows: **approved 2026-10-19**

Mocked in the canvas artboard "Ventanas secundarias".

1. **Loot popup (`UI/LootPopup.lua`).**
   - A small floating card in the theme (width about 380 px, no title bar art), shown only to members of the session's roster (3.4.1).
   - Each pending item is a row: icon, name in its quality color, "Spec: Tank (from your profile)", and the Main spec / Off spec / Other / Pass buttons. Pass is a ghost button; the others are secondary, with the response color on hover.
   - A 2 px accent bar under each row shows the time left (the existing countdown).
   - Several items arriving at once stack as rows in the same card, newest on top, with at most N visible and the rest scrolling.
   - A "Hide" button minimizes the card; the pending items reappear on the next session event or from the Loot tab.
   - Keep `Controller` (lockdown wait, dismissal, timeout) unchanged; only the frame is rebuilt with the kit.
2. **Voting window (`UI/VotingFrame.lua`).**
   - Same chrome as the main window: header with the title, the session count and close; resizable, with its position saved via `UI.ApplyWindowStatus`.
   - With more than one open session, a left list of sessions (item icon and name, candidate count; the selection style is the nav style). The right side shows the selected session with the same candidates table and per-row Vote / Award (inline reason) as the Loot tab, so the two share one component.
   - Auto-opens only for that roster's `rl` and `council` members and for the GM. Keep `Controller` as is.
   - Map `NEED_COLORS` to tokens: main = success, off = warning, other = accent.
3. **Export / Import (`UI.ShowTransfer`).**
   - A modal centered over the main window, with the main window dimmed behind it (a black overlay at 0.5).
   - **Export:** a read-only multiline box that selects all its text when shown and on focus, plus the hint "Press Ctrl+C to copy". Addons cannot write to the clipboard.
   - **Import:** an empty multiline box with the hint "Paste the text (Ctrl+V)", then an "Import" primary button and Cancel. The result goes to the banner of the main window. The import role gate is unchanged.
   - Escape closes the modal.
4. **Minimap button (`UI/MinimapButton.lua`).**
   - Keep the logo inside the gold ring and the drag behavior: this is minimap convention.
   - **The right-click menu is a dark popover in the theme**, holding the tabs the role can open (same list as the sidebar) and "Settings", which opens the main window with the settings popover.
   - **Remove "Request a sync"** from the menu entries built in `ViewModel` (principle 0.1).
   - Left click still toggles the main window.

## 5. Implementation phases (for the implementing agent)

Deliver each phase as its own reviewable change (chained PRs when one exceeds ~400 changed lines). Within each phase, keep tests and docs with the code they belong to. Do not start a phase before the previous one is merged, unless it is marked independent.

| Phase | Scope | Done when |
|---|---|---|
| **P0. Measure client APIs** (independent) | Measure on Forever and record in `docs/API_NOTES.md`: `IsGuildLeader`, `GetGuildInfo` rank index, `GetGuildRosterInfo` isOnline; group APIs (`IsInRaid`, `GetNumGroupMembers`, `GetRaidRosterInfo`, `UnitName("partyN")`); profession and recipe APIs (`GetProfessions` secondaries, `C_TradeSkillUI.*`, `TRADE_SKILL_*` events); loot APIs (`LOOT_OPENED`, `GetLootSlotLink`, `ENCOUNTER_LOOT_RECEIVED`); `ChatFrame_OpenChat` / `ChatFrameUtil.OpenChat`. | Every row has a measured result. The features that depend on an unavailable API are marked to ship without it. |
| **P1. Kit foundation** | `UI/Kit/`: Theme tokens (1.1), fonts (1.2, Fira Sans with OFL), Pixel and Border helpers, and every widget in section 2 including DatePicker. A kit fake for `tests/ui_smoke_spec.lua`. | The kit loads in the client. Unit tests cover the pure helpers. The smoke test fake is in place. |
| **P2. Window shell** | New main window: header (logo, version, sync pill, gear, close), sidebar with groups and the user card, content scroll, banner, settings popover (language, minimap, blacklist sound). Lazy translations and the language setting (3.1). | Every tab still renders through the old Draw functions inside the new shell. Switching the language redraws everything in the chosen language. Tests pass. |
| **P3. Roles and rosters domain** | 3.4.2 (GM-only admin by rank index, assigned roles, `ROLE_SOURCE`, beta list off) and 3.4.1 (roster records, membership, event, template and loot `rosterId`, receiver checks, migration). `PROTOCOL.md`, `PRIVACY.md` and `USER_GUIDE.md` updates. | Sync specs cover the acceptance and rejection cases listed in 3.4.1 and 3.4.2. Older clients tolerate the new fields. |
| **P4. Automatic sync changes** | Principle 0.1: remove the manual sync and publish controls; event-driven profile publish; cooldown retry; Readiness auto-refresh. | Unit tests for the debounce and the cooldown retry. No sync button is left in any window or menu. |
| **P5. Tab migration** | In this order: Home (3.1), Profile (3.2), Readiness (3.3), Members (3.8 + 3.4.2 UI), Raid (3.4), Loot (3.5), PvP (3.6), Blacklist (3.7), Rules (3.9). Add the new ViewModel row and structure functions with tests. | Each tab matches its section and the mockup. The smoke test draws every tab for GM, rl, council, member and no-roster. |
| **P6. Professions** | 3.10: scan, storage, sync message type, receiver validation and caps, the tab UI, Profile's professions line. | Sync specs mirror `pvp_sync_spec.lua`. Size limits are respected. Privacy docs are updated. |
| **P7. Secondary windows** | Section 4: loot popup, voting window, transfer modal, minimap menu. | The Controllers are unchanged and their tests still pass. The smoke test covers the new frames. |
| **P8. Cleanup** | Remove AceGUI from `embeds.xml`, the TOC and `Libs/` once no window uses it. Final `USER_GUIDE.md` pass. | `luacheck`, `busted` and the smoke test are green, and no AceGUI references remain. |

**General rules for the implementer:**
- Follow the existing architecture: domain in `Domain/`, decisions in ViewModel or Controllers (tested), thin frames.
- Every user-visible string goes through `L()`, with an `esES` entry. Never translate wire values.
- Client APIs go through `Core/Platform.lua` behind `pcall`.
- Respect encounter lockdown everywhere.
- When this plan and the mockup disagree, this plan wins. When the code disagrees with a "verified" note here, re-check before building on it.

| Window | File | Today | Redesign direction |
|---|---|---|---|
| Loot popup | `UI/LootPopup.lua` | 440 px wide, rows of 58 px: item plus main/off/other/pass buttons, with a countdown | small floating card in the same theme; the item row has a buttons segment and a thin countdown bar in accent |
| Voting window | `UI/VotingFrame.lua` | 760 × 460 AceGUI: a candidates table (response, upgrade, votes), vote, award, close | same window chrome; shared data table; need colors mapped to tokens (main = success, off = warning, other = accent) |
| Transfer | `UI/Main.lua` `UI.ShowTransfer` | AceGUI Frame with a MultiLineEditBox | small modal in the theme: monospace-free input area, Copy/Import buttons |
| Minimap button | `UI/MinimapButton.lua` | logo in the gold ring; right-click menu | keep the ring (it is minimap convention); restyle the menu if it is custom |

---

## 6. Decisions log

| Date | Decision |
|---|---|
| 2026-10-19 | Full visual redesign approved, starting from the mockup. Base palette "ember" (warm near-black), not Polestar's navy "dusk". Every tab must follow this design. |
| 2026-10-19 | Work order: review each feature first and record it here, then hand implementation to an agent. |
| 2026-10-19 | Home: add the "Next raid event" and "Open loot sessions" cards; move the minimap settings to a gear button in the header. |
| 2026-10-19 | Profile: show "Last published"; edits save on focus loss or on change, with no Save button. |
| 2026-10-19 | Sync is fully automatic (section 0.1): no manual sync or publish buttons; profile changes publish on game events; cooldown changes retry automatically. |
| 2026-10-19 | Settings (header gear): Spanish/English/automatic language selector; requires making load-time translations lazy. |
| 2026-10-19 | Profile layout: line 1 name/class/level/item level; line 2 main and second spec (second optional, "None"); line 3 professions, primary and secondary. |
| 2026-10-19 | New Professions tab: scan learned recipes, sync them automatically, search who can craft a recipe. Client APIs to be measured first. |
| 2026-10-19 | Raid approved: date picker, event list with status and Upcoming/Past filter, new-event form, Export/Import in an overflow menu, "Fill from current group" attendance, assignments by encounter, template cards, danger delete, table reports. |
| 2026-10-19 | Raid rosters: admins assign players to rosters; members see only their roster's raid info; admins pick a roster with a selector. UI visibility filter only (data still reaches every guild client). |
| 2026-10-19 | Only admins manage rosters. Until guild ranks exist, addon roles (member, rl, council) are assigned by admins in the Members tab; admin itself still comes from the rank or the beta list. |
| 2026-10-19 | For now the GM (rank index 0) is the only admin; admin cannot be granted from the addon; the beta admin list gets disabled. To be revisited once the guild ranks exist. |
| 2026-10-19 | Rosters: no roster → no events (notice); templates, reports and loot sessions follow the roster; the loot popup and voting only involve that roster's members. |
| 2026-10-19 | Loot approved: event selector, item preview, optional boss-loot strip (API to measure), session cards with per-row Vote/Award and inline reason, apply with the spec from Profile, collapsible minutes. |
| 2026-10-19 | PvP approved: sub-tabs, Today/Total stat grids, sortable ranking with search, accent own row and top-3 colors, kill list with killing-blow badge, GM-only reset card. |
| 2026-10-19 | Blacklist approved: inline add with a counter, searchable table, inline reason edit for the author or GM, GM remove with confirm, "In your group" badge, alert-sound switch in settings. |
| 2026-10-19 | Members approved: whole guild with a "No addon" badge, full table with stale badge, search and filters, expandable row detail, GM role and roster controls. |
| 2026-10-19 | Rules approved: revision header, automatic/manual badges, in-place edit that keeps the id, per-kind add form with inline errors, confirmed "Use the starting list", link to Readiness. |
| 2026-10-19 | Professions approved: search and profession chips, online crafters first, "Connected only" filter, "Ask" prefills a whisper the player sends, no reagent sync, no members without the addon, "My professions" scan card. |
| 2026-10-19 | Professions filter: one profession dropdown instead of chips; search and "Connected only" stay. |
| 2026-10-19 | Secondary windows approved: themed loot popup with stacked items, voting window sharing the Loot table, export/import modal with Ctrl+C/V hints, dark minimap menu without the sync entry. Implementation phases P0–P8 defined. |
| 2026-10-19 | Readiness refreshes on its own on aura, gear, level and profession events while it is visible. |
