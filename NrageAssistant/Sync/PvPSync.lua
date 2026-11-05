local _, ns = ...

-- Applies received PvP counters to local data, and builds the payloads for them.
--
-- PVP_STATS follows the PROFILE model: the record belongs to the sender (`owner`), never to a name in the
-- payload. Authority comes from the receiver's own guild roster (`role`). The one exception is a snapshot for a
-- late joiner, where a leader (RL/admin) relays other members' records and names the owner of each item.
--
-- Conflicts: the higher `rev` wins, then the later (clamped) `updatedAt`, then the larger owner name; an
-- identical record is a no-op. On top of that a record must be plausible next to the one already held: the
-- totals never go down, and they never grow faster than Constants.PVP_MAX_KILLS_PER_HOUR. That limits what a
-- modified client can claim; it cannot make the numbers true.
--
-- PVP_RESET (admin only) zeroes the record of a member and raises the minimum `rev` accepted for them, so the
-- totals they had cannot come back. The reset of this client's own key is handed to `ctx.onOwnReset(rev)`.
--
-- ctx = { pvpStats = db.global.pvpStats, pvpResets = db.global.pvpResets, now = function(),
--         ownKey = function() -> string (optional), onOwnReset = function(rev) (optional) }
-- Every function returns true, or false plus:
--   "unknown_sender" | "forbidden" | "reset" | "stale" | "implausible" | "limit" | "unsupported"
local PvPSync = {}

local Rules = ns.SyncRules
local countKeys, authorize, clampTimestamp = Rules.CountKeys, Rules.Authorize, Rules.ClampTimestamp

local SECONDS_PER_HOUR = 3600

local function copyPair(pair)
  return { world = pair.world, bg = pair.bg }
end

local function pairTotal(pair)
  return pair.world + pair.bg
end

local function lower(new, old)
  return new.world < old.world or new.bg < old.bg
end

local function within(part, whole)
  return part.world <= whole.world and part.bg <= whole.bg
end

-- Is `payload` believable next to `current` (the record held for the same owner, or nil)?
local function plausible(payload, current, updatedAt)
  local high = ns.Constants.PVP_MAX_KILLS
  if pairTotal(payload.honor) > high or (payload.blows and pairTotal(payload.blows) > high) then
    return false
  end
  -- A day cannot hold more than the total, and killing blows of a day need killing blows in the total.
  local today = payload.today
  if not within(today.honor, payload.honor) then
    return false
  end
  if today.blows and not (payload.blows and within(today.blows, payload.blows)) then
    return false
  end
  if not current then
    return true
  end

  if lower(payload.honor, current.honor) then
    return false
  end
  if payload.blows and current.blows and lower(payload.blows, current.blows) then
    return false
  end
  -- At least one hour's worth is always allowed, so a quick second message or an equal timestamp never means
  -- a zero window.
  local hours = math.max(1, (updatedAt - current.updatedAt) / SECONDS_PER_HOUR)
  local allowed = ns.Constants.PVP_MAX_KILLS_PER_HOUR * hours
  return pairTotal(payload.honor) - pairTotal(current.honor) <= allowed
end

-- Makes room for a record of `owner`: when the table is full the record updated longest ago goes, because a
-- member who left the guild stops sending.
local function makeRoom(ctx, owner)
  if ctx.pvpStats[owner] or countKeys(ctx.pvpStats) < ns.Constants.GUILD_ROSTER_MAX then
    return
  end
  local oldestName, oldestAt
  for name, record in pairs(ctx.pvpStats) do
    local at = type(record) == "table" and type(record.updatedAt) == "number" and record.updatedAt or 0
    if not oldestAt or at < oldestAt or (at == oldestAt and name < oldestName) then
      oldestName, oldestAt = name, at
    end
  end
  ctx.pvpStats[oldestName] = nil
end

-- `relayed`: the record comes from a snapshot, not from its owner. A relay may not push the revision far ahead, which
-- would make the owner's own later messages look stale for good.
local function applyStats(ctx, payload, owner, role, relayed)
  local denied = authorize(role, "pvp_publish")
  if denied then
    return false, denied
  end
  if relayed then
    local held = ctx.pvpStats[owner]
    local constants = ns.Constants
    if held and type(held.rev) == "number" then
      if payload.rev > held.rev + constants.PVP_SNAPSHOT_REV_JUMP_MAX then
        return false, "implausible"
      end
    elseif payload.rev > constants.PVP_SNAPSHOT_REV_NEW_MAX then
      return false, "implausible"
    end
  end

  local floor = ctx.pvpResets[owner]
  if floor and payload.rev <= floor.rev then
    return false, "reset"
  end

  local current = ctx.pvpStats[owner]
  local updatedAt = clampTimestamp(ctx, payload.updatedAt)
  if current then
    local held = { rev = current.rev, updatedAt = current.updatedAt, updatedBy = owner }
    if not Rules.Wins(payload.rev, updatedAt, owner, held) then
      return false, "stale"
    end
  end
  if not plausible(payload, current, updatedAt) then
    return false, "implausible"
  end

  makeRoom(ctx, owner)
  ctx.pvpStats[owner] = {
    honor = copyPair(payload.honor),
    -- A client without the combat log sends no killing blows: what was known stays.
    blows = payload.blows and copyPair(payload.blows) or (current and current.blows) or nil,
    today = {
      day = payload.today.day,
      honor = copyPair(payload.today.honor),
      blows = payload.today.blows and copyPair(payload.today.blows) or nil,
    },
    rev = payload.rev,
    updatedAt = updatedAt,
    receivedAt = ctx.now(),
  }
  return true
