local _, ns = ...

-- Who may do what (plan section 12). Roles come from the guild rank, read from the receiver's own
-- guild roster: a message never gets to say what its sender is allowed to do.
-- Council/loot actions arrive with phase 3.
local PermissionService = {}

local ACTIONS = {
  view = { member = true, rl = true, admin = true },
  edit_own_profile = { member = true, rl = true, admin = true },
  manage_events = { rl = true, admin = true },
  record_attendance = { rl = true, admin = true },
  manage_assignments = { rl = true, admin = true },
  moderate = { admin = true },
}

-- Maps a rank name to a role using `mapping` (default: Constants.RANK_ROLES). Unlisted ranks are
-- plain members; a missing rank name gives nil.
function PermissionService.RoleForRank(rankName, mapping)
  if type(rankName) ~= "string" or rankName == "" then
    return nil
  end
  mapping = mapping or ns.Constants.RANK_ROLES
  return mapping[rankName:lower()] or "member"
end

-- Role of `name` according to the local guild roster, or nil when the roster does not know them
-- (not in the guild, or the roster has not loaded yet). nil never grants anything.
function PermissionService.RoleOf(guildRoster, name, mapping)
  local entry = guildRoster:Lookup(name)
  if not entry then
    return nil
  end
  return PermissionService.RoleForRank(entry.rankName, mapping)
end

function PermissionService.OwnRole(platform, mapping)
  return PermissionService.RoleForRank(platform.GetOwnGuildRank(), mapping)
end

function PermissionService.Can(role, action)
  local allowed = ACTIONS[action]
  return allowed ~= nil and role ~= nil and allowed[role] == true
end

ns.PermissionService = PermissionService
