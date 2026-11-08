# Nrage Assistant: user guide

Guild coordination for Nrage: your character sheet, raid readiness, raid events with attendance and
assignments, and the loot council. Everything here is for **Alliance characters of the Nrage guild on the PvP
ruleset**; on any other character the addon switches itself off and says why once.

> The addon is in beta. Open questions and things still to be verified in game are tracked as issues.

## Getting started

1. Install it as described in the [README](../README.md).
2. Log in with a Nrage character. You should see `Nrage Assistant <version> loaded. Click the minimap button or type /nrage to open the window.` (in Spanish on a Spanish client)
3. Click the minimap button, or type `/nrage`, to open the window. Everything is done from there: there are no
   other commands to learn.
4. Something looks wrong? Run `/nrage debug selftest` and `/nrage debug info`, and send the output to an officer.

Only three commands exist: `/nrage` (opens the window), `/nrage help` (this short list) and `/nrage debug ...`
(diagnostics for developers).

## The window and the settings

The window has a header (logo, version, a pill that shows the sync state, the gear and the close button), a sidebar
with one entry per tab, in two groups, and your character card at the bottom, and the page of the selected tab. Drag
the header to move it and the corner to resize it; the size and position are remembered.

The **Guild** group is for everybody, though what you see depends on your guild rank and your roster:

- **Home** and **Professions**, and **PvP** (the player views), are open to every rank.
- **Raid** lists the upcoming events of your roster (and the guild-wide ones), soonest first, read-only. From the
  Roster rank up, with a roster.
- **Raid check** is your own checklist, measured with the rules of your roster. From the Roster rank up, with a roster.
- **Loot**: from the Roster rank up, with a roster. Guild and co-guild masters see every roster.

The **Admin** group appears from the Officer and RL ranks up:

- **Raid** is where events, attendance, assignments, templates and reports are managed (Officer and RL on their own
  roster, GM and CoGM on any). It has a roster selector when you may act on every roster, and a label with your roster
  otherwise.
- **Roster rules** and **Members** (Officer and RL, GM and CoGM).
- **PvP** holds the season admin: approvals, missions, season, prizes and deliveries (GM and CoGM only).
- **Installed check** lists who runs the addon and which version (GM and CoGM only; see *Installed check* below).

A tab you cannot see, or one that no longer exists in the sidebar (Profile, Layers and Blacklist are hidden for now),
opens Home instead. A player without a roster only sees Home, Professions and PvP.

The **gear** in the header opens the settings, which are the same from every tab and are saved for your whole account:

- **Language**: *Automatic (game language)*, *Español* or *English*. Automatic follows the game client: Spanish on a
  Spanish client (Spain or Latin America), English on any other. The window is drawn again at once when you change it.
- **Show the minimap button**, and **Button position** with *Reset* to put it back in its default place.
- **Share my position** (off by default): guildmates see where you are on the minimap and the world map. Turn it off
  and the addon tells the guild to forget you. See *Guild map* below.
- **Show guildmates on the minimap** and **Show guildmates on the world map** (both on by default): whether you see
  the pins of your guildmates. They do not need you to share your own position.
- **Blacklist alert sound**: when it is off, a listed player in your group still shows the chat line and the
  warning, but plays no sound.

