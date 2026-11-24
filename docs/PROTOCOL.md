# Sync protocol

How Nrage Assistant clients talk to each other. The limits quoted here are the values in
`NrageAssistant/Core/Constants.lua`, which is the source of truth.

## Principles

- **Every received byte is hostile.** Sizes are bounded before each decoding stage, only whitelisted message
  types and fields survive, unknown fields are dropped, and text containing `|` (colour codes, links) or control
  characters is rejected.
- **The sender comes from the client, never from the payload.** Authors of records (`updatedBy`, `recordedBy`,
  a loot candidate, a voter, who awarded an item) are always the message sender.
- **Authority comes from the receiver's own guild roster**, not from the message: the sender's rank is looked up
  locally and turned into a role. An unknown sender gets nothing.
- **Nothing is executed.** Deserialization uses LibSerialize; there is no `loadstring` anywhere.
- **Addon messages are not encrypted or confidential.**

## Transport

- Prefix `NRAGE`, registered only after the addon has passed its access checks (guild Nrage, Alliance, PvP ruleset).
- AceComm on `GUILD` for shared data and on `WHISPER` for snapshots and PvP ledger pages. Any other channel is
  ignored.
- Encoding: LibSerialize, then LibDeflate compression, then the addon-channel encoding. A guild message may be up to
  4096 characters encoded and 32 KB decoded; a snapshot up to 32 KB encoded and 256 KB decoded.
- Secret values (encounter restrictions) raised while handling a message make the message be dropped silently.

## Envelope

```text
{ v = major, m = minor, t = type, id = messageId, p = payload }
```

- `v` must equal the receiver's major version (currently 1); a different major is reported as an incompatible
  peer and the local data is left alone. `m` only adds optional fields and new message types (currently 13 in the PvP tracking branch; see the list below): a client
  that does not know a field drops it while validating, and a client that does not know a message type drops the
  message as `unknown_type`, so older and newer clients keep talking. Minor 5 added the roster and recipe messages and fields
  below; minor 6 added the layer messages (`LAYER_STATE` and the since removed `LAYER_SWAP`); minor 7 added the PvP season messages
  (`PVP_SEASON` and the others of the "PvP seasons" section); minor 8 added event sign-up (`SIGNUP_UPSERT`); minor 9
  replaced `READINESS_RULES` with the per-roster `ROSTER_RULES`; minor 10 added the guild Kill on Sight messages
  (`KOS_UPSERT`, `KOS_DELETE`); minor 11 added the Groups messages (`LFG_POST`, `LFG_APPLY`, see *Groups*); minor 12 added the optional
  `party` of an open `LFG_POST`; minor 13 added the rank map (`RANK_MAP`, see *Rank mapping*); minor 14 added the announcement messages (`ANN`, `ANN_DEL`, see *Announcements*); minor 15 added `PVP_PROGRESS`, the optional `queue` of `PVP_LEDGER_REQ`, claims in the
  ledger catch-up between approvers, the `bg_played` goal kind and the optional goal fields below; minor 16 added the
  optional `zone` of `LAYER_STATE` (layers are per zone, see *Layers*); minor 17 added the `duel_wins` mission kind and the duel evidence row (see *PvP seasons*); minor 18 added raid posts to
  `LFG_POST` (the `raid` kind and its `size`, see *Groups*).
- `id` is 1 to 40 characters from `[A-Za-z0-9_-]`; a `(sender, id)` pair is processed once (a bounded cache of the
  last 200).

## Message types

`rev` is an integer from 1, `updatedAt` a server-time timestamp up to the year 2100. Text fields are plain text of
the length given by the model (title 60, encounter 60, item name 60, reason 100, note 100, ...).

