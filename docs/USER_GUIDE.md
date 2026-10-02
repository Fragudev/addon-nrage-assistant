# Nrage Assistant: user guide

Guild coordination for Nrage: your character sheet, raid readiness, raid events with attendance and
assignments, and the loot council. Everything here is for **Alliance characters of the Nrage guild on the PvP
ruleset**; on any other character the addon switches itself off and says why once.

> The addon is in beta. Open questions and things still to be verified in game are tracked as issues.

## Getting started

1. Install it as described in the [README](../README.md).
2. Log in with a Nrage character. You should see `Nrage Assistant <version> loaded. Type /nrage for help.`
3. Click the minimap button, or type `/nrage`, to open the window. Everything is done from there: there are no
   other commands to learn.
4. Something looks wrong? Run `/nrage debug selftest` and `/nrage debug info`, and send the output to an officer.

Only three commands exist: `/nrage` (opens the window), `/nrage help` (this short list) and `/nrage debug ...`
(diagnostics for developers).

## Language

The addon speaks Spanish when your game client is in Spanish (Spain or Latin America) and English for every other
client language. There is no setting: it follows the client. Output meant for developers (`/nrage debug ...`) is
always in English, and so is what goes over the wire, so players on different languages see the same data.

## The minimap button

The guild logo sits in a gold ring on the edge of the minimap, like most addons' buttons.

- **Left click** opens the window; **drag** it to move it around the minimap.
- **Hover** shows the next event and its start time, your readiness score and how many messages wait in the sync
  queue. It reads only what the addon already holds, so it is safe during an encounter.
- A small **warning mark** on the button means the silent self test, run a few seconds after login, found
  something missing or broken on this client; the tooltip says what. Nothing is printed to chat.
- **Right click** opens a menu with a shortcut to each tab and a *Request a sync* entry.
- On the **Home** tab, under *Settings*, you can hide it or show it again, and put it back in its default place.
  The position and whether it is hidden are saved for your whole account.
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

### Sync

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