Everything you read is translated: the window, the messages after each action, the readiness checklist, your profile,
the reports and the sync state. The exceptions are the output of `/nrage debug ...`, which is for developers, the
names of brands and of game items, the words you type yourself (a role, a rule's name) and what goes over the wire,
which is always the same, so players on different languages see the same data.

## The minimap button

The guild logo sits in a gold ring on the edge of the minimap, like most addons' buttons.

- **Left click** opens the window; **drag** it to move it around the minimap.
- **Hover** shows the next event and its start time, your readiness score and how many messages wait in the sync
  queue. It reads only what the addon already holds, so it is safe during an encounter.
- A small **warning mark** on the button means the silent self test, run a few seconds after login, found
  something missing or broken on this client; the tooltip says what. Nothing is printed to chat.
- **Right click** opens a dark menu with the tabs you can open (the same list as the sidebar), **Intel** (shows or
  hides the Intel window) and the settings.
- In the **settings** (the gear of the window) you can hide it or show it again, and put it back in its default
  place. The position and whether it is hidden are saved for your whole account.
- The logo also appears as the addon's icon in the AddOns list and at the top of the window's Home tab.
- The button only shows on characters where the addon is active.

## What you can do, by role

Your role is your **guild rank**. The addon matches the rank by its name, so the ranks in the game have to be called
exactly `GM`, `CoGM`, `Oficial`, `RL`, `Roster`, `Miembro` and `Alter`. The guild master is always recognised by holding
rank index 0 of the guild, never by the name of the character or of the rank. Nothing is assigned inside the addon:
to change a role, change the rank in the game. The addon never trusts what a message says about its sender: every
client checks the sender against its own copy of the guild roster.

| Rank | Role | Can (so far) |
|---|---|---|
| GM, CoGM | gm, cogm | everything, for every roster: events, loot, rosters and members, the readiness rules, moderation, removing players from the blacklist and all of the PvP seasons |
| Oficial | officer | events and loot of their own roster, plus everything a member can |
| RL | rl | events and loot of their own roster, plus everything a member can |
| Roster | roster | put yourself forward for loot (in your roster), plus everything a member can |
| Miembro | member | see shared data, edit and publish your own sheet, add players to the blacklist |
| Alter | alter | the same as a member, except putting yourself forward for loot |

A rank with any other name counts as **Alter**. **If you rename a rank in the game without updating the addon, everybody
in that rank becomes an Alter** until the addon knows the new name (`RANK_ROLES` in `Core/Constants.lua`).

The PvP officer flag is gone: approving claims, marking deliveries and the rest of the PvP administration are for GM
and CoGM only. Rosters and assignments can only be changed by GM and CoGM for now; the readiness rules of a roster by GM, CoGM and the RL of that roster.

**Rosters.** The guild master defines the rosters (teams) and puts each player in at most one. A player sees the
events, reports and loot of their own roster only (events made before rosters existed stay visible to every
member who has a roster until the guild master assigns one); a player with no roster sees none and is told to ask
for one. The guild master can look at any roster, or all of them, with the roster selector. This is a filter in the
window, not a lock: the raid data still reaches every member with the addon (see `docs/PRIVACY.md`).

## Your sheet (profile)

The **Profile** tab shows what the addon knows about your character, each value with where it comes from:
`verified` (read from the game), `declared` (typed by you) or `received` (from someone else). A value the game
cannot give is shown as `unknown`; it is never guessed.

Under *Your declared details* you can type your role, your main character and some notes; press Enter to save each
one, and leave it empty to clear it. The **Home** tab shows your guild rank and the role the addon gives you for it.

### Sharing your sheet

Your sheet is shared with the guild automatically, with no switch: after you log in, and again whenever it changes.
It holds your class, level, item level, professions and skill, and your declared role and main. Your declared
**notes stay on this computer**, and so do the enchants and buffs that the readiness checks read from your character.

- The Profile tab lists exactly what is shared and what stays private. There is no publish button: a change to your
  gear, level or professions is shared a few seconds after it happens (a change made right after another one waits
  for the short pause between publications and is then sent by itself).
- What other clients already received cannot be taken back.

**Addon messages are not private.** Anyone in the guild running the addon can read what you publish.
See [PRIVACY.md](PRIVACY.md).

## Readiness

The **Readiness** tab shows a checklist with the result of each item and a score that always shows its denominator,
for example `1/3 met, 2 unknown`. An item nobody has confirmed is `unknown`, and unknown is never counted as met.

Manual items are confirmed from a dropdown on the same tab (the score updates at once). A `waived` item leaves the
score but stays visible.

The checklist keeps itself up to date: while the Readiness tab (or the readiness card of Home) is on screen it is
read again when your auras, gear, level or skills change, so a flask that ran out stops counting as met without you
doing anything. Nothing about your readiness is sent to the guild.

Each roster has its own rules. GM and CoGM change those of any roster, the RL those of their own roster, and the
Officer sees them all read-only. A roster that never had its own rules uses the starting list (level 60, item level, role, consumables and enchants); GM and CoGM pick which roster to measure against in the
Raid check tab, everybody else is measured against their own. Items measured from the game
(level, item level, professions, enchants and buffs) say where their value comes from; the rest are confirmed by
hand.

The **Roster rules** tab of the Admin group is the editor of the readiness rules. It lists the rules in force with a
Remove button each, and a form to add one: pick the kind (minimum level, minimum item level, enchanted slots, active
buff, profession, declared field, or confirmed by hand), give it a name and type the details (the hint under Details
says what fits). Slots can be typed by name (`mainhand`, `chest`, `back`...) or number, and buffs by spell id or name.
Every change replaces the whole set of the selected roster; **Use the starting list** puts the starting rules back.

## Raid events

Events are created by raid leaders and admins and are shared with the guild. Names of characters can have several
words (`Yonemon Gg`); in the window you pick a member from a list, so nothing needs quoting.

The **Raid** tab of the Admin group has the events on the left (with a field to create one, and the *Export* and *Import* buttons) and
the selected event on the right. The right side has a sub-tab for each thing you can do: *Summary* (everyone:
status, attendance counts and assignments), and, depending on your rank, *Details* (rename, status, start time in
your local time, and *Delete this event*, which asks you to click twice), *Attendance* (a state dropdown for each member already recorded, and a search to add somebody
else: type part of a name, press Enter, and click the name), *Assignments* (add by picking a member and typing the
encounter, remove) and *Templates* (save, apply, delete, and the suggestions that match the event). Everyone also gets
*Reports*. Sub-tabs your rank does not allow are not shown. Creating an event opens it.

### Attendance

States: `invited`, `confirmed`, `present`, `late`, `leftEarly`, `absent`, `excused`, `unknown`. Only an explicit
entry changes a state: a disconnect is never turned into an absence.

### Templates

*Save this event's assignments as* keeps an event's assignments under a name, and *Apply to this event* adds them to
another event (skipping any it already has), so the same boss does not have to be planned again each week.
Templates stay on your client and are not shared.

A newly created event is opened at once, and any template whose name matches the event's title or instance (for
example a template called *Molten Core* for an event *Molten Core night*) is offered as a button. Nothing is applied
until you click it, and a template the event already has in full is not offered.

### Reports

The **Reports** sub-tab shows the attendance and loot reports of the selected event, or of every event (*Scope*).

Attendance counts `present`, `late` and `leftEarly` as attended and `absent` as missed, and prints the rate with
its denominator (`2/3 (67%)`). `invited`, `confirmed`, `unknown` and `excused` stay out of the rate but are
listed, so unknown data never improves or worsens anyone's numbers. Planned and cancelled events do not count.

### Moving data around

- **Export** opens a window over the dimmed addon with a text (starting with `NRAGE1:`) with all events, attendance,
  assignments, loot awards and deletions. The text is selected: press Ctrl+C to copy it (an addon cannot write to the
  clipboard). Escape closes the window.
- **Import** opens a window with an empty box: paste the text (Ctrl+V) and press *Import*. The result shows in the
  banner of the main window. Only raid leaders and admins see it. Pasted text is
  checked exactly like data received over the guild channel: it never overwrites newer edits, and importing the same
  text twice changes nothing. Imported data stays on your client.

## Loot council

Sessions belong to a raid event. They are opened **after the encounter**: while chat messaging is locked down
the addon refuses, because the session could not be announced.

When a session opens, the members of that event's roster (and the guild master) get the **Nrage Loot** card with
the item and the buttons *Main spec*, *Off spec*, *Other* and *Pass*. A click puts you forward with your declared
role (or your class) as the spec; nothing is sent before that. Several items stack in the same card (the newest on
top, three at a time, the rest scroll) and a thin bar under each one shows the time left. The card never appears
during an encounter lockdown (it waits) and does not pop up for sessions that were already open when you logged in.
*Hide* (the cross) puts it away without passing: the items come back with the next session or from the Loot tab.
An item you do not answer is passed on after 60 seconds (only on your screen; nothing is sent).
The Loot tab remains for choosing a different spec or adding an upgrade.

GM, Officer and RL ranks also get the **Nrage Loot Council** voting window, which opens by itself when a session
opens. It shows the same candidates table as the Loot tab (name, response, spec, upgrade and votes) with *Vote* and
*Award* buttons, *Close without awarding*, and, when several sessions are open, a list on the left to switch between
them. Click a column title to sort by it (again to reverse), and use the dropdown to see only main spec, off spec
or other. *Award* asks for a reason and then *Confirm award* before it gives the item away. Votes follow
the guild's visibility setting, and the window waits during an encounter lockdown. The Loot tab has an
*Open the voting window* button to bring it back. The item's level and slot show under its name
when the client knows them. It does not show equipped gear yet.
Windows remember where you leave them and how big they are.