| Type | Channel | Payload (validated fields) | Who may send it |
|---|---|---|---|
| `HELLO` | guild | `version`, optional `ask` = true (every member online answers with its own `HELLO`, even one that knew the sender already; older clients ignore it) | anyone |
| `PROFILE` | guild | `rev`, `class`, `level`, optional `ilvl`, `professions[]` (`name`, `skill`, optional `max`, optional `secondary` = true for cooking, fishing and archaeology), `fields{role, main, notes}` | anyone, for themselves |
| `EVENT_UPSERT` | guild | `eventId`, `rev`, `updatedAt`, `title`, optional `instance`, `startAt`, `status`, `rosterId` | rl of the roster of the event, admin |
| `ATTENDANCE_UPSERT` | guild | `eventId`, `characterKey`, `state`, `rev`, `updatedAt` | rl, admin |
| `SIGNUP_UPSERT` | guild | `eventId`, `characterKey`, `status` (`yes` or `no`), `rev`, `updatedAt` | officer, rl and roster ranks and above, for themselves; the character is the sender |
| `ASSIGN_UPSERT` | guild | `eventId`, `assignmentId`, `rev`, `updatedAt`, `encounter`, `characterKey`, optional `group`, `task`, `note` | rl, admin |
| `DELETE` | guild | `kind` (`event` or `assignment`), `eventId`, optional `assignmentId`, `rev` | rl, admin |
| `LOOT_SESSION` | guild | `eventId`, `sessionId`, `rev`, `updatedAt`, `itemId`, `itemName`, `status` | council, admin |
| `LOOT_CANDIDATE` | guild | `eventId`, `sessionId`, `rev`, `updatedAt`, `spec`, `need`, optional `upgrade` | anyone; the candidate is the sender |
| `LOOT_VOTE` | guild | `eventId`, `sessionId`, `rev`, `updatedAt`, `target` | council, admin; the voter is the sender |
| `PVP_STATS` | guild | `rev`, `updatedAt`, `honor{world, bg}`, optional `blows{world, bg}`, `today{day, honor{world, bg}, optional blows{world, bg}}` | anyone, for themselves; the record belongs to the sender |
| `PVP_RESET` | guild | `target`, `rev` | admin |
| `PVP_KILL` | guild | `victim` (text, 1 to 40 bytes), `where` (`world` or `bg`), `blow` (boolean) | anyone; the killer is the sender |
| `BLACKLIST_UPSERT` | guild | `key`, `name` (1 to 40 bytes), `reason` (1 to 100 bytes), `rev`, `updatedAt` | anyone; the author is the sender |
| `BLACKLIST_DELETE` | guild | `key`, `rev` | admin |
| `KOS_UPSERT` | guild | `key` (the name key, no `:`), `name` (1 to 40 bytes), `category` (`gank`, `camp`, `corpse`, `objective`, `insult` or `other`), optional `reason` (up to 100 bytes), `rev`, `updatedAt` | anyone adds; for an entry that exists, its author, gm or cogm; the author is the sender |
| `KOS_DELETE` | guild | `key`, `rev` | the author of the entry, gm or cogm; gm or cogm for an entry this client does not hold |
| `LFG_POST` | guild | `pid`, `rev`, `s` (`open` or `closed`); open: `kind`, `title`, `needs{tank, heal, dps}`, `members`, `size` (raid only), optional `minLevel`, `note` and `party[]` (`c`, optional `r`); closed: `o` (`full`, `cancelled` or `expired`) | anyone; the owner is the sender |
| `LFG_APPLY` | guild | `pid`, `s` (`apply`, `withdraw`, `accept` or `decline`); `apply`: `role`, optional `note`; `accept` and `decline`: `to` | anyone; the actor is the sender |
| `I1` sighting (prefix `NRAGEINT`, plain text, not an envelope type) | guild in the open world; the group in a battleground | `map`, `x`, `y`, `class`, `race`, `level`, `flags`, `name` (see *Enemy sightings*) | anyone in the guild roster; the sender is the client that sent it |
| `RECIPES` | guild | `prof` (profession id), optional `name`, `rev`, `updatedAt`, `part`, `parts` (up to 20), optional `total`, `ids[]` (up to 150 recipe ids per message) | anyone, for themselves; the record belongs to the sender |
| `ROSTER_UPSERT` | guild | `rosterId`, `name` (1 to 30 bytes, plain text), `rev`, `updatedAt` | admin |
| `ROSTER_DELETE` | guild | `rosterId`, `rev` | admin |
| `MEMBER_UPSERT` | guild | `key` (the character name as the guild roster writes it, no `:`), optional `rosterId`, `rev`, `updatedAt` (older clients also sent a `role`: it is tolerated and ignored) | gm, cogm; rl, only into or out of its own roster, for a member in no roster or in its own |
| `MEMBER_DELETE` | guild | `key`, `rev` | gm, cogm; rl, only for a member of its own roster |
| `LAYER_STATE` | guild | `map` (0 to 9999), `layer` (0 to 2147483647; `0` means "forget me"), optional `zone` (1 to 99999) | anyone, for themselves; the layer belongs to the sender |
| `ROSTER_RULES` | guild | `rosterId`, `rev`, `updatedAt`, `rules[]` (up to 30 rules, each validated: see Readiness rules per roster) | gm, cogm; rl for its own roster |
| `LOOT_AWARD` | guild | `eventId`, `sessionId`, `rev`, `updatedAt`, `itemId`, `itemName`, `characterKey`, `reason` | council, admin |
| `PVP_SEASON` | guild | `id`, `name` (1 to 40 bytes), `startsAt`, `endsAt`, `state` (`active` or `closed`), `rev`, `updatedAt` | admin |
| `PVP_MISSION` | guild | `id`, `seasonId`, `title` (1 to 40), `desc` (0 to 100), `points` (1 to 1000), `goal{kind, count, zones[], place, distinct, target?, bgs[]?, victimClasses[]?, victimRaces[]?, victimCapPerDay?, minGuildInGroup?, window{startsAt, endsAt}?, maxCompletions?, autoClaim?}` (kinds `kills`, `kos`, `bg_wins`, `bg_played`, `duel_wins`, `manual`), `repeatKind`, `perPlayer`, `active`, `rev`, `updatedAt` | admin |
| `PVP_PRIZES` | guild | `seasonId`, `tiers{["1"], ["2"], ["3"], ["4-6"], ["7-10"]}` (up to 5 gold or item rewards each), `rev`, `updatedAt` | admin |
| `PVP_OFFICER` | guild | `player`, `intervals[]` (`from`, optional `to`; up to 10), `rev`, `updatedAt` | admin |
| `PVP_CLAIM` | guild | `id`, `missionId`, `seasonId`, `periodKey`, `player`, `at`, `summary{}`, `evidence[]` (up to 60 rows), optional `note` | anyone; `player` must be the sender |
| `PVP_REJECT` | guild | `claimId`, `seasonId`, optional `reason`, `at` | admin, PvP officer |
| `PVP_GRANT` | guild | `id`, `seasonId`, `player`, `missionId`, `points`, `at` | admin, PvP officer (a direct grant: admin only) |
| `PVP_VOID` | guild | `grantId`, `seasonId`, optional `reason`, `at` | admin |
| `PVP_DELIVERY` | guild | `seasonId`, `player`, `tier`, `delivered`, `rev`, `updatedAt` | admin, PvP officer |
| `PVP_FINAL` | guild | `seasonId`, `name`, `startsAt`, `endsAt`, `closedAt`, `standings[]` (up to 100), `prizes` | admin |
| `PVP_PROGRESS` | guild | `seasonId`, `rows[]` (`missionId`, `count`, `goal`; up to 50), numbers only | anyone, for themselves; only an approver keeps it |
| `PVP_LEDGER_REQ` | guild | optional `seasonId`, `count`, `digest`, optional `queue` (the requester approves claims) | anyone |
| `PVP_LEDGER_DATA` | whisper | optional `seasonId`, `page`, `pages`, `items[]` (`{ t, p, by }`) | gm, cogm (checked before decoding) |
| `RANK_MAP` | guild | `rev`, `updatedAt`, `ranks[]` (up to 9 rows `{ i, r, n }`: rank index 1 to 9, role, rank name 1 to 32 bytes; see *Rank mapping*) | the guild master (rank index 0) or a cogm by the map the receiver holds |
| `SYNC_REQ` | guild | none | anyone |
| `SYNC_DATA` | whisper | `items[]`, a list of `{ t, p }` raid, loot, PvP, blacklist, readiness rules, roster or rank map messages (a `PVP_STATS` item also carries `owner`, a `BLACKLIST_UPSERT` item `addedBy` and `addedAt`) | rl, admin (checked before decoding) |

`guid` is deliberately never sent. Intel sightings are not in this table: they use their own prefix, see *Enemy sightings* below.

## Conflict resolution

For the same record the incoming message wins if, in this order:

1. its `rev` is higher; else
2. its `updatedAt` is later (clamped to the receiver's clock plus five minutes, so nobody can date an edit in the
   future to always win); else
3. its sender name is lexicographically larger.

An identical record does not win, so a replay changes nothing, and two clients receiving the same edits in any
order end up identical.

- An event upsert carries the whole event: fields it omits are cleared, while the receiver's attendance,
  assignments and loot are kept.
