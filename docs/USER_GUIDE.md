# Nrage Assistant: user guide

Guild coordination for Nrage: your character sheet, raid readiness, raid events with attendance and
assignments, and the loot council. Everything here is for **Alliance characters of the Nrage guild on the PvP
ruleset**; on any other character the addon switches itself off and says why once.

> The addon is in beta. Open questions and things still to be verified in game are tracked as issues.

## Getting started

1. Install it as described in the [README](../README.md).
2. Log in with a Nrage character. You should see `Nrage Assistant <version> loaded. Type /nrage for help.`
3. Type `/nrage` to open the window, or `/nrage help` for the list of commands.
4. Something looks wrong? Run `/nrage debug selftest` and `/nrage debug info`, and send the output to an officer.

## The minimap button

The guild logo sits in a gold ring on the edge of the minimap, like most addons' buttons.

- **Left click** opens the window; **drag** it to move it around the minimap.
- **Hover** shows the next event and its start time, your readiness score and how many messages wait in the sync
  queue. It reads only what the addon already holds, so it is safe during an encounter.
- A small **warning mark** on the button means the silent self test, run a few seconds after login, found
  something missing or broken on this client; the tooltip says what. Nothing is printed to chat.
- **Right click** opens a menu with a shortcut to each tab and a *Request a sync* entry.
- `/nrage minimap hide` hides it, `/nrage minimap show` brings it back, and `/nrage minimap reset` puts it back in
  its default place. The position and whether it is hidden are saved for your whole account.
- The logo also appears as the addon's icon in the AddOns list and at the top of the window's Home tab.
- The button only shows on characters where the addon is active.

## What you can do, by role

Your role comes from your **guild rank**. The addon never trusts what a message says about its sender: every
client checks the sender's rank in its own copy of the guild roster.

| Role | Who | Can |
|---|---|---|
| member | any rank not listed below | see shared data, edit and publish your own sheet, put yourself forward for loot |
| rl | raid leaders | everything a member can, plus create and edit events, record attendance, manage assignments |
| council | loot council | everything a member can, plus open loot sessions, vote and award |
| admin | guild master and officers | everything above, plus moderation |

The rank names are placeholders until the guild defines its own. Ranks that are not mapped count as member.

## Your sheet (profile)

`/nrage profile` shows what the addon knows about your character, each value with where it comes from:
`verified` (read from the game), `declared` (typed by you) or `received` (from someone else). A value the game
cannot give is shown as `unknown`; it is never guessed.

`/nrage profile set <role|main|notes> <text>` sets a declared field. An empty text clears it.

### Sharing your sheet

Nothing leaves your client until you agree to it, and you can agree to each kind of data separately:

| Consent | Shares |
|---|---|
| `profile` | class, level, and your declared role and main |
| `gear` | item level |
| `professions` | your professions and skill |
| `notes` | your declared notes |

- `/nrage consent` shows your choices; `/nrage consent <profile|gear|professions|notes> <on|off>` changes one.
- `/nrage publish` previews exactly what would be shared and what stays private. `/nrage publish confirm` sends it.
- Turning consent off stops future publications; it cannot take back what other clients already received.

**Addon messages are not private.** Anyone in the guild running the addon can read what you publish.
See [PRIVACY.md](PRIVACY.md).

## Readiness

`/nrage ready` shows a checklist with the result of each item and a score that always shows its denominator,
for example `1/3 met, 2 unknown`. An item nobody has confirmed is `unknown`, and unknown is never counted as met.

Manual items are confirmed from a dropdown on the **Readiness** tab (the score updates at once), or with
`/nrage ready set <item> <met|missing|waived|unknown>`. A `waived` item leaves the
score but stays visible. The guild has not chosen the level, item level and profession thresholds yet, so today
the list only holds the items that need no numbers.

## Character names with several words

Character names on Forever can have several words (`Yonemon Gg`). Where a command takes a name followed by more
text, put a name with spaces in double quotes:

- `/nrage assign 1 add "Yonemon Gg" Ragnaros`
- `/nrage loot 1 2 award "Yonemon Gg" highest need`

Two commands need no quotes: `attendance` (the last word is the state, the name is what is before it, as in
`/nrage attendance 1 Yonemon Gg present`) and `loot ... vote` (everything after `vote` is the name).

## Raid events

Events are created by raid leaders and admins and are shared with the guild.

### From the window

The **Raid** tab has the events on the left (with a field to create one) and the selected event on the right.
The right side has a sub-tab for each thing you can do: *Summary* (everyone: status, attendance counts and
assignments), and, depending on your rank, *Details* (rename, status, start time), *Attendance* (a state dropdown for
each member already recorded, and a search to add somebody else: type part of a name, press Enter, and click
the name), *Assignments* (add by picking a member,
remove) and *Templates* (save, apply, and the suggestions that match the event). Sub-tabs your rank does not
allow are not shown. Creating an event opens it. The commands keep working the same way.

### From the chat

Events are numbered as in the list:

| Command | What it does |
|---|---|
| `/nrage event` | list events |
| `/nrage event new <title>` | create an event |
| `/nrage event rename <n> <title>` | rename |
| `/nrage event status <n> <planned\|open\|closed\|cancelled>` | change the status |
| `/nrage event start <n> <YYYY-MM-DD HH:MM>` | set the start, in your local time |
| `/nrage event delete <n>` | delete |