The **Loot** tab does all of this from the window. Pick the event, and each session shows its item, candidates,
votes and decision. Anyone can apply to an open session with a spec and the *Apply: main / off / other* buttons
(the upgrade field is optional). Council and admins also get *Vote*, *Award* (with a reason) and *Close without
awarding*, and a field to paste or shift-click an item link to open a session. Controls your role does not allow
are not shown. At the bottom, *Show the minutes* lists every closed session of the event with what was decided and
why (never who voted for whom). Raid leaders, council and admins can change their vote; awarding closes the session.

Votes are open: they are visible to everyone while a session is open, and the guild chose it that way. Addon
messages are not confidential, so a secret vote could not be guaranteed anyway. A late joiner receives the minutes (awards and open sessions), not the votes of past
sessions.

## PvP

The **PvP** tab has six sub-tabs: **Season**, **Missions**, **Stats**, **Recent kills**, **History** and **Intel** (see *Intel*). The admin
views are the **PvP** tab of the Admin group (guild master and co-guild master only). The seasons are described under *PvP seasons* below. **Stats** holds two views, *My
stats* and *Kill ranking*, which are described here. *My stats* counts your kills automatically, split into **open world** and **battleground**, with
a total and today's count for each. Days follow the server's date in UTC, so they may not start at your midnight.

- **Honourable kills** are read from the game's own honour counter, so group credit counts whenever you receive
  honour. Kills made before you logged in or reloaded are not counted again.
- **Killing blows** would come from the combat log, which the client protects: asking for it makes the client
  show a "blocked action" warning at login. They are off for now, so the killing blows section is not shown.
- If the client does not offer the honour counter either, the tab says so and counts nothing.
- The counters are saved per character. Daily counts are kept for 30 days.
- They are also **shared with the guild automatically**: about a minute after a kill, every guild member running
  the addon receives your counters, and you receive theirs. There is nothing to switch on, and nothing is sent
  during an encounter. The counters are not encrypted (see the privacy notes).
- Your **PvP rank** is at the top, with how many honourable kills you need for the next one. There are 14 ranks,
  from Private to Grand Marshal; only honourable kills count towards them. Their names and thresholds are set in
  `PVP_RANKS` in `Core/Constants.lua`, and the thresholds there are placeholders until the guild decides them.

### Kill ranking

The **Kill ranking** view of the Stats sub-tab lists the guild members whose counters you have received, plus you (your row is green and
always uses your own counters). Columns: name, PvP rank, honourable kills in the open world, in battlegrounds and
in total, killing blows (only shown when you or somebody else can count them) and when the record was last
updated. The default order is total honourable kills, highest first; click a column title to sort by it and click
it again to reverse. Members who are no longer in the guild are not listed, and at most 100 rows are drawn.

The **Show** selector switches between **Total** (all time, the default) and **Today**. Today follows the server
day in UTC: members who have not sent anything today show zero, and the rank column still shows the all-time rank.

A member who logs in late gets the ranking from the snapshot a raid leader or admin whispers. The numbers can lag
a minute behind, and a modified addon could report more than it earned: the addon only checks that totals never
go down and do not grow faster than about 300 honourable kills an hour.

Admins find the **Kill counters** card in *Admin > Season*: they pick a member and press *Reset PvP counters* (and
*Confirm*). It acts at once, says the revision it used, and zeroes the member on every client; the member's own
counters are zeroed when their client receives it, or at their next login. Nobody else can do this.

### Recent kills

The **Recent kills** sub-tab is your own kill history, newest first, for example
`12:04  Me killed Zed (open world, killing blow)`. It shows your last 50 kills since you logged in; nothing is
saved. There are no switches: all your kills are always shared with the guild.

- Your kills are sent to the guild about 5 seconds after they happen, at most 5 per minute, and never during an
  encounter. This shares the names of the players you kill (see the privacy notes). The kills of other members are
  not shown here.
- The feed needs the name of the killed player. If this client does not give it, the tab says the feed is not
  available and nothing is shown or sent.

## PvP seasons

A PvP season is a period in which missions give points and the points make a ranking. Everything is in the PvP tab
(`docs/PVP_MISSIONS_PLAN.md`); the `/nrage pvp ...` commands still work for testing.

| Who | Can |
|---|---|---|
| member | everybody the guild master did not assign a role to | see shared data, edit and publish your own sheet, put yourself forward for loot (in your roster), add players to the blacklist |
| rl | raid leaders, assigned | everything a member can, plus create and edit events, record attendance and manage assignments, only for the events of their own roster |
| council | loot council, assigned | everything a member can, plus open loot sessions, vote and award, only for the sessions of their own roster |
| admin | the guild master | everything above for every roster, plus managing rosters and roles, the readiness rules, moderation and removing players from the blacklist, and all of the PvP seasons |

**PvP officer** is not a role but a flag the guild master gives to a player on top of whatever role they have (see *PvP seasons* below). A PvP officer can approve and reject mission claims and mark prizes as delivered, and nothing else.

**Rosters.** The guild master defines the rosters (teams) and puts each player in at most one. A player sees the
events, reports and loot of their own roster only (events made before rosters existed stay visible to every
member who has a roster until the guild master assigns one); a player with no roster sees none and is told to ask
for one. The guild master can look at any roster, or all of them, with the roster selector. This is a filter in the
window, not a lock: the raid data still reaches every member with the addon (see `docs/PRIVACY.md`).

## Your sheet (profile)

The **Profile** tab shows what the addon knows about your character, each value with where it comes from:
`verified` (read from the game), `declared` (typed by you) or `received` (from someone else). A value the game
cannot give is shown as `unknown`; it is never guessed.

Under *Your declared details* you can type your role, your main character and some notes; press Enter to save each
one, and leave it empty to clear it. The **Home** tab shows your guild rank and the role the addon gives you for it.

### Sharing your sheet

Your sheet is shared with the guild automatically, with no switch: after you log in, and again whenever it changes.
It holds your class, level, item level, professions and skill, and your declared role and main. Your declared
**notes stay on this computer**, and so do the enchants and buffs that the readiness checks read from your character.

- The Profile tab lists exactly what is shared and what stays private. There is no publish button: a change to your
  gear, level or professions is shared a few seconds after it happens (a change made right after another one waits
  for the short pause between publications and is then sent by itself).
- What other clients already received cannot be taken back.

**Addon messages are not private.** Anyone in the guild running the addon can read what you publish.
See [PRIVACY.md](PRIVACY.md).