- A `LOOT_SESSION` that wins replaces the session state, an award included. `LOOT_AWARD` carries the item, so a
  client that never saw the session can still record the decision.
- A candidate or vote is accepted only for an open session; a vote only for a known candidate.

## PvP counters

`PVP_STATS` follows the `PROFILE` model: the record belongs to the **sender**, there is no name in the payload and
a name sent anyway is dropped. Counters are whole numbers from 0 to 1,000,000, `day` is a `YYYY-MM-DD` server date
in UTC, and `blows` (killing blows) is left out by a client that cannot read the combat log; the receiver then
keeps the killing blows it already knew. The rank is never sent: every client works it out from the honourable
kills. The records are stored in `db.global.pvpStats[owner]`, at most 1000 (when full, the record updated longest
ago makes room).

Sending is automatic: a change of the counters is sent after a couple of seconds, but at most once per minute
(a burst of kills is one message), and once about 8 to 20 seconds after login. The queue key `pvp` makes a newer
message replace a queued one, and nothing is sent during an encounter lockdown.

A record is dropped when:

- its `rev` does not exceed the minimum left by an admin reset (`reset`), or it does not win the conflict rules
  above (`stale`; an identical record is a no-op);
- it is **implausible** next to the record held for the same sender: a total (open world or battleground,
  honourable kills or killing blows) went down, the honourable kills grew by more than 300 per hour since the
  previous record's `updatedAt` (never less than one hour's worth, so there is no zero window), a day holds more
  than the total, or the totals of a first record exceed 1,000,000.

These checks only limit what a **modified client** can claim: someone who stays within them can still inflate
their numbers by about 300 kills an hour, and the first record of a sender is only bounded by the maximum. They
cannot make the counters true.

`PVP_RESET` (admin only, `moderate`) zeroes the record held for `target` and stores `rev` as the **minimum
accepted revision** (`db.global.pvpResets[target]`, the highest one is kept), so the old totals cannot come back
with an older `rev`. The admin's client picks a `rev` above everything it has seen of that member. The target's own
client resets its counters when it receives the message and continues with revisions above it. A member who was
offline during the reset learns it from the snapshot on the next login, when the snapshot comes from an admin.

## PvP kill feed

`PVP_KILL` tells the guild that the sender killed `victim`. The killer is the **sender**, never a payload field (a
name sent anyway is dropped). `victim` is plain text of at most 40 bytes without escapes or control characters,
`where` is `world` or `bg`, and `blow` must be a real boolean (the killing blow, as opposed to honour credit);
anything else drops the message. It is **not** part of a snapshot: the feed is live only, the own kills are kept in memory (the
last 50 entries) and never saved. The protocol minor version was raised for it; older clients ignore the unknown type.

Sending: an own kill waits 5 seconds before it is sent, so the honour message and the killing blow (two events for
one kill, in either order) become one message. A killing blow without honour (a grey target) is sent alone with
`blow = true`. The message always goes out (no setting), except during an encounter lockdown (it is dropped, never
queued) and beyond 5 per rolling minute (the rest are dropped).

Receiving: the sender must be a known guild member (`pvp_publish`) and passes the per-sender rate limit of the
inbox. The kill is validated and then ignored: the Recent kills list only holds the own kills.

## Layers

Protocol minor version 6. Older clients drop it with `unknown_type`. It is **guild channel only** (never a whisper,
never part of a snapshot) and live only: nothing is saved. A sender must be a known guild member (`layer_share`,
every role).

`LAYER_STATE` is the sender's own layer, a pair `(map, layer)` read from creature GUIDs (see `docs/API_NOTES.md`).
It is sent when the layer changes and again every 300 seconds, at most once per 30 seconds (queue key `LY`), and
refused during an encounter lockdown instead of waiting. `layer = 0` means "forget me" and is sent once when the
player turns "Share my layer" off. The receiver keeps it in memory for 15 minutes.

Since minor 16 it carries the optional `zone`: the uiMapId, at zone level, of the zone the layer was read in. On
Forever each zone has its own layers. A state without `zone` (an older client) is not listed in the zone view.

`LAYER_SWAP` (a swap request between guildmates) was sent by earlier versions and has been removed. A current client
no longer knows it: it drops the message as `unknown_type`, without an error and without a reply.

## Groups

Protocol minor version 11. Older clients drop both types with `unknown_type`, so a member without this version does not
see the board. Both are **guild channel only**, live only: nothing is saved, and during an encounter lockdown the send
is refused with `locked` instead of queued. A sender must be a known guild member (`lfg_use`, every role). The sender is
always the owner or the actor; a name in a payload is only data.

`LFG_POST` is the post of its sender. The receiver keeps one post per sender on a board of at most 50: a higher `rev`
replaces it, the same `rev` only refreshes it, a lower one is dropped, and a new `pid` replaces the old one. A closed
post stays as a tombstone until it is stale, so a late open message cannot bring it back. The leader repeats an open
post every 120 seconds with the same `rev`, and a post nobody repeats for 360 seconds is dropped.

Rules for an open post: `kind` is `dungeon`, `quest`, `other` or `raid`; `title` is 1 to 60 bytes. The size of the
post is five for a party, and for `raid` (minor 18) the `size` it carries, one of 10, 20, 25 or 40; only a raid carries
a `size`. `needs` holds `tank`, `heal` and `dps`, each 0 to size minus one, and their sum is at least 1; `members` is 1
to size minus one; the needs and the members together never exceed the size. A client older than minor 18 drops raid
posts and keeps parties. `minLevel` (1 to 100) and `note` (up to 100 bytes) are optional. Text fields refuse `|` and control
characters. Unknown fields are dropped.

`party` (minor 12, optional) lists the seats already taken, the leader first, so the board can show who is in the
group: each seat is `{ c, r }` where `c` is a class file token (`WARRIOR`, upper-case letters, up to 20) and `r` is an
optional role (`tank`, `heal` or `dps`) when the leader knows it (the leader's own declared role, or the role an
applicant joined as). It must hold exactly `members` seats; a `party` that does not fit is dropped and the post is
kept. Older clients drop it as an unknown field.

`LFG_APPLY` is one step of an application.

| Step | Sent by | Fields | Meaning |
|---|---|---|---|
| `apply` | applicant | `pid`, `role` (`tank`, `heal` or `dps`), optional `note` | wants to go as `role` on post `pid`; only the owner of `pid` acts on it, and a role the post does not need is dropped |
| `withdraw` | applicant | `pid` | takes the application back |
| `accept` | leader | `pid`, `to` (a character) | invites `to`; counts only from the owner of `pid` on the receiver's board, and only when `to` is the receiver |
| `decline` | leader | `pid`, `to` | turns `to` down; the same check as `accept` |

