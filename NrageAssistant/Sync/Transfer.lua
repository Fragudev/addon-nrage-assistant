local _, ns = ...

-- Text import/export of raid data, to share it outside the addon channel (Discord, a file...).
-- The text is "NRAGE1:" followed by LibSerialize -> LibDeflate -> print encoding of a list of the same
-- messages the sync uses (EVENT_UPSERT, ATTENDANCE_UPSERT, ASSIGN_UPSERT, DELETE). Import therefore
-- reuses their validation, role check and conflict rules: pasted text is hostile input like any other.
-- `libs` = { serialize = LibSerialize, deflate = LibDeflate }.
local Transfer = {}

local L = ns.L

local HEADER = "NRAGE1:"

local function sortedKeys(tbl)
  local keys = {}
  for key in pairs(tbl) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

-- Every live record and every tombstone, in a deterministic order (events first, deletes last).
function Transfer.BuildItems(events, tombstones)
  local items = {}
  local function add(messageType, payload)
    items[#items + 1] = { t = messageType, p = payload }
  end

  for _, eventId in ipairs(sortedKeys(events)) do
    local event = events[eventId]
    add("EVENT_UPSERT", ns.EventSync.EventPayload(event))
    for _, key in ipairs(sortedKeys(event.attendance)) do
      add("ATTENDANCE_UPSERT", ns.EventSync.AttendancePayload(eventId, key, event.attendance[key]))
    end
    for _, key in ipairs(sortedKeys(event.signups or {})) do
      add("SIGNUP_UPSERT", ns.EventSync.SignupPayload(eventId, key, event.signups[key]))
    end
    for _, assignmentId in ipairs(sortedKeys(event.assignments)) do
      add("ASSIGN_UPSERT", ns.EventSync.AssignPayload(eventId, event.assignments[assignmentId]))
    end
    -- Sessions and awards only: candidates and votes cannot be re-attributed to another sender.
    for _, item in ipairs(ns.LootSync.SessionItems(eventId, event)) do
      add(item.t, item.p)
      items[#items].awardedBy = item.awardedBy
    end
  end

  for _, key in ipairs(sortedKeys(tombstones)) do
    local eventId = key:match("^E:([^:]+)$")
    if eventId then
      add("DELETE", { kind = "event", eventId = eventId, rev = tombstones[key].rev })
    else
      local owner, assignmentId = key:match("^A:([^:]+):([^:]+)$")
      if owner then
        add("DELETE", {
          kind = "assignment",
          eventId = owner,
          assignmentId = assignmentId,
          rev = tombstones[key].rev,
        })
      end
    end
  end
  return items
end

-- Returns the text, or nil plus "encode_failed".
function Transfer.Export(libs, events, tombstones)
  local ok, encoded = pcall(function()
    local serialized = libs.serialize:Serialize({ items = Transfer.BuildItems(events, tombstones) })
    return libs.deflate:EncodeForPrint(libs.deflate:CompressDeflate(serialized))
  end)
  if not ok or type(encoded) ~= "string" then
    return nil, "encode_failed"
  end
  return HEADER .. encoded
end

-- Returns the decoded list of { t, p } items, or nil plus
-- "not_string" | "bad_header" | "too_large" | "bad_encoding" | "bad_compression" | "bad_payload".
function Transfer.Decode(libs, text)
  local constants = ns.Constants
  if type(text) ~= "string" then
    return nil, "not_string"
  end
  text = text:match("^%s*(.-)%s*$")
  if text:sub(1, #HEADER) ~= HEADER then
    return nil, "bad_header"
  end
  if #text > constants.IMPORT_MAX_ENCODED_BYTES then
    return nil, "too_large"
  end

  local ok, decoded = pcall(libs.deflate.DecodeForPrint, libs.deflate, text:sub(#HEADER + 1))
  if not ok or type(decoded) ~= "string" then
    return nil, "bad_encoding"
  end

  local decompressed
  ok, decompressed = pcall(libs.deflate.DecompressDeflate, libs.deflate, decoded)
  if not ok or type(decompressed) ~= "string" then
    return nil, "bad_compression"
  end
  if #decompressed > constants.IMPORT_MAX_DECOMPRESSED_BYTES then
    return nil, "too_large"
  end

  local success, value
  ok, success, value = pcall(libs.serialize.Deserialize, libs.serialize, decompressed)
  if not ok or not success or type(value) ~= "table" or type(value.items) ~= "table" then
    return nil, "bad_payload"
  end
  if #value.items > constants.IMPORT_MAX_ITEMS then
    return nil, "too_large"
  end
  return value.items
end

-- The most recent `maxEvents` events (by start time, else last edit), each with its attendance and
-- assignments, plus every tombstone. Used for the snapshot answered to a late joiner. `pvp` (optional) is a PvP
-- context (see PvPSync) and `maxPvP` how many of its records and resets to add: the PvP items are appended
-- after the raid ones and carry the owner of each record, which only a snapshot may do. The text export never
-- includes them (BuildItems is used for it). `blacklist` (optional) is the blacklist table and `maxBlacklist` how
-- many of its entries and of its removals ("B:" tombstones) to add, after the PvP items; its entries carry their
-- author, as an item of a snapshot may. The text export leaves the blacklist out as well. `readinessRules`
-- (optional) is the table of stored rule sets by roster; it needs `rosters` too, `maxRules` (default: all) limits how
-- many sets go, and the items go last: they only count at the receiver when whoever sends the snapshot is a gm or
-- cogm (see ReadinessRulesSync).
-- `rosters` (optional) is a RosterSync context ({ rosters, members, tombstones, now }) and `maxMembers` how many member
-- assignments and removals to add; like the rules they are only worth carrying from an admin.
-- `guildKos` (optional) is the guild Kill On Sight table and `maxGuildKos` how many of its entries and of its removals
-- ("K:" tombstones) to add, last; its entries carry their author like the blacklist ones. The text export leaves
-- them out too. `announcements` (optional) is the announcements store, `maxAnnouncements` how many of its live
-- announcements and removals to add (after everything else) and `now` the server time that decides which have
-- expired; like the rules they are only worth carrying from a gm or cogm (see AnnouncementSync).
function Transfer.BuildSnapshot(
  events,
  tombstones,
  maxEvents,
  pvp,
  maxPvP,
  blacklist,
  maxBlacklist,
  readinessRules,
  rosters,
  maxMembers,
  maxRules,
  guildKos,
  maxGuildKos,
  announcements,
  maxAnnouncements,
  now
)
  local list = {}
  for _, event in pairs(events) do
    list[#list + 1] = event
  end
  table.sort(list, function(a, b)
    local left, right = a.startAt or a.updatedAt or 0, b.startAt or b.updatedAt or 0
    if left ~= right then
      return left > right
    end
    return a.eventId < b.eventId
  end)

  local recent = {}
  for index = 1, math.min(maxEvents, #list) do
    recent[list[index].eventId] = list[index]
  end
  local items = Transfer.BuildItems(recent, tombstones)
  if pvp and maxPvP and maxPvP > 0 then
    for _, item in ipairs(ns.PvPSync.SnapshotItems(pvp, maxPvP)) do
      items[#items + 1] = item
    end
  end
  if blacklist and maxBlacklist and maxBlacklist > 0 then
    for _, item in ipairs(ns.BlacklistSync.SnapshotItems(blacklist, tombstones, maxBlacklist)) do
      items[#items + 1] = item
    end
  end
  if rosters and maxMembers and maxMembers > 0 then
    for _, item in ipairs(ns.RosterSync.SnapshotItems(rosters, maxMembers)) do
      items[#items + 1] = item
    end
  end
  -- The rules of the rosters go after the rosters themselves, so a receiver knows each roster by then.
  if readinessRules and rosters and maxRules ~= 0 then
    for index, item in ipairs(ns.ReadinessRulesSync.SnapshotItems(readinessRules, rosters.rosters)) do
      if maxRules and index > maxRules then
        break
      end
      items[#items + 1] = item
    end
  end
  if guildKos and maxGuildKos and maxGuildKos > 0 then
    for _, item in ipairs(ns.GuildKosSync.SnapshotItems(guildKos, tombstones, maxGuildKos)) do
      items[#items + 1] = item
    end
  end
  if announcements and maxAnnouncements and maxAnnouncements > 0 and now then
    for _, item in ipairs(ns.AnnouncementSync.SnapshotItems(announcements, now, maxAnnouncements)) do
      items[#items + 1] = item
    end
  end
  return items
end

-- A PvP item of a snapshot, applied as if its owner had sent it (a reset is applied under the role of the
-- sender of the snapshot, so it only counts when that is an admin). Only a snapshot names an owner.
local function applyPvPItem(item, ctx, sender, role)
  local owner = sender
  local relayed = false
  if item.t == "PVP_STATS" then
    if not ns.EventModel.IsCharacterKey(item.owner) then
      return false, "bad_owner"
    end
    -- The owner has to be somebody this client's own guild roster knows: a relay cannot invent members.
    if not ctx.roleOf or ctx.roleOf(item.owner) == nil then
      return false, "unknown_owner"
    end
    owner = item.owner
    relayed = true
  end
  local message, invalid = ns.Protocol.Validate(ns.Protocol.Build(item.t, item.p, "import"))
  if not message then
    return false, invalid
  end
  return ns.PvPSync.Apply(ctx, message, owner, role, relayed)
end

-- The original awarder of a LOOT_AWARD item, when it can be trusted: a character key that this client's own guild
-- roster knows as somebody who manages loot. Nil otherwise (a text import never has a roster), and the sender stays
-- the awarder.
local function relayedAwarder(item, ctx)
  local by = item.awardedBy
  if type(by) ~= "string" or not ctx.roleOf or not ns.EventModel.IsCharacterKey(by) then
    return nil
  end
  local role = ctx.roleOf(by)
  if role ~= nil and ns.PermissionService.Can(role, "loot_manage") then
    return by
  end
  return nil
end

-- A blacklist item of a snapshot, applied as if its sender had sent it. The author and date it carries are only
-- read here, from the snapshot of a leader.
local function applyBlacklistItem(item, ctx, sender, role)
  local message, invalid = ns.Protocol.Validate(ns.Protocol.Build(item.t, item.p, "import"))
  if not message then
    return false, invalid
  end
  local origin
  if item.t == "BLACKLIST_UPSERT" and (item.addedBy ~= nil or item.addedAt ~= nil) then
    origin = { addedBy = item.addedBy, addedAt = item.addedAt }
  end
  return ns.BlacklistSync.Apply(ctx, message, sender, role, origin)
end

-- A guild Kill On Sight item of a snapshot, applied like a blacklist one: the author and date it carries are only read
-- here, from the snapshot of a leader.
local function applyGuildKosItem(item, ctx, sender, role)
  local message, invalid = ns.Protocol.Validate(ns.Protocol.Build(item.t, item.p, "import"))
  if not message then
    return false, invalid
  end
  local origin
  if item.t == "KOS_UPSERT" and (item.addedBy ~= nil or item.addedAt ~= nil) then
    origin = { addedBy = item.addedBy, addedAt = item.addedAt }
  end
  return ns.GuildKosSync.Apply(ctx, message, sender, role, origin)
end

-- An announcement item of a snapshot, applied as if the sender had sent it (so only a gm or cogm counts). The author
-- it names is believed only when this client's own guild roster says that member may manage announcements too;
-- otherwise the sender stays the author.
local function applyAnnouncementItem(item, ctx, sender, role)
  local message, invalid = ns.Protocol.Validate(ns.Protocol.Build(item.t, item.p, "import"))
  if not message then
    return false, invalid
  end
  local origin
  if item.t == "ANN" and type(item.author) == "string" and ns.EventModel.IsCharacterKey(item.author) then
    local authorRole = ctx.roleOf and ctx.roleOf(item.author)
    if authorRole ~= nil and ns.PermissionService.Can(authorRole, "announce_manage") then
      origin = { author = item.author }
    end
  end
  return ns.AnnouncementSync.Apply({
    store = ctx.announcements,
    now = ctx.now,
    onApplied = ctx.onAnnouncement,
  }, message, sender, role, origin)
end

-- A roster or member item of a snapshot, applied as if the sender had sent it (so only an admin's counts).
local function applyRosterItem(item, ctx, sender, role)
  local message, invalid = ns.Protocol.Validate(ns.Protocol.Build(item.t, item.p, "import"))
  if not message then
    return false, invalid
  end
  local ok, why = ns.RosterSync.Apply(
    { rosters = ctx.rosters, members = ctx.members, tombstones = ctx.tombstones, now = ctx.now },
    message,
    sender,
    role
  )
  if ok and item.t == "ROSTER_DELETE" and ctx.readinessRules then
    ns.ReadinessRulesSync.Forget(ctx.readinessRules, message.p.rosterId)
  end
  return ok, why
end

-- The readiness rules of a snapshot, applied as if the sender had sent them.
local function applyRulesItem(item, ctx, sender, role)
  local message, invalid = ns.Protocol.Validate(ns.Protocol.Build(item.t, item.p, "import"))
  if not message then
    return false, invalid
  end
  return ns.ReadinessRulesSync.Apply({
    records = ctx.readinessRules,
    rosters = ctx.rosters,
    members = ctx.members,
    tombstones = ctx.tombstones,
    now = ctx.now,
  }, message, sender, role)
end

-- Applies a list of { t, p } items as if `sender` had sent each one: every item goes through the
-- protocol validation, the role check for `role` and the conflict rules. `ctx` = { events, tombstones,
-- now } as for EventSync; PvP items are only applied when `ctx.pvpStats` is there (see PvPSync) and blacklist items
-- when `ctx.blacklist` is (see BlacklistSync), which a text import never provides; guild Kill On Sight items when
-- `ctx.guildKos` is (see GuildKosSync); the readiness rules likewise when `ctx.readinessRules` is there. Returns
-- { total, applied, pvp (how many of those were PvP), blacklist (how many were blacklist), guildKos (how many were
-- guild Kill On Sight), rules (how many roster rule sets were applied), announcements (how many were announcements,
-- applied when `ctx.announcements` is there; `ctx.onAnnouncement(announcement)` hears each stored one), skipped =
-- { [reason] = count }, firstError (the first error an item raised, if any) }.
function Transfer.ApplyItems(items, ctx, sender, role)
  local summary = {
    total = #items,
    applied = 0,
    pvp = 0,
    blacklist = 0,
    guildKos = 0,
    rules = 0,
    rosters = 0,
    announcements = 0,
    skipped = {},
  }
  local function skip(why)
    summary.skipped[why] = (summary.skipped[why] or 0) + 1
  end

  local function applyOne(item)
    if type(item) == "table" and type(item.t) == "string" and ctx.pvpStats and ns.PvPSync.IsPvPMessage(item.t) then
      local ok, why = applyPvPItem(item, ctx, sender, role)
      if ok then
        summary.applied = summary.applied + 1
        summary.pvp = summary.pvp + 1
      else
        skip(why)
      end
    elseif
      type(item) == "table"
      and type(item.t) == "string"
      and ctx.blacklist
      and ns.BlacklistSync.IsBlacklistMessage(item.t)
    then
      local ok, why = applyBlacklistItem(item, ctx, sender, role)
      if ok then
        summary.applied = summary.applied + 1
        summary.blacklist = summary.blacklist + 1
      else
        skip(why)
      end
    elseif
      type(item) == "table"
      and type(item.t) == "string"
      and ctx.guildKos
      and ns.GuildKosSync.IsGuildKosMessage(item.t)
    then
      local ok, why = applyGuildKosItem(item, ctx, sender, role)
      if ok then
        summary.applied = summary.applied + 1
        summary.guildKos = summary.guildKos + 1
      else
        skip(why)
      end
    elseif
      type(item) == "table"
      and type(item.t) == "string"
      and ctx.readinessRules
      and ns.ReadinessRulesSync.IsRulesMessage(item.t)
    then
      local ok, why = applyRulesItem(item, ctx, sender, role)
      if ok then
        summary.applied = summary.applied + 1
        summary.rules = summary.rules + 1
      else
        skip(why)
      end
    elseif
      type(item) == "table"
      and type(item.t) == "string"
      and ctx.announcements
      and ns.AnnouncementSync.IsAnnouncementMessage(item.t)
    then
      local ok, why = applyAnnouncementItem(item, ctx, sender, role)
      if ok then
        summary.applied = summary.applied + 1
        summary.announcements = summary.announcements + 1
      else
        skip(why)
      end
    elseif
      type(item) == "table"
      and type(item.t) == "string"
      and ctx.rosters
      and ctx.members
      and ns.RosterSync.IsRosterMessage(item.t)
    then
      local ok, why = applyRosterItem(item, ctx, sender, role)
      if ok then
        summary.applied = summary.applied + 1
        summary.rosters = summary.rosters + 1
      else
        skip(why)
      end
    elseif type(item) ~= "table" or type(item.t) ~= "string" or not ns.EventSync.IsRaidMessage(item.t) then
      skip("unsupported")
    else
      local message, invalid = ns.Protocol.Validate(ns.Protocol.Build(item.t, item.p, "import"))
      if not message then
        skip(invalid)
      else
        -- A sign-up in a snapshot is relayed by a leader; see EventSync's applySignupUpsert. An award keeps its
        -- original awarder; see LootSync's applyAward.
        local applyCtx = ctx
        if item.t == "SIGNUP_UPSERT" then
          applyCtx = setmetatable({ relay = true }, { __index = ctx })
        elseif item.t == "LOOT_AWARD" then
          applyCtx = setmetatable({ awardedBy = relayedAwarder(item, ctx) }, { __index = ctx })
        end
        local ok, why = ns.EventSync.Apply(applyCtx, message, sender, role)
        if ok then
          summary.applied = summary.applied + 1
        else
          skip(why)
        end
      end
    end
  end

  -- An item that raises is skipped (and counted) instead of aborting the rest of the snapshot; the first error is kept
  -- for the debug output.
  for _, item in ipairs(items) do
    local ok, err = pcall(applyOne, item)
    if not ok then
      skip("error")
      summary.firstError = summary.firstError or tostring(err)
    end
  end
  return summary
end

-- Applies pasted text. `role` is the importer's own role: importing needs the same right as
-- creating events. Returns the ApplyItems summary, or nil plus a Decode reason or "forbidden".
function Transfer.Import(libs, text, ctx, role)
  if not ns.PermissionService.Can(role, "raid_manage") then
    return nil, "forbidden"
  end
  local items, reason = Transfer.Decode(libs, text)
  if not items then
    return nil, reason
  end
  return Transfer.ApplyItems(items, ctx, "import", role)
end

-- One line describing an import summary.
function Transfer.Describe(summary)
  local parts = {}
  for _, why in ipairs(sortedKeys(summary.skipped)) do
    parts[#parts + 1] = ("%s: %d"):format(why, summary.skipped[why])
  end
  local text = L("imported %d of %d record(s)"):format(summary.applied, summary.total)
  if #parts > 0 then
    text = text .. L(" (skipped - %s)"):format(table.concat(parts, ", "))
  end
  return text
end

ns.Transfer = Transfer
