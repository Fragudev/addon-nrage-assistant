local _, ns = ...

-- Raid rosters (teams) and the assignment of members to them (plan 3.4.1). Pure logic over plain tables, no client
-- API, so it is tested without a client.
--   rosters[id]   = { id, name, rev, updatedAt, updatedBy }
--   members[key]  = { rosterId = id or nil, rev, updatedAt, updatedBy }
-- The addon role of a player is their guild rank (PermissionService), never stored here: an old `role` field in a
-- record is kept as it is but nothing reads it.
-- `key` is the character name exactly as the guild roster writes it. A member belongs to at most one roster.
-- Removals leave tombstones "R:<id>" and "M:<key>" in the shared tombstones, so an older copy arriving later cannot
-- bring a removed roster or assignment back.
--
-- This is a VISIBILITY filter in the interface, not access control: raid data still travels over the guild addon
-- channel and every member with the addon receives all of it (docs/PRIVACY.md). What the receivers do enforce is
-- who may change what: only the guild master and the co-guild master change rosters and assignments (until the later
-- phases of docs/NAV_PERMISSIONS_PLAN.md let a raid leader assign to their own roster), and every other rank only acts
-- on the events of their own roster (MayAct).
--
-- ctx = { rosters, members, tombstones, role, actor, now = function(), newId = function() }
local RosterService = {}

-- Rosters and assignments are the guild master's and the co-guild master's. An rl or officer would pass Can at
-- their own scope, but the roster scoping arrives with phase 5 of docs/NAV_PERMISSIONS_PLAN.md, so until then only the
-- global ranks may change them.
local function canManage(role)
  return ns.PermissionService.CanAll(role, "members_manage")
end

local function countKeys(tbl)
  local count = 0
  for _ in pairs(tbl) do
    count = count + 1
  end
  return count
end

local function stamp(ctx, record)
  record.rev = (record.rev or 0) + 1
  record.updatedAt = ctx.now()
  record.updatedBy = ctx.actor
end

-- The revision a new record under `tombstoneKey` needs: 1, or one above the removal that is remembered.
local function nextRev(tombstones, tombstoneKey)
  local tombstone = tombstones[tombstoneKey]
  return tombstone and (tombstone.rev + 1) or 1
end

-- A member key as it may be stored: plain text, no ":" (it would break the tombstone key).
function RosterService.IsMemberKey(key)
  return ns.Validate.Text(key, 64) and not key:find(":", 1, true)
end

-- The clean roster name, or nil plus "invalid:name".
function RosterService.CleanName(name)
  if type(name) ~= "string" then
    return nil, "invalid:name"
  end
  name = name:gsub("%s+", " "):match("^%s*(.-)%s*$")
  if not ns.Validate.Text(name, ns.Constants.ROSTER_NAME_MAX) then
    return nil, "invalid:name"
  end
  return name
end