A leader keeps at most 10 pending applicants per post. A repeated `apply` refreshes its row. The applicant's level is
never sent: a minimum level is checked by the applicant's own client.

## Announcements

Protocol minor version 13. Older clients drop both types with `unknown_type`, so a member without this version sees
no announcements. Both are **guild channel** messages and go through the normal outbound queue (held back during an
encounter lockdown). The sender must be a known guild member whose role has `announce_manage`, which is only `gm` and
`cogm` (rank Emperador and Comandante): an `ANN` or `ANN_DEL` from any other role, or from a sender the receiver's guild
roster does not know, is dropped as `forbidden` or `unknown_sender`. The role is read from the receiver's own roster,
never from the message, and the author is always the sender: the payload has no field for it.

`ANN` is a whole announcement (an upsert, like `EVENT_UPSERT`): `id` (a message id, 1 to 40 characters from
`[A-Za-z0-9_-]`), `title` (1 to 60 characters), `body` (0 to 600 characters, may be left out; newlines are allowed, `|`
and the other control characters are not), `createdAt`, `updatedAt`, `rev` (from 1), `popup` (boolean), `popupRev` (from
1), `pinned` (boolean) and `expiresAt` (optional, a server-time timestamp: left out means it never expires). Characters
are counted, not bytes, so accented text keeps its full length. Unknown fields are dropped.

`ANN_DEL` removes one: `id`, `rev` (above the last one the sender saw) and `updatedAt`.

Rules on the receiver:

- The higher `rev` wins, then the later `updatedAt` (clamped to five minutes ahead of the local clock), then the larger
  sender. An identical message is a no-op. `createdAt` is kept from the first copy.
- A removal leaves a tombstone (`{ at, rev }`, kept 30 days, at most 200 of them), and an `ANN` whose `rev` does not
  exceed it is dropped as `tombstoned`, so an old copy cannot bring a deleted announcement back.
- A new announcement that already expired is dropped (`expired`).
- At most 30 live announcements are kept. When it is full, the oldest unpinned one is dropped (and remembered as a
  tombstone) to take a newer one, or a pinned one; an older announcement never pushes out newer ones, and a pinned one is
  never pushed out (`limit`).
- A member shows the popup once per `popupRev`: `popupRev` starts at 1 and "Send popup again" raises it. The popup is
  only shown for an announcement touched in the last 7 days; older ones only count as unread on the board. What was
  seen is kept per account (`announcementsSeen[id] = popupRev`), so alts do not get the same popup twice.

**Catch-up.** A snapshot (`SYNC_DATA`, see below) carries the newest live announcements and the removals when its
sender is a `gm` or a `cogm`; an item is applied under the role of the sender. Each `ANN` item may name its original
`author` (the one documented exception to "the author is the sender", only inside a snapshot), and it is believed only
when the receiver's own guild roster says that member has `announce_manage` too; otherwise the sender stays the author.
The text export never includes announcements. As the snapshot only comes from a leader who happens to be online, a
`gm` or `cogm` also repeats their own live announcements once after login, each at a random moment of 5 to 40 seconds.

## Guild map positions

A second addon prefix, `NRAGEPOS`, carries the position of members who chose to share it. It does **not** use the
`NRAGE` envelope, AceComm, LibSerialize or LibDeflate, so `PROTOCOL_MINOR` does not change and older clients simply
never register the prefix. The reasons: with 40 members sending every few seconds, the `(sender, id)` seen cache of
the main inbox (one ring for all senders, 200 entries) would be evicted within seconds, weakening duplicate
protection for real data; and four numbers need no serialization, while a strict text pattern is a small attack
surface.

- Sent on `GUILD` only, through `ChatThrottleLib:SendAddonMessage("BULK", ...)`, so it never delays real traffic. A
  message that arrives on any other channel is ignored. Live only: nothing is saved, queued during an encounter
  lockdown or part of a snapshot.
- A message is at most 32 bytes and one of:

```text
P1:<mapId>:<x>:<y>     a position; mapId 1 to 9999, x and y integers 0 to 10000 (zone coordinates times 10000)
P1:0                   "forget me"
```

- It must match `^P1:(%d+):(%d+):(%d+)$` or `^P1:0$` exactly. Anything else is dropped, and a different leading version
  (`P2`, ...) is dropped silently: a future format adds a new tag.
- Name, class and level are not sent: the receiver has them from the guild roster and received profiles. The layer is
  not sent either: it comes from the layer directory.
- Sending: every 5 seconds the client checks its position and sends when it moved more than 20 units (0.2 % of the
  zone), when the map changed or after 20 seconds without a message, and never more than one per 5 seconds. When the
  position disappears (an instance, a loading screen) after one was sent, it sends one `P1:0`; so does switching
  "Share my position" off, at once. Nothing is sent from an instance or while the lockdown is on.
- Receiving, cheapest check first: the channel is `GUILD`; the sender is a non-empty string, normalized (realm
  stripped), and not the own key; a dedicated inbox allows at most 30 messages per sender per 60 seconds (rate only,
  never a seen cache); the sender is in the local guild roster (`position_share`, every role); then the strict parse. The
  whole handler runs in `pcall`, because arguments can be secret values during an encounter.
- The receiver keeps `{ map, x, y, at }` per sender, in memory, for 60 seconds, at most 200 senders (new ones are
  refused when full).

## Enemy sightings (NRAGEINT)

Intel tells the guild about the enemy players its owner sees. A sighting does not use the `NRAGE` envelope, LibSerialize
or LibDeflate: it is a short text that is read as it is, so there is no decoder to attack. It has its own prefix,
`NRAGEINT`, registered by the client like `NRAGE`.

- **Text:** `I1:<map>:<x>:<y>:<class>:<race>:<level>:<flags>:<name>`, at most 96 bytes.
  - `map` 1 to 9999; `x` and `y` 0 to 10000. They are the **reporter's** position (the client gives no coordinates for
    an enemy), in zone coordinates times 10000.
  - `class` and `race` are positions in the fixed lists of the constants, and `0` is unknown.
  - `level` 0 to 100, `0` is unknown. `flags` 0 to 3: bit 1 is stealth, bit 2 an estimated level (a skull enemy).
  - `name` is last, so it is the only field that can hold spaces. It is a clean name (1 to 40 bytes, no `|`, `:` or
    control character).
  - Any other text, extra field, or value out of range is dropped (`bad_format` or `out_of_range`).
