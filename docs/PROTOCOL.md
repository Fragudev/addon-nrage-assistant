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
| `LOOT_AWARD` | guild | `eventId`, `sessionId`, `rev`, `updatedAt`, `itemId`, `itemName`, `characterKey`, `reason` | council, admin |
| `SYNC_REQ` | guild | none | anyone |
| `SYNC_DATA` | whisper | `items[]`, a list of `{ t, p }` raid, loot or PvP messages (a `PVP_STATS` item also carries `owner`) | rl, admin (checked before decoding) |

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

## Deletions

A `DELETE` removes the record and leaves a **tombstone** (`E:<eventId>` or `A:<eventId>:<assignmentId>`) with the
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
and 30 votes each, 500 received profiles, 1000 PvP records and 1000 reset floors, 20 templates. Events are purged 90 days after their start.

## Text import and export

`NRAGE1:` followed by LibSerialize, LibDeflate and the print encoding of `{ items = { { t, p } ... } }`, the same
raid items a snapshot carries (never PvP records: an imported `PVP_STATS` or `PVP_RESET` item is skipped). Import requires the manage-events role, accepts at most 32 KB of text, 256 KB decoded and
3000 items, and applies each item like a received message, with the sender `import`.