### Attendance

`/nrage attendance <n>` lists the recorded attendance of event *n*, and
`/nrage attendance <n> <name> <state>` records one. States: `invited`, `confirmed`, `present`, `late`,
`leftEarly`, `absent`, `excused`, `unknown`. Only an explicit entry changes a state: a disconnect is never
turned into an absence.

### Assignments

`/nrage assign <n>` lists them, `/nrage assign <n> add <name> <encounter>` adds one and
`/nrage assign <n> remove <k>` removes the *k*-th.

### Templates

`/nrage template save <event> <name>` keeps an event's assignments under a name, and
`/nrage template apply <event> <name>` adds them to another event (skipping any it already has), so the same
boss does not have to be planned again each week. Also `template list`, `template show <name>` and
`template delete <name>`. Templates stay on your client and are not shared.

In the **Raid** tab, a newly created event is opened at once, and any template whose name matches the event's
title or instance (for example a template called *Molten Core* for an event *Molten Core night*) is offered as a
button. Nothing is applied until you click it, and a template the event already has in full is not offered.

## Loot council

Sessions belong to a raid event. They are opened **after the encounter**: while chat messaging is locked down
the addon refuses, because the session could not be announced.

When a session opens, everyone in the guild with the addon gets the **Nrage Loot** popup with the item and the
buttons *Main spec*, *Off spec*, *Other* and *Pass*. A click puts you forward with your declared role (or your
class) as the spec; nothing is sent before that. The popup never appears during an encounter lockdown (it waits),
it does not pop up for sessions that were already open when you logged in, and closing it counts as passing.
The Loot tab remains for choosing a different spec or adding an upgrade.

GM, Officer and RL ranks also get the **Nrage Loot Council** voting window, which opens by itself when a session
opens. It lists the candidates (name, rank, response, upgrade and votes) with *Vote* and *Award* buttons, a
reason field for the award, *Close without awarding*, and a row of buttons to switch between open items. Votes
follow the guild's visibility setting, and the window waits during an encounter lockdown. The Loot tab has an
*Open the voting window* button to bring it back. It does not show item level, slot or equipped gear yet.

The **Loot** tab does all of this from the window. Pick the event, and each session shows its item, candidates,
votes and decision. Anyone can apply to an open session with a spec and the *Apply: main / off / other* buttons
(the upgrade field is optional). Council and admins also get *Vote*, *Award* (with a reason) and *Close without
awarding*, and a field to paste or shift-click an item link to open a session. Controls your role does not allow
are not shown. The commands below keep working the same way.

| Command | Who | What it does |
|---|---|---|
| `/nrage loot <event>` | anyone | list the sessions of the event |
| `/nrage loot <event> open <item link>` | council, admin | open a session; shift-click the item, or give `<id> <name>` |
| `/nrage loot <event> <n>` | anyone | show a session: candidates, votes, decision |
| `/nrage loot <event> <n> apply <spec> <main\|off\|other> [upgrade]` | anyone | put yourself forward |
| `/nrage loot <event> <n> vote <name>` | raid leader, council, admin | vote for a candidate (you can change it) |
| `/nrage loot <event> <n> award <name> <reason>` | raid leader, council, admin | award the item and close the session |
| `/nrage loot <event> <n> close` | raid leader, council, admin | close without awarding |
| `/nrage loot acta <event>` | anyone | the minutes: what was decided and why |

Votes are visible to everyone while a session is open; whether they should be secret until it closes is still to
be decided by the guild. A late joiner receives the minutes (awards and open sessions), not the votes of past
sessions.

## Reports

`/nrage report attendance [event]` and `/nrage report loot [event]`, over every event held or over one.

Attendance counts `present`, `late` and `leftEarly` as attended and `absent` as missed, and prints the rate with
its denominator (`2/3 (67%)`). `invited`, `confirmed`, `unknown` and `excused` stay out of the rate but are
listed, so unknown data never improves or worsens anyone's numbers. Planned and cancelled events do not count.

## Moving data around

- `/nrage export` shows a text (starting with `NRAGE1:`) with all events, attendance, assignments, loot awards
  and deletions. Copy it anywhere.
- `/nrage import` takes such a text and merges it into your data. Only raid leaders and admins can import.
  Pasted text is checked exactly like data received over the guild channel: it never overwrites newer edits,
  and importing the same text twice changes nothing. Imported data stays on your client.

## Sync

`/nrage sync` shows the sync state. While an encounter is in progress the game blocks addon messages, so
everything you change waits in a queue and is sent when the encounter ends: the addon says
`sync paused: encounter in progress`.

A member who logs in late asks the guild for the latest raid data; a raid leader or admin answers by whisper.
`/nrage sync request` asks again (at most once a minute).

## Troubleshooting

| Symptom | What to check |
|---|---|
| "disabled: ..." at login | the message says why: not in the guild, other guild, other faction or ruleset, or saved data from a newer version |
| A command says it is "unavailable while the addon is disabled" | same as above |
| "not allowed: your guild rank gives the role ..." | your rank does not allow it; ask an officer if that is wrong |
| Changes do not reach others | `/nrage sync` shows whether messages are queued; check `/nrage debug selftest` |
| Something else | `/nrage debug selftest`, `/nrage debug info`, `/nrage role` |

## All commands

Type `/nrage help` in game for the list that matches your version.
