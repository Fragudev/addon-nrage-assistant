local _, ns = ...

-- Applies the readiness rules of a roster received from the guild, and builds the payload for them.
--
-- ROSTER_RULES { rosterId, rev, updatedAt, rules } replaces the whole set of one roster. Authority: the sender's role
-- comes from the receiver's own guild roster (`role`), never from the message. gm and cogm set the rules of any
-- roster; an rl only those of the roster it belongs to, read from the receiver's own assignments (`rules_edit`
-- at the "own" scope); every other rank is refused. A newer set wins by `rev`, then `updatedAt`, then sender
-- (SyncRules.Wins), per roster; an identical message is a no-op. A snapshot for a late joiner carries the set of every
-- roster, but it is applied under the role of whoever sent the snapshot, so it only counts when that is a gm or cogm;
-- a gm or cogm also sends the sets once after login, and an rl the one of its own roster.
-- A roster that was deleted (its tombstone "R:<id>") takes no rules, and its record is dropped (Forget).
--
-- ctx = { records = db.global.readinessRulesByRoster, rosters, members, tombstones, now = function() }
-- Returns true, or false plus "unknown_sender" | "forbidden" | "tombstoned" | "stale" | "unsupported".
local ReadinessRulesSync = {}

local Rules = ns.SyncRules

local MESSAGE = "ROSTER_RULES"

function ReadinessRulesSync.IsRulesMessage(messageType)
  return messageType == MESSAGE
end

-- May somebody with `role` whose roster is `senderRosterId` set the rules of `rosterId`? Nil when allowed, else the
-- reason.
function ReadinessRulesSync.Authorize(role, senderRosterId, rosterId)
  if role == nil then
    return "unknown_sender"
  end
  local scope = ns.PermissionService.Scope(role, "rules_edit", senderRosterId)
  if scope == "all" or (scope == "own" and senderRosterId == rosterId) then
    return nil
  end
  return "forbidden"
end

-- `message` must already be validated by Protocol.
function ReadinessRulesSync.Apply(ctx, message, sender, role)
  if message.t ~= MESSAGE then
    return false, "unsupported"
  end
  local payload = message.p
  local denied = ReadinessRulesSync.Authorize(role, ns.RosterService.SenderRoster(ctx, sender), payload.rosterId)
  if denied then
    return false, denied
  end
  if ctx.tombstones and ctx.tombstones["R:" .. payload.rosterId] then
    return false, "tombstoned"
  end

  local updatedAt = Rules.ClampTimestamp(ctx, payload.updatedAt)
  local record = ctx.records[payload.rosterId]
  if record and record.rules and not Rules.Wins(payload.rev, updatedAt, sender, record) then
    return false, "stale"
  end
  if not record then
    record = {}
    ctx.records[payload.rosterId] = record
  end

  record.rules = payload.rules
  record.rev = payload.rev
  record.updatedAt = updatedAt
  record.updatedBy = sender
  return true
end

-- What a stored set looks like on the wire, or nil while the roster has set none.
function ReadinessRulesSync.Payload(rosterId, record)
  if rosterId == nil or type(record) ~= "table" or type(record.rules) ~= "table" then
    return nil
  end
  return { rosterId = rosterId, rev = record.rev, updatedAt = record.updatedAt, rules = record.rules }
end

-- The snapshot item for the stored set of a roster, or nil when there is none or it does not validate.
function ReadinessRulesSync.SnapshotItem(rosterId, record)
  local payload = ReadinessRulesSync.Payload(rosterId, record)
  if not payload then
    return nil
  end
  local message = ns.Protocol.Validate(ns.Protocol.Build(MESSAGE, payload, "snapshot"))
  return message and { t = MESSAGE, p = message.p } or nil
end

-- The items for every roster that exists and has a set, by roster name.
function ReadinessRulesSync.SnapshotItems(records, rosters)
  local items = {}
  for _, roster in ipairs(ns.RosterService.List(rosters)) do
    local item = ReadinessRulesSync.SnapshotItem(roster.id, records[roster.id])
    if item then
      items[#items + 1] = item
    end
  end
  return items
end

-- The rosters whose set the role may author, with their payloads: every stored one for gm and cogm, the own
-- roster's for an rl. For the resend after login.
function ReadinessRulesSync.Authored(records, role, ownRosterId)
  local payloads = {}
  for rosterId, record in pairs(records) do
    if not ReadinessRulesSync.Authorize(role, ownRosterId, rosterId) then
      payloads[#payloads + 1] = ReadinessRulesSync.Payload(rosterId, record)
    end
  end
  table.sort(payloads, function(a, b)
    return a.rosterId < b.rosterId
  end)
  return payloads
end

-- A deleted roster keeps no rules.
function ReadinessRulesSync.Forget(records, rosterId)
  records[rosterId] = nil
end

ns.ReadinessRulesSync = ReadinessRulesSync