## Readiness

The **Readiness** tab shows a checklist with the result of each item and a score that always shows its denominator,
for example `1/3 met, 2 unknown`. An item nobody has confirmed is `unknown`, and unknown is never counted as met.

Manual items are confirmed from a dropdown on the same tab (the score updates at once). A `waived` item leaves the
score but stays visible.

The checklist keeps itself up to date: while the Readiness tab (or the readiness card of Home) is on screen it is
read again when your auras, gear, level or skills change, so a flask that ran out stops counting as met without you
doing anything. Nothing about your readiness is sent to the guild.

Each roster has its own rules. GM and CoGM change those of any roster, the RL those of their own roster, and the
Officer sees them all read-only. A roster that never had its own rules uses the starting list (level 60, item level, role, consumables and enchants); GM and CoGM pick which roster to measure against in the
Raid check tab, everybody else is measured against their own. Items measured from the game
(level, item level, professions, enchants and buffs) say where their value comes from; the rest are confirmed by
hand.

The **Roster rules** tab of the Admin group is the editor of the readiness rules. It lists the rules in force with a
Remove button each, and a form to add one: pick the kind (minimum level, minimum item level, enchanted slots, active
buff, profession, declared field, or confirmed by hand), give it a name and type the details (the hint under Details
says what fits). Slots can be typed by name (`mainhand`, `chest`, `back`...) or number, and buffs by spell id or name.
Every change replaces the whole set of the selected roster; **Use the starting list** puts the starting rules back.

## Raid events

Events are created by raid leaders and admins and are shared with the guild. Names of characters can have several
words (`Yonemon Gg`); in the window you pick a member from a list, so nothing needs quoting.

The **Raid** tab of the Admin group has the events on the left (with a field to create one, and the *Export* and *Import* buttons) and
the selected event on the right. The right side has a sub-tab for each thing you can do: *Summary* (everyone:
status, attendance counts and assignments), and, depending on your rank, *Details* (rename, status, start time in
your local time, and *Delete this event*, which asks you to click twice), *Attendance* (a state dropdown for each member already recorded, and a search to add somebody
else: type part of a name, press Enter, and click the name), *Assignments* (add by picking a member and typing the
encounter, remove) and *Templates* (save, apply, delete, and the suggestions that match the event). Everyone also gets
*Reports*. Sub-tabs your rank does not allow are not shown. Creating an event opens it.

### Attendance

States: `invited`, `confirmed`, `present`, `late`, `leftEarly`, `absent`, `excused`, `unknown`. Only an explicit
entry changes a state: a disconnect is never turned into an absence.

### Templates

*Save this event's assignments as* keeps an event's assignments under a name, and *Apply to this event* adds them to
another event (skipping any it already has), so the same boss does not have to be planned again each week.
Templates stay on your client and are not shared.

A newly created event is opened at once, and any template whose name matches the event's title or instance (for
example a template called *Molten Core* for an event *Molten Core night*) is offered as a button. Nothing is applied
until you click it, and a template the event already has in full is not offered.

### Reports

The **Reports** sub-tab shows the attendance and loot reports of the selected event, or of every event (*Scope*).

Attendance counts `present`, `late` and `leftEarly` as attended and `absent` as missed, and prints the rate with
its denominator (`2/3 (67%)`). `invited`, `confirmed`, `unknown` and `excused` stay out of the rate but are
listed, so unknown data never improves or worsens anyone's numbers. Planned and cancelled events do not count.

### Moving data around

- **Export** opens a window over the dimmed addon with a text (starting with `NRAGE1:`) with all events, attendance,
  assignments, loot awards and deletions. The text is selected: press Ctrl+C to copy it (an addon cannot write to the
  clipboard). Escape closes the window.
- **Import** opens a window with an empty box: paste the text (Ctrl+V) and press *Import*. The result shows in the
  banner of the main window. Only raid leaders and admins see it. Pasted text is
  checked exactly like data received over the guild channel: it never overwrites newer edits, and importing the same
  text twice changes nothing. Imported data stays on your client.

## Loot council

Sessions belong to a raid event. They are opened **after the encounter**: while chat messaging is locked down
the addon refuses, because the session could not be announced.

When a session opens, the members of that event's roster (and the guild master) get the **Nrage Loot** card with
the item and the buttons *Main spec*, *Off spec*, *Other* and *Pass*. A click puts you forward with your declared
role (or your class) as the spec; nothing is sent before that. Several items stack in the same card (the newest on
top, three at a time, the rest scroll) and a thin bar under each one shows the time left. The card never appears
during an encounter lockdown (it waits) and does not pop up for sessions that were already open when you logged in.
*Hide* (the cross) puts it away without passing: the items come back with the next session or from the Loot tab.
An item you do not answer is passed on after 60 seconds (only on your screen; nothing is sent).
The Loot tab remains for choosing a different spec or adding an upgrade.

GM, Officer and RL ranks also get the **Nrage Loot Council** voting window, which opens by itself when a session
opens. It shows the same candidates table as the Loot tab (name, response, spec, upgrade and votes) with *Vote* and
*Award* buttons, *Close without awarding*, and, when several sessions are open, a list on the left to switch between
them. Click a column title to sort by it (again to reverse), and use the dropdown to see only main spec, off spec
or other. *Award* asks for a reason and then *Confirm award* before it gives the item away. Votes follow
the guild's visibility setting, and the window waits during an encounter lockdown. The Loot tab has an
*Open the voting window* button to bring it back. The item's level and slot show under its name
when the client knows them. It does not show equipped gear yet.
Windows remember where you leave them and how big they are.

The **Loot** tab does all of this from the window. Pick the event, and each session shows its item, candidates,
votes and decision. Anyone can apply to an open session with a spec and the *Apply: main / off / other* buttons
(the upgrade field is optional). Council and admins also get *Vote*, *Award* (with a reason) and *Close without
awarding*, and a field to paste or shift-click an item link to open a session. Controls your role does not allow
are not shown. At the bottom, *Show the minutes* lists every closed session of the event with what was decided and
why (never who voted for whom). Raid leaders, council and admins can change their vote; awarding closes the session.

Votes are open: they are visible to everyone while a session is open, and the guild chose it that way. Addon
messages are not confidential, so a secret vote could not be guaranteed anyway. A late joiner receives the minutes (awards and open sessions), not the votes of past
sessions.

## PvP