- **Channels.** `GUILD` (open world), and `RAID`, `PARTY` or `INSTANCE_CHAT` (battlegrounds). Any other channel is
  dropped (`wrong_channel`).
- **Sender.** It is the sender the client reports, never anything from the text. Your own messages are dropped. A
  sender who is not in your guild roster has no role and is dropped (`unknown_sender`), which covers a battleground
  group mate outside the guild.
- **Rate.** At most 30 messages per sender in a 60 second window, a rate limit only and never a seen cache.
- **Sending.** One message per 2 seconds at most, sent with `ChatThrottleLib` at `BULK` priority so it never delays
  real traffic. An enemy is sent at most once per 30 seconds, sooner when it starts stealth. The queue holds 5 sightings.
  Nothing is sent in arenas, dungeons and raids, or during an encounter lockdown.
- **Receiving.** A sighting is kept in memory for 120 seconds, for at most 200 enemies, and is never saved.

## Guild blacklist

A list of players the guild wants to be warned about, each with a short reason. Two messages, both on the guild
channel; the protocol minor version was raised to 3 for them, and older clients drop the unknown types with
`unknown_type`.

| Action | Roles | Message |
|---|---|---|
| `blacklist_add` | member, rl, council, admin (everyone with a role) | `BLACKLIST_UPSERT` |
| `blacklist_remove` | admin (guild master, officers and the beta admins) | `BLACKLIST_DELETE` |

The receiver reads the role of the **sender** from its own guild roster, so hiding the Remove button is only
convenience: a delete from anyone but an admin is dropped with `forbidden`, and one from a sender the roster does
not know with `unknown_sender`.

- **The author is the sender.** `addedBy` (set once, when the entry is created) and `updatedBy` (every write) are
  never payload fields; fields sent anyway are dropped.
- `name` is the name as it is shown: no realm suffix, no leading, trailing or doubled spaces, no `|`, `:` or
  control characters. `key` is the name in lowercase without any whitespace (`Yonemon Gg` is `yonemongg`). The
  receiver works the key out again from the name and drops the message (`bad_key`) when they differ.
- Entries are stored in `db.global.blacklist[key]`, at most 200. A message that would add a 201st player is
  rejected with `limit`; one that updates a listed player is still accepted.
- Conflicts follow the rules above (`rev`, then `updatedAt`, then the larger sender). Adding a player who is
  already listed changes only the reason, locally and on the wire, and only for the member who added the entry and
  for admins (`blacklist_edit_any`); anyone else gets `forbidden` (`not_author` in the interface). A message with a
  higher `rev` from one of them replaces its name and reason, and keeps who added it. Inside a snapshot the sender
  is the relaying leader, so a relay changes a listed player only when that leader is an admin.
  Known limit: if two members add the same player at nearly the same moment, each client keeps whichever entry it
  received first and refuses the other as `forbidden`, so clients can briefly hold a different reason and author for
  that player. Both list the player; an admin edit (a higher `rev`) makes them agree again.
