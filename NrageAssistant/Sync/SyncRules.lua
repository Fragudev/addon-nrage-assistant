local _, ns = ...

-- Rules shared by everything that applies received data (raid events, loot council):
-- who is allowed, how far in the future a timestamp may claim to be, which of two records wins,
-- and whether a tombstone blocks an upsert.
local SyncRules = {}

SyncRules.MAX_FUTURE_SKEW_SECONDS = 300

function SyncRules.CountKeys(tbl)
  local count = 0
  for _ in pairs(tbl) do
    count = count + 1
  end
  return count
end

-- nil when allowed, otherwise the reason. A sender the roster does not know gets nothing.
function SyncRules.Authorize(role, action)
  if role == nil then
    return "unknown_sender"
  end
  if not ns.PermissionService.Can(role, action) then
    return "forbidden"
  end
  return nil
end

-- Like Authorize, but only for gm and cogm (the ranks that act on every roster). For what a rank may do only on its
-- own roster (members_manage, rules_edit) and the code that checks that roster does not exist yet.
function SyncRules.AuthorizeGlobal(role, action)
  if role == nil then
    return "unknown_sender"
  end
  if not ns.PermissionService.CanAll(role, action) then
    return "forbidden"
  end
  return nil
end

-- A sender cannot date an edit in the future to always win.
function SyncRules.ClampTimestamp(ctx, updatedAt)
  return math.min(updatedAt, ctx.now() + SyncRules.MAX_FUTURE_SKEW_SECONDS)
end

-- Does an incoming record beat the one held? Higher `rev` first, then later `updatedAt`, then the
-- lexicographically larger sender; an identical record does not win, so replays are no-ops.
function SyncRules.Wins(rev, updatedAt, sender, current)
  if rev ~= current.rev then
    return rev > current.rev
  end
  if updatedAt ~= current.updatedAt then
    return updatedAt > current.updatedAt
  end
  return sender > (current.updatedBy or "")
end

-- True if a tombstone blocks an upsert with this revision.
function SyncRules.BlockedByTombstone(ctx, key, rev)
  local tombstone = ctx.tombstones[key]
  return tombstone ~= nil and rev <= tombstone.rev
end

ns.SyncRules = SyncRules
