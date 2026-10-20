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
- AceComm on `GUILD` for shared data and on `WHISPER` for snapshots. Any other channel is ignored.
- Encoding: LibSerialize, then LibDeflate compression, then the addon-channel encoding. A guild message may be up to
  4096 characters encoded and 32 KB decoded; a snapshot up to 32 KB encoded and 256 KB decoded.
- Secret values (encounter restrictions) raised while handling a message make the message be dropped silently.

## Envelope

```text
{ v = major, m = minor, t = type, id = messageId, p = payload }
```

- `v` must equal the receiver's major version (currently 1); a different major is reported as an incompatible
  peer and the local data is left alone. `m` only adds optional fields.
- `id` is 1 to 40 characters from `[A-Za-z0-9_-]`; a `(sender, id)` pair is processed once (a bounded cache of the
  last 200).

## Message types

`rev` is an integer from 1, `updatedAt` a server-time timestamp up to the year 2100. Text fields are plain text of
the length given by the model (title 60, encounter 60, item name 60, reason 100, note 100, ...).

| Type | Channel | Payload (validated fields) | Who may send it |
|---|---|---|---|
| `HELLO` | guild | `version` | anyone |
| `PROFILE` | guild | `rev`, `class`, `level`, optional `ilvl`, `professions[]`, `fields{role, main, notes}` | anyone, for themselves |
| `EVENT_UPSERT` | guild | `eventId`, `rev`, `updatedAt`, `title`, optional `instance`, `startAt`, `status` | rl, admin |
| `ATTENDANCE_UPSERT` | guild | `eventId`, `characterKey`, `state`, `rev`, `updatedAt` | rl, admin |
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
| `LAYER_STATE` | guild | `map` (0 to 9999), `layer` (0 to 2147483647; `0` means "forget me") | anyone, for themselves; the layer belongs to the sender |
| `LAYER_SWAP` | guild | `rid`, `s` (`request`, `offer`, `assign` or `close`), and by step: `map` + `layer` (`request`), `helper` (`assign`), `o` (`close`: `done`, `expired`, `cancelled`, `declined` or `unconfirmed`) | anyone; the actor is the sender |
| `READINESS_RULES` | guild | `rev`, `updatedAt`, `rules[]` (up to 30 rules, each validated: see Guild readiness rules) | admin |
| `LOOT_AWARD` | guild | `eventId`, `sessionId`, `rev`, `updatedAt`, `itemId`, `itemName`, `characterKey`, `reason` | council, admin |
| `SYNC_REQ` | guild | none | anyone |
| `SYNC_DATA` | whisper | `items[]`, a list of `{ t, p }` raid, loot, PvP, blacklist or readiness rules messages (a `PVP_STATS` item also carries `owner`, a `BLACKLIST_UPSERT` item `addedBy` and `addedAt`) | rl, admin (checked before decoding) |

`guid` is deliberately never sent.

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

Protocol minor version 5. Older clients drop both types with `unknown_type`. Both are **guild channel only** (never a
whisper, never part of a snapshot) and live only: nothing is saved. A sender must be a known guild member
(`layer_share`, every role).

`LAYER_STATE` is the sender's own layer, a pair `(map, layer)` read from creature GUIDs (see `docs/API_NOTES.md`).
It is sent when the layer changes and again every 300 seconds, at most once per 30 seconds (queue key `LY`), and
refused during an encounter lockdown instead of waiting. `layer = 0` means "forget me" and is sent once when the
player turns "Share my layer" off. The receiver keeps it in memory for 15 minutes.

`LAYER_SWAP` is one step of a swap, tied together by `rid`, which the requester makes. The actor is always the
**sender**; a name in the payload is only data.

| Step | Sent by | Meaning |
|---|---|---|
| `request` | requester | wants to be on `(map, layer)` |
| `offer` | an eligible member on that layer | can help |
| `assign` | requester | the first offer won; `helper` names who |
| `close` | requester (`o` = `done`, `expired`, `cancelled`, `unconfirmed`), or the assigned helper (`o = declined`) | the swap is over |