The **PvP** tab has six sub-tabs: **Season**, **Missions**, **Stats**, **Recent kills**, **History** and **Intel** (see *Intel*). The admin
views are the **PvP** tab of the Admin group (guild master and co-guild master only). The seasons are described under *PvP seasons* below. **Stats** holds two views, *My
stats* and *Kill ranking*, which are described here. *My stats* counts your kills automatically, split into **open world** and **battleground**, with
a total and today's count for each. Days follow the server's date in UTC, so they may not start at your midnight.

- **Honourable kills** are read from the game's own honour counter, so group credit counts whenever you receive
  honour. Kills made before you logged in or reloaded are not counted again.
- **Killing blows** would come from the combat log, which the client protects: asking for it makes the client
  show a "blocked action" warning at login. They are off for now, so the killing blows section is not shown.
- If the client does not offer the honour counter either, the tab says so and counts nothing.
- The counters are saved per character. Daily counts are kept for 30 days.
- They are also **shared with the guild automatically**: about a minute after a kill, every guild member running
  the addon receives your counters, and you receive theirs. There is nothing to switch on, and nothing is sent
  during an encounter. The counters are not encrypted (see the privacy notes).
- Your **PvP rank** is at the top, with how many honourable kills you need for the next one. There are 14 ranks,
  from Private to Grand Marshal; only honourable kills count towards them. Their names and thresholds are set in
  `PVP_RANKS` in `Core/Constants.lua`, and the thresholds there are placeholders until the guild decides them.

### Kill ranking

The **Kill ranking** view of the Stats sub-tab lists the guild members whose counters you have received, plus you (your row is green and
always uses your own counters). Columns: name, PvP rank, honourable kills in the open world, in battlegrounds and
in total, killing blows (only shown when you or somebody else can count them) and when the record was last
updated. The default order is total honourable kills, highest first; click a column title to sort by it and click
it again to reverse. Members who are no longer in the guild are not listed, and at most 100 rows are drawn.

The **Show** selector switches between **Total** (all time, the default) and **Today**. Today follows the server
day in UTC: members who have not sent anything today show zero, and the rank column still shows the all-time rank.

A member who logs in late gets the ranking from the snapshot a raid leader or admin whispers. The numbers can lag
a minute behind, and a modified addon could report more than it earned: the addon only checks that totals never
go down and do not grow faster than about 300 honourable kills an hour.

Admins find the **Kill counters** card in *Admin > Season*: they pick a member and press *Reset PvP counters* (and
*Confirm*). It acts at once, says the revision it used, and zeroes the member on every client; the member's own
counters are zeroed when their client receives it, or at their next login. Nobody else can do this.

### Recent kills

The **Recent kills** sub-tab is your own kill history, newest first, for example
`12:04  Me killed Zed (open world, killing blow)`. It shows your last 50 kills since you logged in; nothing is
saved. There are no switches: all your kills are always shared with the guild.

- Your kills are sent to the guild about 5 seconds after they happen, at most 5 per minute, and never during an
  encounter. This shares the names of the players you kill (see the privacy notes). The kills of other members are
  not shown here.
- The feed needs the name of the killed player. If this client does not give it, the tab says the feed is not
  available and nothing is shown or sent.

## PvP seasons

A PvP season is a period in which missions give points and the points make a ranking. Everything described here is
the base of the system: for now it is driven with `/nrage pvp ...` commands, and the PvP tab will get its own screens
in a later version (`docs/PVP_MISSIONS_PLAN.md`).

| Who | Can |
|---|---|
| any member | claim a mission when it is complete (`/nrage pvp claim <missionId> [note]`); see the season, its missions and the ranking (`/nrage pvp season`, `/nrage pvp mission`) |
| GM, CoGM | everything a member can, plus see the claims waiting (`/nrage pvp queue`), approve (`approve <claimId>`) or reject (`reject <claimId> [reason]`) them, mark a prize as delivered, create and close seasons (`/nrage pvp season create <days> <name>`, `close`), define missions and prizes, give points without a claim (`grant <player> <missionId> [points]`) and void a grant |

### The sub-tabs

- **Season**: the running season (name, dates, days left), your position and points, how many points you lack for
  the 3rd place, the prizes by tier, and the ranking. Your row is highlighted and a dashed line under the 10th
  position marks where the prizes end. With no season running, it says so.
- **Missions**: one card per active mission with its criteria (zones, count, distinct players, place, repetition),
  a progress bar and a button: **Claim**, or **Claim with note** (needed for manual missions), or the state of your
  claim (*Pending approval*, *Approved*, *Rejected*). A mission the client cannot detect says *Not available on
  this client* and cannot be claimed. Kills without a known class or race are listed so the approver decides. After
  the end date no claim is accepted until the admin closes the season.
- **Stats** and **Recent kills**: described above.
- **History**: *By season* shows a card per closed season (podium, delivery progress and, on request, the full final
  standing) and *Cumulative* adds all the closed seasons (seasons played, podiums, points).
- **Admin** (GM and CoGM only): *Approvals* (each claim with its evidence, **Reject** or **Approve**, and the
  rejected ones, which can still be approved) and *Deliveries* (**Mark delivered** once you handed the prize over in
  game), *Missions* (table, **New mission**, **Edit**, copy from another season; the form takes
  title, description, goal, count, points, zones as map ids or the current zone, place, distinct by, repetition,
  times per player and status), *Season* (name and dates, **Create season** or **Save**, and **Close season**,
  which asks for a second click and warns about the pending claims that will expire; the kill-counter reset is
  here too) and *Prizes* (a row per tier with its rewards, click one to remove it; add gold, or an item by
  pasting its link: only the item id and name are kept).


- Only **one season** is active at a time. A claim only counts for something done between the start and the end date
  of the season; the end date blocks new claims, and the admin **closes** the season by hand.
- Every claim needs the approval of the GM or the CoGM, also the automatic ones. Approving gives the points the
  mission is worth at that moment, and approving the same claim twice counts once.
- The ranking is the sum of the approved points. If two players have the same total, the one who got there first
  ranks higher. Points are never spent.
- On closing, the final standing is frozen and every member keeps only that; the detail of the season (each grant,
  the pending claims) is dropped. The top 10 get the prizes the admin defined, by tier (1st, 2nd, 3rd, 4th to 6th, 7th
  to 10th; each player in a tier gets the whole prize). The addon never sends gold or mail: the prize is handed over
  in game and marked as delivered.
- A member who logs in late, or while a season starts, asks the guild for it and receives the ranking from a raid
  leader, the GM or the CoGM who is online.