- **Removal.** `BLACKLIST_DELETE` removes the entry and leaves a tombstone `B:<key>` in the shared, bounded
  tombstone list (500 entries, 30 days) with the revision of the removal (the entry's `rev` plus one). An upsert
  whose `rev` does not exceed the tombstone's is dropped (`tombstoned`), so an old copy cannot bring a removed
  player back. Adding the player again needs `rev = tombstone.rev + 1`; that is a legitimate new entry, and an admin
  can remove it again. A delete for a player this client never saw is remembered too.
- Sending goes through the outbound queue with the key `BL:<key>`, so a newer edit replaces a queued older one, and
  nothing is sent during an encounter lockdown.

**Snapshot.** Blacklist entries and `B:` tombstones are part of `SYNC_DATA`. Here is a second documented exception
to "the author is the sender": a `BLACKLIST_UPSERT` item of a snapshot may carry `addedBy` (validated like a
character name) and `addedAt` (a timestamp), so the original author and date are kept when a leader relays an
entry. Both are only read from the items of a snapshot, which only a raid leader or admin can send (checked before
decoding); a guild message has nowhere to carry them, and an item with an unusable `addedBy` or `addedAt` is skipped
(`bad_origin`). The item is otherwise applied as if the relaying leader had sent it, with `updatedBy` set to the
leader and the usual validation, authority and conflict rules. A `BLACKLIST_DELETE` item only counts when the
sender of the snapshot is an admin, like a PvP reset. The blacklist part is capped separately, at the 200 most
recently updated entries and the 200 newest removals, and shrinks together with the events and the PvP records
(halved until the snapshot fits in 32 KB). The blacklist is not part of the text export, and an imported blacklist
item is skipped.

## Guild Kill On Sight list

A list of enemy players the guild wants to watch for, each with a category and an optional reason. It works like the
blacklist: two messages on the guild channel, with the protocol minor version raised to 10 for them. Older clients
drop the unknown types with `unknown_type`.

| Action | Roles | Message |
|---|---|---|
| add a player, or change an entry | every member to add; for an entry that already exists, its author, gm or cogm | `KOS_UPSERT` |
| remove | its author, gm or cogm; gm or cogm for an entry the receiver does not hold | `KOS_DELETE` |

- **The author is the sender.** `addedBy` (set once, when the entry is created) and `updatedBy` (every write) are never
  payload fields. The receiver reads the role of the sender from its own guild roster, and an unknown sender gets
  nothing (`unknown_sender`).
- `key` is the name key (`IntelModel.Key`: the name in lowercase without any whitespace or realm suffix). The receiver
  works it out again from `name` and drops the message (`bad_key`) when they differ. `name`, `category` and `reason`
  must pass the same check as a personal entry; a text with `|`, `:` or a control character is refused.
- Entries are stored in `db.global.guildKos`, at most 500. A message that would add a 501st player is refused with
  `limit`; one that changes a listed player is still accepted.
- Conflicts follow the other shared data: the higher `rev` wins, then the later `updatedAt`, then the larger sender. An
  identical message does nothing.
- **Removal.** `KOS_DELETE` removes the entry and leaves the tombstone `K:<key>` in the shared tombstones with the
  revision of the removal. An upsert whose `rev` does not exceed the tombstone's is dropped (`tombstoned`). Adding the
  player again needs a revision above the tombstone's.
- **Snapshot.** A late joiner gets up to 200 entries and as many removals inside `SYNC_DATA`, the newest first. A
  `KOS_UPSERT` item of a snapshot may carry `addedBy` and `addedAt`, so the original author and date are kept when a
  leader relays the entry. Only a snapshot from a raid leader or admin is read this way, the same exception as the
  blacklist (see *Guild blacklist*).
- Sending goes through the outbound queue under the key `KOS:<key>`, so a newer change to the same player replaces a
  queued older one. During an encounter lockdown the message waits in the queue.

## Readiness rules per roster

Each roster has its own set of readiness rules (issue #32, `docs/NAV_PERMISSIONS_PLAN.md` 5.1), a record
`{ rev, updatedAt, updatedBy, rules }` per roster that is replaced as a whole with `ROSTER_RULES`. The protocol minor
version was raised to 9 for it: the guild-wide `READINESS_RULES` (minor 4) is gone, so a new client drops it as
`unknown_type`, and an old client drops `ROSTER_RULES` the same way.

- **Authority:** `rules_edit`, read from the receiver's own guild roster. gm and cogm may set the rules of any
  roster; an rl only those of the roster it belongs to, read from the receiver's own assignments. Officer, roster,
  member and alter are refused. A newer `rev` wins per roster, then `updatedAt` (clamped), then the sender; a replay is
  a no-op. A roster without a record uses the starting checklist; a deleted roster (tombstone `R:<id>`) takes no rules
  and its record is dropped.
- **Rule validation:** every rule is checked field by field, and unknown fields are dropped. `check` is one of
  `field`, `confirm`, `level`, `ilvl`, `profession`, `enchants` or `buff`, with the numbers or lists that check
  needs (levels and item levels 1 to 999, enchant slots 1 to 18, up to 20 spell ids or names). `evidenceMode`
  is worked out from the check and never taken from the message. Ids are unique, up to 32 characters of `[%w_]`.
- **Late joiners:** a gm or cogm snapshot carries the set of every roster (after the rosters themselves), and the
  receiver applies each under the role of the sender. After login, gm and cogm send every stored set and an rl the
  one of its own roster, for the members who were not online. Existing rosters start with a copy of the former
  guild-wide set (schema 13); a new roster starts with none.

## Rank mapping

`RANK_MAP { rev, updatedAt, ranks = { { i = 3, r = "officer", n = "Oficial" }, ... } }` replaces the whole rank map of
the guild of the receiver: which addon role each guild rank index has, so renaming a rank in the game keeps the role of
its members. Rank index 0 is the guild master and is never in the map; the role is one of `cogm`, `officer`, `rl`,
`roster`, `member`, `alter` (`gm` is never assignable). `n` is the rank name when the map was saved, used for display
and to detect a rename; it decides nothing. The validator refuses a duplicate index, an index outside 1 to 9, a role
outside that set and a name with escape sequences.

Authority is worked out by the receiver, never read from the message, against the map it holds **before** applying the
incoming one:

- the sender is the guild master: their guild roster entry has rank index 0 (a rank that is merely called like the guild
  master's does not count); or
- the sender's role is `cogm` according to the map the receiver holds. The incoming map never authorizes itself.
- A `cogm` sender is also held to one guard: the row of their own rank must keep resolving to `cogm` (no
  self-promotion or demotion). The receiver drops the whole message on a violation. A cogm can still change the other
  rows, even make another rank `cogm`; the guild master's role never depends on the map and can undo it.

A newer map wins by `rev`, then `updatedAt`, then the sender (see *Conflict resolution*), per guild; maps are stored under
`<guild name>-<realm>`, so a character in another guild never shares one. Until a map is saved, every role comes from
the rank name as before. A sender whose rank is not in the receiver's roster yet is dropped as unknown. The author is the
sender. A client older than minor 13 drops the type and keeps using rank names.

The map is also in the snapshot (`SYNC_DATA`) of a sender who may author it, and whoever saved the map in force sends it
once after login (jittered with the other login resends).

## Rosters and assigned roles

Raid rosters (teams) and the addon role of each member are set by the guild master inside the addon (protocol
minor 5, plan 3.4.1 and 3.4.2).

- **Records:** `rosters[id] = { id, name, rev, updatedAt, updatedBy }` and `members[key] = { rosterId, rev,
  updatedAt, updatedBy }`. A member is in at most one roster (`rosterId` is a single value; a record that leaves it out
  means no roster). Messages: `ROSTER_UPSERT` and `ROSTER_DELETE` for the definitions, `MEMBER_UPSERT` and
  `MEMBER_DELETE` for the assignments. The addon role of a player is their guild rank (matched by name on the
  receiver), so a `role` in a `MEMBER_UPSERT` means nothing: an older client may still send one, it validates and is
  dropped, and a stored `role` is never read.
- **Authority:** `members_manage` from a global rank (gm or cogm) only, until the per-roster scoping of
  `docs/NAV_PERMISSIONS_PLAN.md` phases 4 and 5. The sender is recognised from the receiver's own guild roster (the
  guild master by **rank index 0**, never by a character name; everybody else by the rank name).
- **Conflicts and deletions:** like the blacklist (higher `rev`, then `updatedAt`, then sender). Removals leave
  tombstones `R:<rosterId>` and `M:<key>` in the shared tombstones, with the deleted revision plus one.
- **Events carry their roster:** `EVENT_UPSERT` has an optional `rosterId`; templates and loot sessions follow the
  roster of their event, so they need nothing of their own. The receiver checks it with the roster it holds for the
  sender (never from the message): a raid leader's new event has to say it is of their roster, they cannot move an
  event to another roster, and attendance, assignments, deletions and every loot message (session, candidacy, vote,
  award) from somebody who is not in the roster of the event, or has none, are refused as `other_roster`. The guild
  master acts on any roster. An event with no `rosterId` (made before rosters, or by an older client) stays open to
  the members who have a roster until the guild master assigns one. A message that leaves `rosterId` out never
  clears the roster an event already has, so an older client editing it does not undo the assignment. Only the
  guild master can delete something of an event the receiver has never seen.
- **Late joiners:** the rosters, the 300 most recently updated assignments and the newest removals are part of a
  snapshot only when the sender is an admin, and the receiver applies them under the role of the sender (a raid
  leader cannot relay or forge them). An admin also sends the roster definitions after login; the assignments of a
  member who was offline are only learned from an admin's snapshot, so a client that has never met the guild
  master online does not know its own assigned role yet.
- **Visibility is not access control.** Every client with the addon still receives every message on the guild
  channel; the roster only decides what the window shows and who may change what. See `docs/PRIVACY.md`.

## PvP seasons

A season system for PvP (protocol minor 7, `docs/PVP_MISSIONS_PLAN.md`): admins define missions that award points,
members claim them, an admin or a PvP officer approves each claim, the points make a season ranking, and the top 10
get a prize at the end. Points live in an **append-only ledger of grants**; the ranking is derived from it on every
client, so nothing but the grants has to be trusted.

- **Records:** season, mission, prizes, officer, claim, grant, void, reject, delivery and final, as listed in the table
  of message types. Each is validated by `PvPSeasonModel` (bounds, plain text, whole numbers; unknown fields are
  dropped). **No payload carries its author**: `by` is the message sender, or, inside a ledger catch-up, the author the
  item names.
- **Authority** is worked out by the receiver. An admin is the guild master of the receiver's own guild roster. A
  **PvP officer** is a flag, not a role: the receiver's own `PVP_OFFICER` records say since when (a list of
  `from`/`to` intervals, both ends included). Officers may approve and reject claims and mark deliveries; everything
  else is admin only. A grant counts if its author was an admin, or a PvP officer at the time of the grant and not
  approving a claim of their own; removing the flag does not undo earlier grants, and an admin voids any abusive one.
  A direct grant (an id that is not a claim id) is admin only.
- **Claims:** `id` is `<player>:<missionId>:<periodKey>:<n>` with the period `all`, `YYYYMMDD` (server day, UTC) or
  `YYYYWww` (ISO week, UTC), so a claim sent twice is one. Approving a claim sends a `PVP_GRANT` whose `id` is the claim
  id: two approvers make the same grant and the second is a no-op. Only a client that approves claims keeps them
  (`queue`: at most 300, 20 per player), and only for the active season, a mission it knows and inside the dates of
  the season; a claim it cannot place yet is refused and the claimant announces it again. A rejection leaves the claim
  in the queue marked rejected, so an approver can change their mind: a grant beats a rejection.
- **Conflicts:** season, mission, prizes, officer and delivery follow the usual rule (higher `rev`, then `updatedAt`,
  then sender). A grant, a void and a final are append-only: the first record with that id wins and a replay is a
  no-op. For a reject the latest `at` wins (then the larger author). A second active season is refused. The final of
  a season is **authoritative**: after it, grants, voids and rejections of that season are ignored.
- **Closing a season:** the closing admin sends `PVP_FINAL` (the standing, up to 100 rows, cut from the tail if it
  does not fit one message, never below 10) and then the season as `closed`. Every client, on receiving the final,
  deletes the grants, voids, rejections and queued claims of that season, creates one delivery per player in the
  prize tiers (positions 1 to 10) and drops the detail of its own mission log. A season a client never saw is kept
  as history. The addon never sends gold or mail: delivery is done in game and marked with `PVP_DELIVERY`.
- **Ranking:** points per player from the grants that count; ties go to whoever reached the total first (the earlier
  `at` of their last counted grant), then name. Nobody without points is ranked. Tiers: 1, 2, 3, 4 to 6, 7 to 10.
- **Ledger catch-up (late joiners):** the ranking has to be complete, so it does not travel in `SYNC_DATA`. After
  login (at the same moment as `SYNC_REQ`) and whenever a season becomes active, a client sends `PVP_LEDGER_REQ` with
  the number of ledger records it holds for its active season and a digest (Adler-32 of the sorted record tokens: the
  officers, the seasons, the finals and the deliveries, and for that season its missions, prizes, grants, voids and
  rejections). A raid leader, admin or PvP officer whose own ledger differs answers, after a random 1 to 10 second
  delay and at most once a minute per requester, by whispering `PVP_LEDGER_DATA` pages: officers first (they decide who
  may write what), then the seasons, the missions, prizes, grants, voids, rejections of the requested season and the
  relay's active one, every final and every delivery. A page holds at most 400 items and fits the snapshot limit (32 KB
  encoded); there are at most 100 pages. The requester decodes a page only if the whisper comes from a raid leader,
  admin or PvP officer according to its own data, and applies every item as if its `by` had sent it, through the same
  validation, authority and conflict rules. Because `by` is read from the item, a relay is trusted to name the right
  author, the same trust a `PVP_STATS` snapshot gives it. Claims still waiting for a decision travel in the
  catch-up only between approvers: a request from a gm or cogm carries `queue = true`, the digest then also covers the
  undecided claims, and the relay (a gm or cogm) adds them as `PVP_CLAIM` items, last, with the claimant as `by`. A
  relay that is not a gm or cogm cannot hand claims in. The claimant also sends its pending claims again when it hears
  a HELLO from a gm or cogm (at most every 2 minutes), so a claim is not stuck when its author is never online with an
  approver.
