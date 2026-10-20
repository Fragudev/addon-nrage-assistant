# Privacy and data

What Nrage Assistant stores, what it shares and how to take it back. The guild's decisions on retention and on
which fields are shared are still open (see the issues labelled `decision`).

## The short version

- Nothing about you leaves your client until you say so, one kind of data at a time.
- **Addon messages are not encrypted or confidential.** Anything shared is readable by every guild member running
  the addon, and possibly by others. Do not share what you would not put in guild chat.
- The addon is meant for the Nrage guild only and disables itself elsewhere.

## What is stored on your machine

Everything is kept in the game's `SavedVariables` (`NrageAssistantDB`). It is a normal file on your disk, not a
secret store.

| Data | Where it comes from |
|---|---|
| Your sheet: class, level, item level, professions, guid, and the fields you declared (role, main, notes) | read from the game, or typed by you |
| Your readiness confirmations | you |
| Profiles received from other members | the guild channel |
| Your PvP counters (honourable kills, killing blows, per day for 30 days) | read from the game |
| PvP counters received from other members | the guild channel |
| Recent guild kills (killer, victim, place), in memory only | the guild channel, and your own kills |
| Your layer, and the layers other members share, in memory only | read from the creatures you target, and the guild channel |
| The guild blacklist: names of players, a short free-text reason, who added each one and when | you, or received |
| Raid events, attendance, assignments, loot sessions and awards | you, or received |
| Tombstones (records of deletions) | local deletions and received ones |
| Assignment templates (each keeps the roster of the event it was saved from) | you; never shared |
| Raid rosters and the role and roster the guild master assigned to each member | the guild master, received over the guild channel |

Every stored value keeps where it came from (`observed`, `declared` or `received`), when, and who authored it.

## Rosters are a filter, not a lock

The guild can split its raiders into rosters (teams). A player sees in the window only the events, reports and loot
of their own roster, and the loot popup and the voting window only open for the members of the roster of a session.
**This is a visibility filter in the interface, not access control.** Raid data still travels over the guild addon
channel, which is not private: every guild member with the addon receives all of it (all rosters), and anyone who
reads their saved data or the channel can see it. What the roster does enforce is who may change what (a raid
leader only acts on the events of their roster). Real confidentiality would need each roster's data to be whispered
member by member, which this addon does not do.

The addon role of a member (member, raid leader, loot council) and their roster are set by the guild master and
shared with the whole guild: everybody can see who is in which roster.

## Your sheet is shared automatically

**Your sheet is shared with the guild without a consent switch** (decision in issue #36). Every guild member
running the addon receives it after you log in and again whenever it changes, at most once every 30 seconds, and you
receive theirs. It holds:

| Shared | |
|---|---|
| class and level | always |
| item level | when known |
| professions and skill | when known |
| declared role and main | when you set them |
| recipes you have learned | after you open each profession window |

Never shared: your **declared notes** (they stay on this computer), the enchants and buffs the readiness checks read
from your character, your guid, your inventory and chat. The Profile tab lists what is shared and when it was last published. Text you declare has escape characters (`|`) and control characters stripped before it is sent. Like
every addon message the sheet is **not encrypted**, and the only way not to share it is not to run the addon.

**PvP counters are shared automatically, without a consent switch.** Every guild member running the addon
receives your honourable kills and killing blows (open world and battleground, totals and today's count), and you
receive theirs; that is what the ranking shows. Nothing else about the fights is shared: no victim names, places or
times of single kills. Like every addon message they are **not encrypted**, so anyone able to read the addon
channel can read them. An admin can reset a member's counters.

**The kill feed shares the names of the players you kill.** When you kill a player, the guild members running the
addon receive the victim's name, whether it was in the open world or a battleground, and whether you landed the
killing blow, together with your name as the sender. It is always on, in the open world and in
battlegrounds, and cannot be turned off. The *Recent kills* sub-tab of the PvP tab only lists your own kills. Kills are sent about 5 seconds after they happen, at most 5
per minute and never during an encounter. The feed is not saved: the last 50 entries are kept in memory until you
log out. Like every addon message it is **not encrypted**, and a message already sent cannot be recalled.

**The blacklist shares names and free text about other people.** When you add a player to the guild blacklist, every
guild member running the addon receives the player's name, the reason you typed (up to 100 characters) and your
name as the author, and you receive the entries of the others; a member who logs in later gets the whole list from
a leader. There is no consent switch: adding a player is the act of sharing, and anyone with a guild role can do
it. Only the guild master and officers can remove an entry. The reason is about a third party who has not agreed
to it, so write only what you would say to them in the guild channel. Like every addon message these are **not
encrypted**, a message already sent cannot be recalled, and removing an entry does not erase copies held by
clients that never received the removal (the removal itself is remembered for 30 days). The blacklist is not part
of the text export.

Other data is shared because of the role someone plays, not by your choice: a raid leader recording attendance
publishes it, and a loot session's candidates, votes and awards are published to the guild. Loot **votes are
visible to everyone** while a session is open.

## Your layer

The layer you are on is coarse location data. It is read from the creatures you target or mouse over, kept **in
memory only** (never saved), shared with the guild only, and forgotten by everyone after 15 minutes without a new
message. **Share my layer** (Layers tab, on by default) stops sharing it: the addon then tells the guild once to
forget you and sends nothing more. With sharing off you can still ask for a swap: the request carries the layer you
want, not the one you are on. A guildmate who answers a request tells the requester that they are on that layer.

## Taking data back

- A sheet that was already published **cannot be recalled** from the clients that received it.
- Deleting an event or an assignment sends a tombstone so other clients delete it too, but a client that never
  receives it keeps its copy.
- A tool to view, export and delete your own data is planned (tracked as an issue).

## Retention

Events are purged from your client 90 days after their start, and tombstones after 30 days. These periods are
placeholders until the guild decides them.

## Where data comes from when it is not yours

Everything received is validated before it is stored, and marked `received`. A received value is never shown as
verified, and a received profile older than seven days is shown as `stale` in the roster.