### How missions are counted and claimed

While a season is running, the addon keeps a private log of your own kills and counts them for the missions by
itself; nothing is shared until you claim.

- **What counts.** Only honourable kills (a grey target gives no honour and never counts), done between the start and
  the end date of the season, in the current period of the mission (*once*: the whole season; *daily*: today, server
  day, UTC; *weekly*: this ISO week, UTC). The same victim counts at most 3 times per server day, across all missions.
  A mission can ask for a number of kills, a number of different players, one kill of each enemy class and/or race, a
  number of battleground wins, or be *manual* (you describe what you did in the note).
- **Zones and place.** A mission can be limited to some zones and to the open world or battlegrounds. A kill whose
  zone the client did not give never matches a zone mission.
- **Class and race.** The client does not tell the addon the class of a victim directly: the addon remembers the
  enemy players you saw (target, mouseover, nameplates) for an hour. If it did not see the victim before the kill,
  the class or race is *unknown*: it does not fill the bar, but if the unknown kills could complete it you can still
  claim, and the approver decides from the evidence.
- **Battleground wins** are logged once per battleground when the client reports your side as the winner.
- **Claiming.** When a mission is complete (or could be, with unknown classes), claim it. The claim carries up to 60
  of the rows that back it, the counts and your note, and goes to the guild. It is repeated after you log in and
  about every 10 minutes while it waits, so an approver who comes online later receives it. A claim is *pending*
  until the GM or the CoGM approves or rejects it. A period allows as many approved claims as the mission says
  (usually one), and a rejected claim uses its place.
- **Not available on this client.** Zones, class and race, and battleground wins depend on what the game client lets
  addons read, which is still being measured. A mission that needs a source the client does not give is shown as not
  available; manual missions never depend on one.

## Professions

The **Professions** tab (Guild group) answers "who can craft this?". Type part of a recipe name in the search box,
optionally pick a profession, and the table lists the members that know it, with the ones online first. **Ask** puts
a whisper in your chat box ("Could you craft me ...?"); you send it with Enter. Tick **Connected only** to hide
members who are offline.

Recipes are shared automatically: open each of your professions once and the addon reads the list the client shows
and sends it to the guild. It sends again only when the recipes change. The **My professions** card shows when each
profession was last read and tells you to open it again after your skill changes. If the client does not allow
reading recipes, the tab says so and you can still search what others share.

## Installed check

The **Installed check** tab of the Admin group (GM and CoGM only) lists every guild member with whether they run the
addon and which version:

| Status | Meaning |
|---|---|
| Up to date | the newest version seen in the guild (or your own, if newer) |
| Outdated | an older version |
| Installed | the addon is there, but the version is not known yet |
| Incompatible | a version too old (or too new) to sync with yours |
| Not installed | online now and never heard from: a member with the addon announces itself when logging in |
| Never seen | offline and never heard from |

What is heard is saved, so an offline member keeps the last version seen and when (*Last seen*). The search box
filters by name, the chips by status (each shows how many members it holds), the dropdown by version, and *Online
only* keeps the members connected now. **Ask online members** makes everyone online with a recent version answer
with their version again, at most once a minute; the answers arrive over a few seconds. The tab only knows about members
heard from since you installed this version: *Never seen* may just mean "not logged in since".

## Blacklist

The **Blacklist** tab is a guild-wide list of players the guild wants to be warned about. It is shared with every
member running the addon (see the privacy notes: names and the reason you type go to the whole guild, unencrypted).

- **Anyone can add** a player: type the **Name** (a name with several words is fine, a realm suffix is dropped) and a
  **Reason** of up to 100 characters, then press **Add**. Adding a player who is already listed changes the reason, but only the member who added
  the entry and the GM and CoGM can do it; for anyone else it is refused.
- **Only the GM and CoGM can remove** an entry. The **Remove** button only shows for them, and every
  client checks the sender's rank again, so a removal from anyone else is ignored. Once a player has been removed,
  anyone can add them again.
- The list is sorted by name and shows the reason, who added the player and when. It holds up to 200 players, and a
  member who logs in late gets it from a raid leader or admin, like the raid data. It is not part of the export.

**The alert.** When a blacklisted player is in your party or raid, the addon warns you: a chat line
`Nrage Assistant: <name> is on the blacklist: <reason>`, a raid warning in the middle of the screen and a sound.
Each player warns **once per group**: you are warned when you join a group that has them, when they join yours,
when you log in with them in your group, and when an entry about someone already in your group reaches you from the
guild. The memory is cleared when you leave the group, so the next group warns again. You are never warned about
yourself.

The game gives the addon only the **first word** of a multi-word character name for group members (`Yonemon` for
`Yonemon Gg`). When a group member has a single-word name that equals the first word of a listed multi-word name,
the alert still fires and says so: `Yonemon may be Yonemon Gg, who is on the blacklist: <reason>`. A false alarm is
better than a warning that never comes; check who it is before acting on it.

## Layers

The **Layers** tab shows the layer you are on and the layers of your continent that guildmates have shared. The
addon reads your layer from the creatures you **target or mouse over** (it needs two different creatures to be
sure), so when it says "unknown", click any NPC. The label of a layer is `#` plus the last four digits of its
id; your own layer is marked "(you)". Layers are shown only for your continent.

- **Share my layer** (on by default) lets the guild see your layer. Turn it off and the addon tells the guild to
  forget you. You can still ask for a swap with it off.
- **Request swap** asks the guildmates on that layer to help you. It needs you to be alone (not in a group), out of
  combat and not in an instance, and no other swap running; otherwise the button is disabled and says why.
- A member on that layer who can help gets a popup with a sound: **Help** or **Ignore**. The first to answer is
  picked, and the others' popups close. The helper then clicks **Invite**; you accept the normal group invite.
- After you join, target or mouse over any NPC so the addon can confirm the move. When your layer is the one you
  asked for, the popup says "Layer changed" and offers **Leave group**. The addon never leaves a group by itself.
- If nobody answers (60 seconds), the helper does not invite you (90 seconds) or the move cannot be confirmed
  (120 seconds), the popup says so. **Cancel** works at any step.

To help: the popup appears only if you are on the requested layer, not in combat or an instance, and either alone
or leading a party that is not full.

The game moves a player to the layer of the group leader after a short delay; whether it works exactly like this
on Forever is still being checked (see `docs/API_NOTES.md`).

## Groups