- **Duel evidence (minor 17):** the evidence of a `duel_wins` claim is made of rows `{at, victim, mapId?, duel = true}`: `duel`
  is exactly `true`, `victim` is text of at most `PVP_FEED_VICTIM_MAX` characters, and the row carries none of `place`,
  `bgWin`, `kos`, `guild`, `class` or `race` (a row that does is refused with the whole claim, `invalid:evidence`). A
  `duel_wins` goal keeps only `count`, `zones`, `distinct` (`none` or `name`), `victimCapPerDay`, `window`,
  `maxCompletions` and `autoClaim`; `place` is forced to `any` and the kill-only fields are dropped.
- **Progress summaries (`PVP_PROGRESS`):** a member shares, at most every 2 minutes and only when something changed,
  how far they are in each mission of the active season (counts only, no evidence). Only a client that approves claims
  keeps the last summary of each member (up to 1000, `db.global.pvpSeason.progress`, dropped when the season closes). It
  is display only and not checked; the claim decides. It never travels in a catch-up.
- **Older clients:** a client without these fields drops the optional goal fields while validating (so it would count
  more than the officer asked) and refuses a mission of kind `bg_played` or `duel_wins` (`invalid:goal`; no partial counting); the admin form warns
  when a mission uses them. `maxCompletions` is also enforced by approvers when a claim arrives (`limit`).
- **Order:** a record that reaches a client before the one that authorises it (a grant of an officer before the officer
  record, a claim before its mission) is refused and comes back with the next catch-up. Records an admin wrote do not
  depend on any other and may arrive in any order (a void before its grant, a grant before its season).
- **Interim commands:** until the PvP tab has its own sub-tabs, `/nrage pvp` (`season`, `officer`, `mission`, `claim`,
  `queue`, `approve`, `reject`, `grant`) drives the same service, for testing.

