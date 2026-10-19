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
with one entry per tab (grouped under *Guild* and, for the guild master, *Admin*) and your character card at the
bottom, and the page of the selected tab. Drag the header to move it and the corner to resize it; the size and
position are remembered.

The **gear** in the header opens the settings, which are the same from every tab and are saved for your whole account:

- **Language**: *Automatic (game language)*, *Español* or *English*. Automatic follows the game client: Spanish on a
  Spanish client (Spain or Latin America), English on any other. The window is drawn again at once when you change it.
- **Show the minimap button**, and **Button position** with *Reset* to put it back in its default place.
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
- **Right click** opens a menu with a shortcut to each tab and a *Request a sync* entry.
- In the **settings** (the gear of the window) you can hide it or show it again, and put it back in its default
  place. The position and whether it is hidden are saved for your whole account.
- The logo also appears as the addon's icon in the AddOns list and at the top of the window's Home tab.
- The button only shows on characters where the addon is active.

## What you can do, by role

Your role comes from your **guild rank**. The addon never trusts what a message says about its sender: every
client checks the sender's rank in its own copy of the guild roster.

| Role | Who | Can |
|---|---|---|
| member | any rank not listed below | see shared data, edit and publish your own sheet, put yourself forward for loot, add players to the blacklist |
| rl | raid leaders | everything a member can, plus create and edit events, record attendance, manage assignments |
| council | loot council | everything a member can, plus open loot sessions, vote and award |
| admin | guild master and officers | everything above, plus moderation and removing players from the blacklist |

The rank names are placeholders until the guild defines its own. Ranks that are not mapped count as member.

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

- The Profile tab lists exactly what is shared and what stays private. *Publish now* sends it at once.
- What other clients already received cannot be taken back.

**Addon messages are not private.** Anyone in the guild running the addon can read what you publish.
See [PRIVACY.md](PRIVACY.md).

## Readiness

The **Readiness** tab shows a checklist with the result of each item and a score that always shows its denominator,
for example `1/3 met, 2 unknown`. An item nobody has confirmed is `unknown`, and unknown is never counted as met.

Manual items are confirmed from a dropdown on the same tab (the score updates at once). A `waived` item leaves the
score but stays visible.

The rules are the same for the whole guild and only an admin can change them. Until the guild sets its own, the
starting list applies (level 60, item level, role, consumables and enchants). Items measured from the game
(level, item level, professions, enchants and buffs) say where their value comes from; the rest are confirmed by
hand.

Admins (guild master and officers) also see a **Rules** tab, which nobody else gets. It lists the rules in force with a
Remove button each, and a form to add one: pick the kind (minimum level, minimum item level, enchanted slots, active
buff, profession, declared field, or confirmed by hand), give it a name and type the details (the hint under Details
says what fits). Slots can be typed by name (`mainhand`, `chest`, `back`...) or number, and buffs by spell id or name.
Every change replaces the whole set for the guild; **Use the starting list** puts the starting rules back.

## Raid events

Events are created by raid leaders and admins and are shared with the guild. Names of characters can have several
words (`Yonemon Gg`); in the window you pick a member from a list, so nothing needs quoting.

The **Raid** tab has the events on the left (with a field to create one, and the *Export* and *Import* buttons) and
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

- **Export** shows a text (starting with `NRAGE1:`) with all events, attendance, assignments, loot awards and
  deletions. Select it and copy it anywhere.
- **Import** takes such a text and merges it into your data. Only raid leaders and admins see it. Pasted text is
  checked exactly like data received over the guild channel: it never overwrites newer edits, and importing the same
  text twice changes nothing. Imported data stays on your client.

## Loot council

Sessions belong to a raid event. They are opened **after the encounter**: while chat messaging is locked down
the addon refuses, because the session could not be announced.

When a session opens, everyone in the guild with the addon gets the **Nrage Loot** popup with the item and the
buttons *Main spec*, *Off spec*, *Other* and *Pass*. A click puts you forward with your declared role (or your
class) as the spec; nothing is sent before that. The popup never appears during an encounter lockdown (it waits),
it does not pop up for sessions that were already open when you logged in, and closing it counts as passing.
An item you do not answer is passed on after 60 seconds (only on your screen; nothing is sent).
The Loot tab remains for choosing a different spec or adding an upgrade.

GM, Officer and RL ranks also get the **Nrage Loot Council** voting window, which opens by itself when a session
opens. It lists the candidates (name, rank, response, upgrade and votes) with *Vote* and *Award* buttons, a
reason field for the award, *Close without awarding*, and a row of items (icon, name and the usual item tooltip
on hover) to switch between them. Click a column title to sort by it (again to reverse), and use *Show* to see
only main spec, off spec or other. *Award* asks you to click *Confirm* before it gives the item away. Votes follow
the guild's visibility setting, and the window waits during an encounter lockdown. The Loot tab has an
*Open the voting window* button to bring it back. Hovering a name lists what that person has already won. The
item's level and slot show under its name when the client knows them. It does not show equipped gear yet.
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

The **PvP** tab (*My stats*) counts your kills automatically, split into **open world** and **battleground**, with
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

### Ranking

The **Ranking** sub-tab lists the guild members whose counters you have received, plus you (your row is green and
always uses your own counters). Columns: name, PvP rank, honourable kills in the open world, in battlegrounds and
in total, killing blows (only shown when you or somebody else can count them) and when the record was last
updated. The default order is total honourable kills, highest first; click a column title to sort by it and click
it again to reverse. Members who are no longer in the guild are not listed, and at most 100 rows are drawn.

The **Show** selector switches between **Total** (all time, the default) and **Today**. Today follows the server
day in UTC: members who have not sent anything today show zero, and the rank column still shows the all-time rank.

A member who logs in late gets the ranking from the snapshot a raid leader or admin whispers. The numbers can lag
a minute behind, and a modified addon could report more than it earned: the addon only checks that totals never
go down and do not grow faster than about 300 honourable kills an hour.

Admins see an *Admin* section under the ranking, where they pick a member and press *Reset PvP counters* (and
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

## Blacklist

The **Blacklist** tab is a guild-wide list of players the guild wants to be warned about. It is shared with every
member running the addon (see the privacy notes: names and the reason you type go to the whole guild, unencrypted).

- **Anyone can add** a player: type the **Name** (a name with several words is fine, a realm suffix is dropped) and a
  **Reason** of up to 100 characters, then press **Add**. Adding a player who is already listed changes the reason, but only the member who added
  the entry and the guild master and officers can do it; for anyone else it is refused.
- **Only the guild master and officers can remove** an entry. The **Remove** button only shows for them, and every
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

## Sync

The **Home** tab shows the sync state. While an encounter is in progress the game blocks addon messages, so
everything you change waits in a queue and is sent when the encounter ends: the addon says
`sync paused: encounter in progress`.

A member who logs in late asks the guild for the latest raid data; a raid leader or admin answers by whisper.
*Request a sync* on the Home tab (or in the minimap button's menu) asks again, at most once a minute.

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
| `/nrage debug ...` | diagnostics for developers: `selftest`, `info`, `identity`, `roster`, `senders`, `lockdown`, `pvp` |