The **Groups** tab, in the Guild part of the window, is a board where you post a party for a dungeon, a quest or
anything else. Others apply with a role, and you invite them with a click. A party holds five players; raids stay in
Events. Every rank can use it. The Groups item of the sidebar shows how many groups are open, your own included.

**Limits.** Read these before you rely on it:

- Only members running the addon see the board.
- A post disappears from the board up to six minutes after its leader logs out or reloads. A member who logs in sees
  the open posts within two minutes at most.
- A post closes by itself after an hour.
- Nothing is saved. A `/reload` clears your own post and your own application.

**Posting.** Click **New group**, pick the type (Dungeon, Quest or Other), write a title of up to 60 characters and
say how many Tanks, Heals and DPS you need. You can also set a minimum level and a note of up to 100 characters. The
post shows five seats. A taken seat shows the class icon of a member of your party, with a small mark of the role
(shield for Tank, cross for Heal, swords for DPS) when it is known: your own declared role, and the role each applicant
joined as. A free seat shows the role you still need, dimmed. A member who was in your party before you posted has no
role mark, and a post from an older version of the addon shows people instead of classes. You can post when you are alone or when
you lead a party that is not full. You cannot post while you are in a raid or during an encounter, or while a layer
swap runs. **Edit** changes the open post and **Close group** ends it. The post closes by itself when the party is
full, when you stop leading it, when it disbands after someone joined, or when it becomes a raid.

**Applying.** On the board, press **Apply** on a post, choose the role you go as (it must be one the post still needs)
and add a note if you like. The button says why it is off when you cannot apply: you are in a group, you already have
an application or an open post, your known level is below the minimum, or a layer swap runs. Your application waits
two minutes for the leader. If there is no answer it expires, and you can apply again. **Withdraw** takes it back.

**Inviting.** The leader sees each applicant in the tab and in a popup, with **Invite** and **Decline**. **Invite**
asks the game to send the invitation. If the game refuses, nothing changes. When the applicant accepts the game's
invitation, they join and the need goes down by one. If they do not join within a minute, the row says so and you can
invite again. **Decline** tells the applicant. Invites are never automatic. You cannot invite during combat, or while
you are in a group you do not lead.

**Joining may move you.** Joining a party may move you to the leader's layer, as a layer swap does. The addon does
nothing about it. Whether the game does this on Forever has not been checked yet (see `docs/API_NOTES.md`).

**Groups and layer swaps exclude each other.** While you have an open post or an application that has not ended, you
cannot request a layer swap or answer one, and the Layers tab says why. While a swap runs, Groups refuses to post or
to apply.

## Guild map

Guildmates who share their position appear as small pins on the minimap and on the world map, drawn as a round class
icon inside a ring in the class colour (a grey dot when the class is not known). Hover a pin to see the name, the level,
the layer (green when it is yours) and how many seconds ago the position arrived. The ring turns grey when that member
is on another layer than you. Members of your own party or raid are not drawn: the game already shows them.

- Turning on **Share my position** in the settings is your decision and is off by default. Only the map and your
  coordinates are sent, on the guild channel; nothing is saved, and the others forget you after 60 seconds without a
  message or at once when you turn it off.
- Nothing is sent from an instance or a battleground, and nothing during an encounter.
- A pin disappears 60 seconds after the last message from that member (for instance when they log out).
- The map library (HereBeDragons) is included with the addon. If the game cannot load it, no pins are drawn and
  nothing else changes.
- Whether the pins are placed correctly on the Forever client has not been checked in game yet (see
  `docs/API_NOTES.md`).
- On the world map, the **Guild** button in the top-right corner (people icon) shows or hides the guildmates. It is the
  same setting as *Show guildmates on the world map*, so the two always agree. The button is lit when the pins are shown
  and dimmed when they are hidden; its tooltip says what a click does.

## Intel

**Intel** finds the enemy players around you, keeps a record of each one you meet, and shares what you see with the
guild. It covers the detection, alerts and lists of Spy (Forever), and adds a guild Kill on Sight list, live sightings
and bounties. It is the **Intel** sub-tab of the PvP tab, a compact window, the minimap button and the chat warnings.
Intel is not yet tested in the live game: keep Spy installed until the officers confirm that Intel works (see *Limits to know*
below).

### Before you start

- **Enemy nameplates must be on.** Intel reads the enemies whose nameplate you can see. When they are off, the Intel
  tab says so and offers a button to turn them on (outside combat). The addon also reminds you once per session.
- Intel runs in battlegrounds, arenas and world PvP. It never runs in dungeons and raids. Sanctuaries are skipped
  unless you turn them on, and any zone can be skipped in the settings.

### What it can and cannot see

- It reads the enemy players whose nameplate is in range, and also your target, focus and mouseover. The list is
  refreshed every second.
- **A stealthed enemy is not detected**, and neither is one that never shows a nameplate.
- The distance is about the nameplate range, not the whole zone.
- The client can hide unit information, mostly in instanced PvP. Those units are skipped.
- A skull enemy has no readable level. It is shown as your level plus 10, marked as estimated.
- **A sighting shows your position, not the enemy's.** The client does not give the enemy's coordinates, so the map
  pin is where you were when you saw them.

### On the world map

The **Enemies** button in the top-right corner of the world map (swords icon) shows or hides the enemies Intel reports
there. It is the *Show enemies on the world map* switch in the Maps group of the Intel settings, on by default. It
changes only the world map: the enemy pins on the minimap are not affected. The button is lit when on and dimmed when
off, like the Guild button.

### The compact window

`/nrage intel show` opens it and `/nrage intel hide` closes it; **Intel** in the minimap button's right-click menu
toggles it. Drag the corner to resize it: the width is free and the height snaps to whole rows (1 to 20), outside
combat and while the window is not locked. It lists who is nearby (or the last hour, the Ignore
list, or a Kill on Sight list). An entry fades at half the *Nearby delay* and leaves after it (1 to 15 minutes, or
never; 5 minutes by default).

- **Left click** targets the player.
- **Shift-click** adds or removes your personal Kill on Sight mark.
- **Ctrl-click** adds or removes the player from your Ignore list.
- **Right-click** opens a menu with the Kill on Sight and Ignore actions, the guild list, and the announce options
  (only me, party, raid, guild or Local Defense).
- In combat the rows keep their places. A player who leaves stays greyed out, and a newcomer can be targeted only
  after combat.

Automatic announcements (the *Announce* setting) are capped at 3 per minute across all enemies, on top of the
once-per-enemy-every-5-minutes rule, so a big world PvP fight cannot flood chat and disconnect you. Skipped ones can be
announced later. The *only me* option and manual announcements are not capped.