end

local function applyReset(ctx, payload, _, role)
  local denied = authorize(role, "moderate")
  if denied then
    return false, denied
  end

  local target = payload.target
  local floor = ctx.pvpResets[target]
  if floor and floor.rev >= payload.rev then
    return false, "stale"
  end
  if not floor and countKeys(ctx.pvpResets) >= ns.Constants.GUILD_ROSTER_MAX then
    return false, "limit"
  end
  ctx.pvpResets[target] = { rev = payload.rev }

  -- Zeroed rather than removed, so the next record has to start from nothing at a believable pace.
  local record = ctx.pvpStats[target]
  if record then
    local day = record.today and record.today.day or "2000-01-01"
    ctx.pvpStats[target] = {
      honor = { world = 0, bg = 0 },
      today = { day = day, honor = { world = 0, bg = 0 } },
      rev = payload.rev,
      updatedAt = ctx.now(),
      receivedAt = ctx.now(),
    }
  end
  if ctx.ownKey and ctx.onOwnReset and target == ctx.ownKey() then
    ctx.onOwnReset(payload.rev)
  end
  return true
end

local APPLIERS = { PVP_STATS = applyStats, PVP_RESET = applyReset }

function PvPSync.IsPvPMessage(messageType)
  return APPLIERS[messageType] ~= nil
end

-- `message` must already be validated by Protocol. `owner` is the sender of a guild message; for an item of a
-- snapshot it is the owner named in the item (see Transfer.ApplyItems), and `relayed` is true. `role` is the
-- sender's, from the roster.
function PvPSync.Apply(ctx, message, owner, role, relayed)
  local applier = APPLIERS[message.t]
  if not applier then
    return false, "unsupported"
  end
  return applier(ctx, message.p, owner, role, relayed)
end

-- The revision a reset of `target` needs to beat everything this client has seen of them.
function PvPSync.NextResetRev(ctx, target)
  local current = ctx.pvpStats[target]
  local floor = ctx.pvpResets[target]
  return math.max(current and current.rev or 0, floor and floor.rev or 0) + 1
end

-- Payload builders: what a local change looks like on the wire.

-- The own counters (`stats` as kept by PvPService) for day `day`. `blowsAvailable` = false leaves the killing
-- blows out.
function PvPSync.OwnPayload(stats, rev, updatedAt, day, blowsAvailable)
  local totals = ns.PvPService.Totals(stats)
  local today = ns.PvPService.Today(stats, day)
  local payload = {
    rev = rev,
    updatedAt = updatedAt,
    honor = copyPair(totals.honor),
    today = { day = day, honor = copyPair(today.honor) },
  }
  if blowsAvailable then
    payload.blows = copyPair(totals.blows)
    payload.today.blows = copyPair(today.blows)
  end
  return payload
end

-- The payload of a stored record (the shape of a PVP_STATS message), or nil when the record is not one.
local function recordPayload(record)
  if type(record) ~= "table" then
    return nil
  end
  local message = ns.Protocol.Validate(ns.Protocol.Build("PVP_STATS", record, "snapshot"))
  return message and message.p or nil
end

local function newestFirst(list, field, tieField)
  table.sort(list, function(a, b)
    if a[field] ~= b[field] then
      return a[field] > b[field]
    end
    return a[tieField] < b[tieField]
  end)
  return list
end

-- Items for a snapshot ({ t, p, owner } for a record, { t, p } for a reset): the `max` highest resets, then the
-- `max` most recently updated records. Records that do not validate are left out.
function PvPSync.SnapshotItems(ctx, max)
  local resets = {}
  for target, floor in pairs(ctx.pvpResets) do
    if type(floor) == "table" and type(floor.rev) == "number" then
      resets[#resets + 1] = { target = target, rev = floor.rev }
    end
  end
  newestFirst(resets, "rev", "target")

  local records = {}
  for owner, record in pairs(ctx.pvpStats) do
    if type(record) == "table" and type(record.updatedAt) == "number" then
      records[#records + 1] = { owner = owner, updatedAt = record.updatedAt, record = record }
    end
  end
  newestFirst(records, "updatedAt", "owner")

  local items = {}
  for index = 1, math.min(max, #resets) do
    items[#items + 1] = { t = "PVP_RESET", p = { target = resets[index].target, rev = resets[index].rev } }
  end
  local added = 0
  for _, entry in ipairs(records) do
    if added >= max then
      break
    end
    local payload = recordPayload(entry.record)
    if payload and ns.EventModel.IsCharacterKey(entry.owner) then
      items[#items + 1] = { t = "PVP_STATS", p = payload, owner = entry.owner }
      added = added + 1
    end
  end
  return items
end

ns.PvPSync = PvPSync
