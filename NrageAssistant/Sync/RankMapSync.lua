local _, ns = ...

-- Applies the rank map received from the guild, and builds the payload for it (docs/ANNOUNCEMENTS_MODULES_PVP_PLAN.md,
-- part D).
--
-- RANK_MAP { rev, updatedAt, ranks = { { i = rankIndex, r = role, n = rankName }, ... } } replaces the whole map of the
-- guild of the receiver. The sender is the author; authority is worked out here, never read from the message:
--   - the sender is the guild master: their roster entry has rankIndex 0 (the name never counts); or
--   - the sender's role is cogm according to the map the receiver holds BEFORE this one is applied. The incoming map
--     never authorizes itself.
-- A co-guild master is also held to two guards, and the whole message is dropped on a violation: the row of the
-- sender's own rank must stay cogm (no self-promotion or demotion), and `gm` is never a role of a rank (the validator
-- refuses it; index 0 is not in the map).
-- A newer map wins by `rev`, then `updatedAt`, then sender (SyncRules.Wins); an identical message is a no-op.
--
-- ctx = { maps = db.global.rankMaps, guildKey = "<guild>-<realm>" or nil, now = function(),
--         entryOf = function(name) -> { rankName, rankIndex } or nil (the guild roster of the receiver) }
-- Apply returns true, or false plus "unsupported" | "no_guild" | "invalid" | "unknown_sender" | "forbidden" |
-- "self_row" | "stale".
local RankMapSync = {}

local Rules = ns.SyncRules
local Model = ns.RankMapModel

local MESSAGE = "RANK_MAP"
local NO_MAP = { ranks = {} }

function RankMapSync.IsRankMapMessage(messageType)
  return messageType == MESSAGE
end

-- The map held for the guild, or nil when there is none or it is damaged.
local function heldMap(ctx)
  local held = ctx.maps[ctx.guildKey]
  if type(held) == "table" and type(held.ranks) == "table" and type(held.rev) == "number" then
    return held
  end
  return nil
end

-- May somebody with this roster entry author a rank map, according to the map `held` (nil: none saved)? The guild
-- master by the rank index, a co-guild master by the role the held map gives them.
function RankMapSync.MayAuthor(entry, held)
  if type(entry) ~= "table" then
    return false
  end
  if ns.PermissionService.IsGuildMasterIndex(entry.rankIndex) then
    return true
  end
  return type(entry.rankIndex) == "number"
    and ns.PermissionService.RoleOfEntry(entry, nil, held or NO_MAP) == "cogm"
    and ns.PermissionService.Can("cogm", "ranks_manage")
end

-- `message` must already be validated by Protocol; the payload is checked again here, since a direct caller has not
-- been through it.
function RankMapSync.Apply(ctx, message, sender)
  if type(message) ~= "table" or message.t ~= MESSAGE then
    return false, "unsupported"
  end
  if type(ctx.guildKey) ~= "string" then
    return false, "no_guild"
  end
  local payload = Model.ValidateWire(message.p)
  if not payload then
    return false, "invalid"
  end

  -- Authority first, with the map held now.
  local held = heldMap(ctx)
  local entry = ctx.entryOf and ctx.entryOf(sender) or nil
  if type(entry) ~= "table" then
    return false, "unknown_sender"
  end
  if not RankMapSync.MayAuthor(entry, held) then
    return false, "forbidden"
  end
  local incoming = Model.FromWire(payload)
  if not ns.PermissionService.IsGuildMasterIndex(entry.rankIndex) then
    -- A co-guild master: the row of their own rank has to stay cogm.
    if Model.Resolve(incoming, entry.rankName, entry.rankIndex) ~= "cogm" then
      return false, "self_row"
    end
  end

  local updatedAt = Rules.ClampTimestamp(ctx, payload.updatedAt)
  if
    held
    and not Rules.Wins(
      payload.rev,
      updatedAt,
      sender,
      { rev = held.rev, updatedAt = held.updatedAt, updatedBy = held.by }
    )
  then
    return false, "stale"
  end

  incoming.updatedAt = updatedAt
  incoming.by = sender
  ctx.maps[ctx.guildKey] = incoming
  return true
end

-- A snapshot item ({ t, p }) applied as if `sender` had sent it: validated like any message first.
function RankMapSync.ApplyItem(ctx, item, sender)
  local message, invalid = ns.Protocol.Validate(ns.Protocol.Build(item.t, item.p, "import"))
  if not message then
    return false, invalid
  end
  return RankMapSync.Apply(ctx, message, sender)
end

-- What a stored map looks like on the wire, or nil while there is none.
function RankMapSync.Payload(rankMap)
  if type(rankMap) ~= "table" or type(rankMap.ranks) ~= "table" or type(rankMap.rev) ~= "number" then
    return nil
  end
  local payload = Model.ToWire(rankMap)
  return Model.ValidateWire(payload) and payload or nil
end

-- The snapshot item for a stored map, or nil when there is none or it does not validate.
function RankMapSync.SnapshotItem(rankMap)
  local payload = RankMapSync.Payload(rankMap)
  if not payload then
    return nil
  end
  return { t = MESSAGE, p = payload }
end

ns.RankMapSync = RankMapSync
