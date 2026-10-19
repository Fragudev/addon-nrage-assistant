local _, ns = ...

-- The operations the Members tab calls to manage rosters and the roles of members: only the guild master can. Each
-- method returns the lines to show, so the whole thing is testable without a client. A change is applied locally
-- through RosterService (which checks the role) and then sent to the guild through Comm.
--   deps: rosters, members, tombstones, platform, comm, onChange (optional, called after a change made here)
local RosterCommands = {}
RosterCommands.__index = RosterCommands

local L = ns.L
local Failure = ns.Validate.Failure

function RosterCommands.New(deps)
  return setmetatable({
    rosters = deps.rosters,
    members = deps.members,
    tombstones = deps.tombstones,
    platform = deps.platform,
    comm = deps.comm,
    onChange = deps.onChange,
  }, RosterCommands)
end

function RosterCommands:Context()
  local platform = self.platform
  return {
    rosters = self.rosters,
    members = self.members,
    tombstones = self.tombstones,
    role = ns.PermissionService.OwnRole(platform),
    actor = platform.GetIdentityKey(),
    now = platform.ServerTime,
    newId = function()
      return self.comm:NextId()
    end,
  }
end

local ERRORS = ns.Locale.Table(function()
  return {
    forbidden = L("only the guild master can manage rosters and roles."),
    ["invalid:name"] = L("give a plain-text roster name (up to 30 characters)."),
    ["invalid:key"] = L("that is not a valid member name."),
    ["invalid:role"] = L("a member can be assigned member, raid leader or loot council."),
    ["invalid:roster"] = L("that roster does not exist."),
    duplicate = L("there is a roster with that name already."),
    limit = L("limit reached."),
    not_found = L("not found."),
  }
end)

local function fail(reason)
  return ERRORS[reason] or tostring(reason)
end

-- Adds a note when the change was saved here but could not be queued for the guild.
local function sentNote(ok, reason)
  if ok then
    return nil
  end
  return L("saved here, but not sent to the guild (%s)."):format(tostring(reason))
end

function RosterCommands:Changed()
  if self.onChange then
    self.onChange()
  end
end

function RosterCommands:CreateRoster(name)
  local roster, reason = ns.RosterService.Create(self:Context(), name)
  if not roster then
    return Failure(fail(reason))
  end
  self:Changed()
  return { L("created the roster '%s'."):format(roster.name), sentNote(self.comm:SendRoster(roster)) }
end

function RosterCommands:RenameRoster(id, name)
  local roster, reason = ns.RosterService.Rename(self:Context(), id, name)
  if not roster then
    return Failure(fail(reason))
  end
  self:Changed()
  return { L("renamed the roster to '%s'."):format(roster.name), sentNote(self.comm:SendRoster(roster)) }
end

function RosterCommands:DeleteRoster(id)
  local roster = self.rosters[id]
  local ok, reason = ns.RosterService.Delete(self:Context(), id)
  if not ok then
    return Failure(fail(reason))
  end
  self:Changed()
  return { L("deleted the roster '%s'."):format(roster.name), sentNote(self.comm:SendDeleteRoster(id)) }
end

-- `fields` = { role, rosterId } as RosterService.Assign takes them (rosterId = false: no roster).
function RosterCommands:AssignMember(key, fields)
  local record, reason = ns.RosterService.Assign(self:Context(), key, fields)
  if not record then
    return Failure(fail(reason))
  end
  self:Changed()
  return { L("saved the role and roster of %s."):format(key), sentNote(self.comm:SendMember(key, record)) }
end

function RosterCommands:UnassignMember(key)
  local ok, reason = ns.RosterService.Unassign(self:Context(), key)
  if not ok then
    return Failure(fail(reason))
  end
  self:Changed()
  return { L("%s is a plain member with no roster again."):format(key), sentNote(self.comm:SendDeleteMember(key)) }
end

ns.RosterCommands = RosterCommands