## Event sign-up

Protocol minor 8 (`docs/NAV_PERMISSIONS_PLAN.md` 3.4.1). A player says whether they are coming; the leader's record of
what happened (`ATTENDANCE_UPSERT`) is a separate thing, and a sign-up never touches it.

- **Record:** `event.signups[characterKey] = { status, rev, updatedAt, updatedBy }`, `status` is `yes` or `no`; no
  entry means not answered. At most `EVENT_ATTENDANCE_MAX` entries per event. An event without the table (made by an
  older client) counts as having none.
- **Authority:** `SIGNUP_UPSERT` is accepted only when `characterKey` is the sender, the rank of the sender (read from
  the receiver's guild roster) has `event_signup` (gm, cogm, and officer, rl and roster with a roster), and the event
  is visible to the roster the receiver holds for the sender (the event's roster, or none yet; gm and cogm any).
  Otherwise `forbidden`, `unknown_sender` or `other_roster`.
- **Conflicts:** last writer wins per character (higher `rev`, then `updatedAt` clamped to 5 minutes ahead, then the
  sender), like attendance. The receiver does not check the closing time of the sign-up (planned or open, not yet
  started): the sender enforces it, and a queued or relayed answer can arrive late.
- **Late joiners:** the sign-ups are part of a snapshot. Here, and only inside `SYNC_DATA` (accepted from a raid
  leader or admin), the item names the character and is applied under that character's own rank and roster as the
  receiver knows them, so a relayed sign-up gets the same checks as a live one. On the guild channel a
  `characterKey` that is not the sender is never accepted. The text export carries sign-ups, but an import skips them
  (the importer is not the character).

## Recipes

`RECIPES` carries the recipes a member has learned in one profession, as numeric ids (names and icons are looked up
in the client). A profession can have hundreds of recipes and a message is limited to 255 encoded bytes, so a list
is sent as `parts` messages of at most 150 ids. The receiver keeps the parts aside, in memory, until all of them
arrived and only then replaces the stored list, so a list that never completes changes nothing. A newer `rev`
starts a new list and drops the half-received one; a `rev` that does not beat the stored one is ignored. The record
belongs to the sender (there is no name in the payload) and any member may send their own. Bounds: 3000 ids per
profession, 12 professions per member, 500 members, 100 half-received lists. The revision only goes up when the
recipes changed, so an unchanged scan sends nothing. Recipes are not part of the snapshot: they are resent 30 to 60
seconds after login and whenever a scan finds a change.

## Deletions

A `DELETE` removes the record and leaves a **tombstone** (`E:<eventId>` or `A:<eventId>:<assignmentId>`; the
blacklist has its own, see above) with the
deleted revision plus one. An upsert whose `rev` does not exceed the tombstone's is dropped, so a stale message
cannot bring deleted data back; on a tie the delete wins. A newer revision does resurrect the record. Tombstones
are bounded (500) and expire after 30 days.

## Rate limits and queues

- Received: at most 60 messages per minute per sender, checked before decoding; at most 200 tracked senders.
- Snapshots: at most 4 per minute per sender, and only from senders whose role can manage events. PvP ledger pages
  (whispers from a raid leader, admin or PvP officer) have their own limit of 100 per minute per sender, checked
  before decoding.
- Sent: everything goes through a queue of at most 100 messages, kept at most 120 seconds. While the encounter
  lockdown is active (`C_ChatInfo.InChatMessagingLockdown()`), nothing is sent; when it ends the queue drains with
  a random delay of up to 5 seconds. A newer message for the same record replaces a queued older one.
- A new `HELLO` peer, or a `HELLO` with `ask`, is answered at most once every 30 seconds, after a random delay. The
  Installed check tab sends a `HELLO` with `ask` at most once a minute.

## Snapshot for late joiners

1. Roughly 8 to 20 seconds after login (once the guild roster had time to load) the client sends `SYNC_REQ`.
2. A raid leader or admin answers, after a random 1 to 10 second delay and at most once a minute per requester,
   by whispering `SYNC_DATA`: the 20 most recent events with their attendance, assignments and loot sessions or
   awards, plus every tombstone. If it does not fit, the number of events is halved until it does. When the answering
   leader is a `gm` or `cogm`, the snapshot also carries the newest announcements and their removals (see *Announcements*),
   which shrink with the events.
3. The requester decodes it only if the whisper comes from someone whose role allows managing events, and applies
   every item as if that leader had sent it, through the same validation, authority and conflict rules.

The PvP season ledger is not part of `SYNC_DATA` either: it has its own catch-up (see "PvP seasons").

Loot candidates and votes are not part of a snapshot: on the wire they always belong to the sender and cannot be
re-attributed to whoever relays them.

PvP records are part of a snapshot, and here is the one documented exception to "the author is the sender": inside
`SYNC_DATA` (only accepted from a raid leader or admin, checked before decoding) a `PVP_STATS` item carries the
`owner` of the record, validated like a character name, and is applied as if that owner had sent it, through the
same plausibility and conflict rules, so a relayed record cannot lower or outrun what a client already holds. On
the guild channel an `owner` is never accepted. The PvP part is capped separately: the 100 most recently updated
records and the 100 highest resets, shrinking together with the events if the snapshot does not fit. The resets
in a snapshot only count when its sender is an admin (a raid leader cannot reset anybody). PvP is not part of the
text export.

## Limits on stored data

30 announcements (and 200 announcement tombstones), 20 rosters, 1000 role and roster assignments, 100 events, 60 attendance rows and 50 assignments per event, 40 loot sessions per event with at most 40 candidates
and 30 votes each, 500 received profiles, 1000 PvP records and 1000 reset floors, 200 blacklist entries, 20 templates.
PvP seasons: 60 seasons, 50 missions per season, 3000 grants per season (never evicted), 3000 voids, 3000 rejections,
300 queued claims (20 per player), 50 finals, 20 officers with 10 intervals each, 10 deliveries per season. Events are purged 90 days after their start.

## Text import and export

`NRAGE1:` followed by LibSerialize, LibDeflate and the print encoding of `{ items = { { t, p } ... } }`, the same
raid items a snapshot carries (never PvP records or the blacklist: an imported `PVP_STATS`, `PVP_RESET` or
`BLACKLIST_*` item is skipped). Import requires the manage-events role, accepts at most 32 KB of text, 256 KB decoded and
3000 items, and applies each item like a received message, with the sender `import`.
