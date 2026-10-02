local _, ns = ...

-- The operations the Blacklist tab calls. Each method returns the lines to show, so the whole thing is testable
-- without a client. A change is applied locally through
-- BlacklistService (which checks the rank-derived role) and then sent to the guild through Comm.
--   deps: blacklist, tombstones, platform, comm, onChange (optional, called after a change made here)
local BlacklistCommands = {}
BlacklistCommands.__index = BlacklistCommands

local L = ns.L

function BlacklistCommands.New(deps)
  return setmetatable({
    blacklist = deps.blacklist,
    tombstones = deps.tombstones,
    platform = deps.platform,
    comm = deps.comm,
    onChange = deps.onChange,
  }, BlacklistCommands)
end

function BlacklistCommands:Context()
  local platform = self.platform
  return {
    blacklist = self.blacklist,
    tombstones = self.tombstones,
    role = ns.PermissionService.OwnRole(platform),
    actor = platform.GetIdentityKey(),
    now = platform.ServerTime,
  }
end

local ERRORS = {
  empty_name = L("enter the name of the player."),
  long_name = L("the name is too long."),
  bad_name = L("that is not a valid name."),
  empty_reason = L("enter a reason."),
  long_reason = L("the reason is too long (up to 100 characters)."),
  bad_reason = L("the reason cannot contain | or control characters."),
  not_author = L(
    "that player is already on the blacklist; only the member who added them or an officer can change the reason."
  ),
  limit = L("the blacklist is full."),
  not_found = L("that player is not on the blacklist."),
}

local function fail(ctx, reason, action)
  if reason == "forbidden" then
    if action == "remove" then
      return L("not allowed: only the guild master and officers can remove a player from the blacklist.")
    end
    return L("not allowed: your guild rank gives the role '%s', which cannot do this."):format(tostring(ctx.role))
  end
  return ERRORS[reason] or tostring(reason)
end

-- Adds a note when the change was saved here but could not be queued for the guild.
local function sentNote(ok, reason)
  if ok then
    return nil
  end
  return L("saved here, but not sent to the guild (%s)."):format(tostring(reason))
end

function BlacklistCommands:Changed()
  if self.onChange then
    self.onChange()
  end
end

function BlacklistCommands:Add(name, reason)
  local ctx = self:Context()
  local entry, key, updated = ns.BlacklistService.Add(ctx, name, reason)
  if not entry then
    return { fail(ctx, key, "add") }
  end
  self:Changed()
  return {
    (updated and L("changed the reason of %s on the blacklist.") or L("added %s to the blacklist.")):format(
      ns.ViewModel.Escape(entry.name)
    ),
    sentNote(self.comm:SendBlacklistUpsert(key, entry)),
  }
end

-- `name` is the player as typed (a realm suffix is fine).
function BlacklistCommands:Remove(name)
  local ctx = self:Context()
  local entry, key = ns.BlacklistService.Find(self.blacklist, name)
  -- The role is checked first, so a member is told they may not rather than that the player is not listed.
  if not ns.PermissionService.Can(ctx.role, "blacklist_remove") then
    return { fail(ctx, "forbidden", "remove") }
  end
  if not entry then
    return { fail(ctx, "not_found", "remove") }
  end
  local ok, reason = ns.BlacklistService.Remove(ctx, key)
  if not ok then
    return { fail(ctx, reason, "remove") }
  end
  self:Changed()
  return {
    L("removed %s from the blacklist."):format(ns.ViewModel.Escape(entry.name)),
    sentNote(self.comm:SendBlacklistDelete(key)),
  }
end

ns.BlacklistCommands = BlacklistCommands
