local _, ns = ...

-- Text commands for the guild blacklist, and the operations the Blacklist tab calls. Each method returns the
-- lines to print, so the whole thing is testable without a client. A change is applied locally through
-- BlacklistService (which checks the rank-derived role) and then sent to the guild through Comm.
--   deps: blacklist, tombstones, platform, comm, onChange (optional, called after a change made here)
local BlacklistCommands = {}
BlacklistCommands.__index = BlacklistCommands

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
  empty_name = "enter the name of the player.",
  long_name = "the name is too long.",
  bad_name = "that is not a valid name.",
  empty_reason = "enter a reason.",
  long_reason = "the reason is too long (up to 100 characters).",
  bad_reason = "the reason cannot contain | or control characters.",
  exists = "that player is already on the blacklist.",
  limit = "the blacklist is full.",
  not_found = "that player is not on the blacklist.",
}

local function fail(ctx, reason, action)
  if reason == "forbidden" then
    if action == "remove" then
      return "not allowed: only the guild master and officers can remove a player from the blacklist."
    end
    return ("not allowed: your guild rank gives the role '%s', which cannot do this."):format(tostring(ctx.role))
  end
  return ERRORS[reason] or tostring(reason)
end

-- Adds a note when the change was saved here but could not be queued for the guild.
local function sentNote(ok, reason)
  if ok then
    return nil
  end
  return ("saved here, but not sent to the guild (%s)."):format(tostring(reason))
end

function BlacklistCommands:Changed()
  if self.onChange then
    self.onChange()
  end
end

function BlacklistCommands:List()
  local entries = self.blacklist
  local rows = ns.ViewModel.BlacklistRows(entries, {
    formatDate = self.platform.FormatDate,
  })
  if #rows == 0 then
    return { "The blacklist is empty. Add a player with /nrage blacklist add <name> | <reason>." }
  end
  local lines = { ("%d player(s) on the blacklist:"):format(#rows) }
  for _, row in ipairs(rows) do
    lines[#lines + 1] = ("  %s - %s (added by %s, %s)"):format(row.name, row.reason, row.addedBy, row.added)
  end
  return lines
end

function BlacklistCommands:Add(name, reason)
  local ctx = self:Context()
  local entry, key = ns.BlacklistService.Add(ctx, name, reason)
  if not entry then
    return { fail(ctx, key, "add") }
  end
  self:Changed()
  return {
    ("added %s to the blacklist."):format(ns.ViewModel.Escape(entry.name)),
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
    ("removed %s from the blacklist."):format(ns.ViewModel.Escape(entry.name)),
    sentNote(self.comm:SendBlacklistDelete(key)),
  }
end

local USAGE = "usage: /nrage blacklist | blacklist add <name> | <reason> | blacklist remove <name> (admin only)"

-- The text after "/nrage blacklist".
function BlacklistCommands:Blacklist(rest)
  local sub, args = rest:match("^(%S*)%s*(.-)$")
  if sub == "" or sub == "list" then
    return self:List()
  elseif sub == "add" then
    local name, reason = args:match("^(.-)%s*|%s*(.*)$")
    if not name then
      return { USAGE }
    end
    return self:Add(ns.Args.Unquote(name), reason)
  elseif sub == "remove" and args ~= "" then
    return self:Remove(ns.Args.Unquote(args))
  end
  return { USAGE }
end

ns.BlacklistCommands = BlacklistCommands