Only the requester of a `rid` may send `assign` and `close`, with the one exception of `close declined` from the
assigned helper; the receiver checks this against the sender of the stored request, so another member cannot
hijack or close a swap. A client takes part in at most one swap at a time and drops one whose `close` was lost
after 300 seconds without messages. Like `PVP_KILL`, a step is never queued during an encounter lockdown.

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

## Guild readiness rules

One set of readiness rules for the whole guild (issue #32), in a single record `{ rev, updatedAt, updatedBy, rules }`
that an admin replaces as a whole with `READINESS_RULES`. The protocol minor version was raised to 4 for it.

- **Authority:** `rules_edit`, admin only, read from the receiver's own guild roster. A newer `rev` wins, then
  `updatedAt` (clamped), then the sender; a replay is a no-op. Until a set arrives, the starting checklist applies.
- **Rule validation:** every rule is checked field by field, and unknown fields are dropped. `check` is one of
  `field`, `confirm`, `level`, `ilvl`, `profession`, `enchants` or `buff`, with the numbers or lists that check
  needs (levels and item levels 1 to 999, enchant slots 1 to 18, up to 20 spell ids or names). `evidenceMode`
  is worked out from the check and never taken from the message. Ids are unique, up to 32 characters of `[%w_]`.
- **Late joiners:** the set is part of a snapshot only when the sender is an admin, and the receiver applies it
  under the role of the sender, so a leader who is not an admin cannot relay (or forge) rules. For the members who
  were not online, an admin also sends the set once after login.

## Deletions

A `DELETE` removes the record and leaves a **tombstone** (`E:<eventId>` or `A:<eventId>:<assignmentId>`; the
blacklist has its own, see above) with the
deleted revision plus one. An upsert whose `rev` does not exceed the tombstone's is dropped, so a stale message
cannot bring deleted data back; on a tie the delete wins. A newer revision does resurrect the record. Tombstones
are bounded (500) and expire after 30 days.

## Rate limits and queues

- Received: at most 60 messages per minute per sender, checked before decoding; at most 200 tracked senders.
- Snapshots: at most 4 per minute per sender, and only from senders whose role can manage events.
- Sent: everything goes through a queue of at most 100 messages, kept at most 120 seconds. While the encounter
  lockdown is active (`C_ChatInfo.InChatMessagingLockdown()`), nothing is sent; when it ends the queue drains with
  a random delay of up to 5 seconds. A newer message for the same record replaces a queued older one.
- A new `HELLO` peer is answered at most once every 30 seconds, after a random delay.

## Snapshot for late joiners

1. Roughly 8 to 20 seconds after login (once the guild roster had time to load) the client sends `SYNC_REQ`.
2. A raid leader or admin answers, after a random 1 to 10 second delay and at most once a minute per requester,
   by whispering `SYNC_DATA`: the 20 most recent events with their attendance, assignments and loot sessions or
   awards, plus every tombstone. If it does not fit, the number of events is halved until it does.
3. The requester decodes it only if the whisper comes from someone whose role allows managing events, and applies
   every item as if that leader had sent it, through the same validation, authority and conflict rules.

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

100 events, 60 attendance rows and 50 assignments per event, 40 loot sessions per event with at most 40 candidates
and 30 votes each, 500 received profiles, 1000 PvP records and 1000 reset floors, 200 blacklist entries, 20 templates. Events are purged 90 days after their start.

## Text import and export

`NRAGE1:` followed by LibSerialize, LibDeflate and the print encoding of `{ items = { { t, p } ... } }`, the same
raid items a snapshot carries (never PvP records or the blacklist: an imported `PVP_STATS`, `PVP_RESET` or
`BLACKLIST_*` item is skipped). Import requires the manage-events role, accepts at most 32 KB of text, 256 KB decoded and
3000 items, and applies each item like a received message, with the sender `import`.
