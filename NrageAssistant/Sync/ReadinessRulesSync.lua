local _, ns = ...

-- Applies the guild's readiness rules received from an admin, and builds the payload for them.
--
-- READINESS_RULES replaces the whole set. Authority: the sender's role comes from the receiver's own guild roster
-- (`role`), never from the message, and `rules_edit` is gm and cogm only until the per-roster rules
-- (docs/NAV_PERMISSIONS_PLAN.md phase 4) arrive. A newer set wins by `rev`, then `updatedAt`, then sender
-- (SyncRules.Wins); an identical message is a no-op. A snapshot for a late joiner carries the set too, but it is
-- applied under the role of whoever sent the snapshot, so it only counts when that is a gm or cogm; a gm or cogm
-- also sends the set once after login for the members who were not there.
--
-- ctx = { record = db.global.readinessRules, now = function() }
-- Returns true, or false plus "unknown_sender" | "forbidden" | "stale" | "unsupported".
local ReadinessRulesSync = {}

local Rules = ns.SyncRules

local MESSAGE = "READINESS_RULES"

function ReadinessRulesSync.IsRulesMessage(messageType)
  return messageType == MESSAGE
end

-- `message` must already be validated by Protocol.
function ReadinessRulesSync.Apply(ctx, message, sender, role)
  if message.t ~= MESSAGE then
    return false, "unsupported"
  end
  local denied = Rules.AuthorizeGlobal(role, "rules_edit")
  if denied then
    return false, denied
  end

  local payload = message.p
  local updatedAt = Rules.ClampTimestamp(ctx, payload.updatedAt)
  local record = ctx.record
  if record.rules and not Rules.Wins(payload.rev, updatedAt, sender, record) then
    return false, "stale"
  end

  record.rules = payload.rules
  record.rev = payload.rev
  record.updatedAt = updatedAt
  record.updatedBy = sender
  return true
end

-- What a stored set looks like on the wire, or nil while the guild has set none.
function ReadinessRulesSync.Payload(record)
  if type(record) ~= "table" or type(record.rules) ~= "table" then
    return nil
  end
  return { rev = record.rev, updatedAt = record.updatedAt, rules = record.rules }
end

-- The snapshot item for the stored set, or nil when there is none or it does not validate.
function ReadinessRulesSync.SnapshotItem(record)
  local payload = ReadinessRulesSync.Payload(record)
  if not payload then
    return nil
  end
  local message = ns.Protocol.Validate(ns.Protocol.Build(MESSAGE, payload, "snapshot"))
  return message and { t = MESSAGE, p = message.p } or nil
end

ns.ReadinessRulesSync = ReadinessRulesSync
