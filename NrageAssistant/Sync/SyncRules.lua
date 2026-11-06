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
-- own roster (members_manage) and the code that checks that roster does not exist yet.
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

local MAX_TIMESTAMP = 4102444800 -- 2100-01-01, as in Protocol

-- The original author and date an item of a snapshot may carry (`origin` = { addedBy, addedAt }), or nil when it
-- carries none. Returns false when one of them is there but unusable. Shared by the blacklist and the guild Kill On
-- Sight list, whose snapshot items name the member who added the entry.
function SyncRules.ReadOrigin(origin)
  if origin == nil then
    return nil
  end
  if type(origin) ~= "table" or not ns.EventModel.IsCharacterKey(origin.addedBy) then
    return false
  end
  if not ns.Validate.Int(origin.addedAt, 0, MAX_TIMESTAMP) then
    return false
  end
  return { addedBy = origin.addedBy, addedAt = origin.addedAt }
end

ns.SyncRules = SyncRules