-- The rosters sorted by name (then id).
function RosterService.List(rosters)
  local list = {}
  for _, roster in pairs(rosters) do
    list[#list + 1] = roster
  end
  table.sort(list, function(a, b)
    local left, right = a.name:lower(), b.name:lower()
    if left ~= right then
      return left < right
    end
    return a.id < b.id
  end)
  return list
end

function RosterService.NameOf(rosters, id)
  local roster = id and rosters[id]
  return roster and roster.name or nil
end

-- The roster a member belongs to, or nil: no assignment, no roster, or a roster that was deleted.
function RosterService.RosterOf(members, rosters, key)
  local record = key and members[key]
  if type(record) == "table" and record.rosterId and rosters[record.rosterId] then
    return record.rosterId
  end
  return nil
end

local function nameTaken(rosters, name, exceptId)
  for id, roster in pairs(rosters) do
    if id ~= exceptId and roster.name:lower() == name:lower() then
      return true
    end
  end
  return false
end

-- Creates a roster. Returns it, or nil plus "forbidden" | "invalid:name" | "duplicate" | "limit".
function RosterService.Create(ctx, name)
  if not canManage(ctx.role) then
    return nil, "forbidden"
  end
  local clean, reason = RosterService.CleanName(name)
  if not clean then
    return nil, reason
  end
  if nameTaken(ctx.rosters, clean) then
    return nil, "duplicate"
  end
  if countKeys(ctx.rosters) >= ns.Constants.ROSTERS_MAX then
    return nil, "limit"
  end
  local roster = { id = ctx.newId(), name = clean }
  roster.rev = nextRev(ctx.tombstones, "R:" .. roster.id) - 1
  stamp(ctx, roster)
  ctx.rosters[roster.id] = roster
  return roster
end

-- Renames a roster. Returns it, or nil plus "forbidden" | "not_found" | "invalid:name" | "duplicate".
function RosterService.Rename(ctx, id, name)
  if not canManage(ctx.role) then
    return nil, "forbidden"
  end
  local roster = ctx.rosters[id]
  if not roster then
    return nil, "not_found"
  end
  local clean, reason = RosterService.CleanName(name)
  if not clean then
    return nil, reason
  end
  if nameTaken(ctx.rosters, clean, id) then
    return nil, "duplicate"
  end
  roster.name = clean
  stamp(ctx, roster)
  return roster
end

-- Deletes a roster and leaves a tombstone. The members that were in it stay assigned to it, but a roster that does
-- not exist counts as no roster (RosterOf). Returns true, or false plus "forbidden" | "not_found".
function RosterService.Delete(ctx, id)
  if not canManage(ctx.role) then
    return false, "forbidden"
  end
  local roster = ctx.rosters[id]
  if not roster then
    return false, "not_found"
  end
  ctx.rosters[id] = nil
  ns.EventService.AddTombstone(ctx, "R:" .. id, roster.rev + 1)
  return true
end

-- Sets the roster of a member. `fields` = { rosterId = a roster id, or false to take the member out of every roster
-- (default: unchanged) }. One roster per member: assigning another roster moves them. The role of a member is their
-- guild rank, so it is not set here.
-- Returns the record, or nil plus "forbidden" | "invalid:key" | "invalid:roster" | "limit".
function RosterService.Assign(ctx, key, fields)
  if not canManage(ctx.role) then
    return nil, "forbidden"
  end
  if not RosterService.IsMemberKey(key) then
    return nil, "invalid:key"
  end
  local record = ctx.members[key]
  local rosterId = fields.rosterId
  if rosterId == nil then
    rosterId = record and record.rosterId or nil
  elseif rosterId == false then
    rosterId = nil
  elseif not ctx.rosters[rosterId] then
    return nil, "invalid:roster"
  end
  if not record and countKeys(ctx.members) >= ns.Constants.MEMBER_ASSIGNMENTS_MAX then
    return nil, "limit"
  end
  if not record then
    record = { rev = nextRev(ctx.tombstones, "M:" .. key) - 1 }
    ctx.members[key] = record
  end
  record.rosterId = rosterId
  stamp(ctx, record)
  return record
end

-- Takes the assignment of a member away (they have no roster again) and leaves a tombstone.
-- Returns true, or false plus "forbidden" | "not_found".
function RosterService.Unassign(ctx, key)
  if not canManage(ctx.role) then
    return false, "forbidden"
  end
  local record = ctx.members[key]
  if not record then
    return false, "not_found"
  end
  ctx.members[key] = nil
  ns.EventService.AddTombstone(ctx, "M:" .. key, record.rev + 1)
  return true
end

-- How many of `names` (the guild members) are in each roster, and how many in none: { [rosterId] = n, none = n }.
function RosterService.Counts(rosters, members, names)
  local counts = { none = 0 }
  for id in pairs(rosters) do
    counts[id] = 0
  end
  for _, name in ipairs(names) do
    local id = RosterService.RosterOf(members, rosters, name)
    if id then
      counts[id] = counts[id] + 1
    else
      counts.none = counts.none + 1
    end
  end
  return counts
end

-- Who sees which events (plan 3.4.1). `options` = { role, rosterId = the own roster (or nil), selected = what an admin
-- picked in the roster selector: a roster id, "all" or "none" (events with no roster) }.
-- Returns { mode = "all" | "roster" | "none" | "blocked", rosterId, legacy }:
--   admins: the selected roster (default their own, else all); "none" shows the events no roster owns;
--   everybody else: their own roster, plus the events no roster owns yet (legacy); with no roster: "blocked", which
--   shows nothing and means the UI says "you are not in a roster yet".
function RosterService.Viewer(options)
  if ns.PermissionService.IsGlobal(options.role) then
    local selected = options.selected or options.rosterId or "all"
    if selected == "all" then
      return { mode = "all", canSelect = true }
    elseif selected == "none" then
      return { mode = "none", legacy = true, canSelect = true }
    end
    return { mode = "roster", rosterId = selected, canSelect = true }
  end
  if options.rosterId then
    return { mode = "roster", rosterId = options.rosterId, legacy = true, canSelect = false }
  end
  return { mode = "blocked", canSelect = false }
end

-- The viewer of the player running this client. `selected` is the roster an admin picked in the selector, if any.
function RosterService.OwnViewer(platform, rosters, members, selected)
  local role = ns.PermissionService.OwnRole(platform)
  return RosterService.Viewer({
    role = role,
    rosterId = RosterService.RosterOf(members, rosters, platform.GetIdentityKey()),
    selected = selected,
  }),
    role
end

function RosterService.EventVisible(event, viewer)
  if viewer.mode == "all" then
    return true
  elseif viewer.mode == "blocked" then
    return false
  elseif viewer.mode == "none" then
    return event.rosterId == nil
  end
  return event.rosterId == viewer.rosterId or (viewer.legacy == true and event.rosterId == nil)
end

-- The events a viewer sees, as a table with the same keys.
function RosterService.FilterEvents(events, viewer)
  local visible = {}
  for id, event in pairs(events) do
    if RosterService.EventVisible(event, viewer) then
      visible[id] = event
    end
  end
  return visible
end

-- May somebody with `role` whose roster is `senderRosterId` act on an event of `eventRosterId`? (to change the event,
-- its attendance, assignments and loot, or to apply, vote and award there)
--   gm, cogm: always (any roster).
--   others:   they need a roster, and the event has to be of it, or of none yet. An event no roster owns (created
--             before rosters, or by a client that does not know them) is open to the players who have a roster until
--             the guild master gives it one.
-- The role check itself (is this role allowed to do the action at all) is PermissionService's.
function RosterService.MayAct(role, senderRosterId, eventRosterId)
  if ns.PermissionService.IsGlobal(role) then
    return true
  end
  if senderRosterId == nil then
    return false
  end
  return eventRosterId == nil or eventRosterId == senderRosterId
end

-- The roster of a sender at the receiver. `ctx.rosterOf(sender)` wins when there is one (an import answers with the
-- own roster); otherwise the assignments and rosters in the ctx are read.
function RosterService.SenderRoster(ctx, sender)
  if ctx.rosterOf then
    return ctx.rosterOf(sender)
  end
  if ctx.members and ctx.rosters then
    return RosterService.RosterOf(ctx.members, ctx.rosters, sender)
  end
  return nil
end

-- Templates (kept on this client) follow the roster of their event: `template.rosterId`. A template with no roster
-- is a legacy one. Which of them a viewer can use: their roster's and the legacy ones; an admin sees the selected
-- roster's, or all.
function RosterService.TemplateVisible(template, viewer)
  if viewer.mode == "all" then
    return true
  elseif viewer.mode == "blocked" then
    return false
  elseif viewer.mode == "none" then
    return template.rosterId == nil
  end
  return template.rosterId == viewer.rosterId or template.rosterId == nil
end

ns.RosterService = RosterService