### Kill on Sight

There are two lists:

- **Your list** is personal. It is kept on this character and is **never sent** to anyone. Up to 500 players.
- **The guild list** is shared with every member running the addon. Any member can add a player. Only the member who
  added the player, the GM or the CoGM can change the entry, and only that member, the GM or the CoGM can remove it.
  Removing an entry tells the guild.

Each entry has a category (gank, camp, corpse, objective, insult or other) and an optional reason of up to 100
characters. The reason is free text about another player, so write only what you would say in guild chat.

### Ignore

A player on your Ignore list is never alerted, never listed as nearby and never shared. The list is personal and is
never sent.

### Sightings

When Intel sees an enemy, it can tell the guild. **Sharing sightings is on by default.** The addon tells you so in
chat once, at login. To turn it off, run `/nrage intel config`, open *Sharing*, and clear
**Share sightings with the guild**.

- A sighting holds the enemy's name, class, race, level and whether they are stealthed, and **your position**. A
  guildmate who receives it sees where you were when you saw the enemy.
- In the open world the sighting goes to the guild. In a battleground it goes to your group. Nothing is sent from
  arenas, dungeons or raids, or during an encounter.
- Each enemy is sent at most once every 30 seconds, sooner when it starts stealth.
- Sightings you receive stay in memory for two minutes, and are shown in *Nearby* and on the maps. They are never
  saved, and they disappear when you log out.

### Wins and losses

- A **win** is an honourable kill credited to you on an enemy player you met.
- A **loss** is the player who killed you, read from the death recap. When the recap does not name a killer, the addon
  takes the enemy who was targeting you in the last 10 seconds.

Wins and losses are kept per player and shown in the statistics.

### Statistics

- `/nrage intel stats` shows this session: the enemies you met, your wins and losses, the most seen enemy, your
  nemesis (the player who killed you most) and the hottest zone.
- `/nrage intel stats season` shows the same for the running PvP season. It says so when no season is running.
- The **Statistics** view of the Intel sub-tab lists every enemy you met, with search, sortable columns and filters.
  Your lifetime honourable kills are shown when the client gives them.

### Bounties

A bounty is a PvP mission that rewards kills of players on the guild Kill on Sight list. Only the **GM and the CoGM**
can create one.

1. On the Intel sub-tab, open a player of the guild list and click **Create bounty** (the sword icon).
2. The Missions form of the PvP Admin tab opens with the title `Bounty: <name>` and the goal **Kill on Sight kills**.
   Set the count and the points, then save.
3. A kill counts toward the bounty when the victim was on the guild Kill on Sight list at the moment of the kill. Later
   changes to the list do not change that.
4. If the bounty names a player, only kills of that player count. Otherwise any player on the guild list counts.

Kills for a bounty go through the normal claims: the GM or the CoGM approves them, as for every mission. Players with an
open bounty are marked with `!` in the Intel window, and their tooltip says so.

### Importing lists

- `/nrage intel import spy` copies the Kill on Sight and Ignore lists of Spy into yours. Spy has to be loaded for this.
  Its data may use other names, so check the result.
- `/nrage intel import kos <names>` and `/nrage intel import ignore <names>` add names to your lists. Separate them
  with commas or put one on each line. The import skips names already on the list and names that are not valid.

### Commands

| Command | What it does |
|---|---|
| `/nrage intel show`, `hide`, `config` | the compact window, and the Intel settings |
| `/nrage intel stats [season]` | the session report, or the season report |
| `/nrage intel kos [guild] <name> [category] [reason]` | add a player to your list, or to the guild list with `guild` |
| `/nrage intel kos [guild] remove <name>`, `kos list` | remove a player, or list the entries |
| `/nrage intel ignore <name>`, `ignore remove <name>`, `ignore list` | the Ignore list |
| `/nrage intel clear` | forget who is nearby (the sightings you received too) |
| `/nrage intel reset confirm` | forget every enemy you met, with their wins and losses; your lists stay |
| `/nrage intel import spy`, `import [kos\|ignore] <names>` | bring in names |
| `/nrage intel test`, `minimap`, `debug` | an alert test (nothing is shared), the minimap button, and diagnostics |

`/nrage spy` is the same command, for players coming from Spy.

### Limits to know

- Enemy nameplates must be on, and detection stays within nameplate range.
- A stealthed enemy is not detected.
- A sighting reveals your position to the guild.
- Addon messages are not encrypted. See the privacy notes.
- Intel is not yet tested in the live game. The guild keeps Spy installed until the officers confirm that Intel works.

## Sync

The **Home** tab shows the sync state. While an encounter is in progress the game blocks addon messages, so
everything you change waits in a queue and is sent when the encounter ends: the addon says
`sync paused: encounter in progress`.

Syncing is always automatic and there is no button for it: your sheet is shared after login and whenever it
changes, raid, loot, PvP and blacklist changes are sent as they are made, and a member who logs in late asks the
guild for the latest raid data by itself (a raid leader or the guild master answers by whisper). The header pill shows
what is happening: *Sync ready*, *Sync paused* during an encounter, or how many messages are queued. For
troubleshooting, `/nrage debug sync` asks again (at most once a minute) and `/nrage debug publish` sends your sheet at
once; they are not needed in normal use.

## Troubleshooting

| Symptom | What to check |
|---|---|
| "disabled: ..." at login | the message says why: not in the guild, other guild, other faction or ruleset, or saved data from a newer version |
| "not allowed: your guild rank gives the role ..." | your rank does not allow it; ask an officer if that is wrong |
| Changes do not reach others | the Home tab shows whether messages are queued; check `/nrage debug selftest` |
| The blacklist alert does not fire for a multi-word name | the client may give only the first word for group members: the alert then says "may be ..."; if it does not fire at all, tell an officer (see the notes in `docs/API_NOTES.md`) |
| Something else | `/nrage debug selftest` and `/nrage debug info` |

## Commands

| Command | What it does |
|---|---|
| `/nrage` | opens the window, where everything else is done |
| `/nrage help` | this short list |
| `/nrage pvp ...` | commands for the PvP seasons (see *PvP seasons*); the PvP tab does the same with screens |
| `/nrage intel ...` | the Intel commands (see *Intel*); `/nrage spy` is the same command |
| `/nrage debug ...` | diagnostics for developers: `selftest`, `info`, `identity`, `roster`, `senders`, `sync`, `publish`, `lockdown`, `pvp`, `layer` |
