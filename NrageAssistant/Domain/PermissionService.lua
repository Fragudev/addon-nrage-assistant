local _, ns = ...

-- Who may do what (plan section 12). Roles come from the guild rank, read from the receiver's own
-- guild roster: a message never gets to say what its sender is allowed to do.
-- Roles: member, rl (raid leader), council (loot council) and admin. A raid leader does not get
-- loot rights by default (the plan marks that as optional); map a rank to "council" to grant them.
local PermissionService = {}

local ACTIONS = {
  view = { member = true, rl = true, council = true, admin = true },
  edit_own_profile = { member = true, rl = true, council = true, admin = true },
  manage_events = { rl = true, admin = true },
  record_attendance = { rl = true, admin = true },
  manage_assignments = { rl = true, admin = true },
  loot_apply = { member = true, rl = true, council = true, admin = true },
  loot_open = { council = true, admin = true },
  loot_vote = { council = true, admin = true },
  loot_award = { council = true, admin = true },
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

-- Lowercase, no spaces: "Some Name" and "somename" are the same name. Character names cannot
-- contain spaces in the game, so this only makes the configured list forgiving.
local function normalizeName(text)
  return (text:lower():gsub("%s+", ""))
end

-- BETA ONLY (tracked in issue #25): the characters listed in Constants.BETA_ADMIN_NAMES are treated as
-- admins, as if they were the guild master. `identityKey` is "Name" or "Name-Realm"; only the name
-- part is compared. Callers apply this only to someone who is really in the guild.
function PermissionService.IsBetaAdmin(identityKey)
  local constants = ns.Constants
  if not constants.BETA_ADMIN_ENABLED or type(identityKey) ~= "string" then
    return false
  end
  local name = identityKey:match("^([^%-]+)")
  if not name then
    return false
  end
  name = normalizeName(name)
  for _, admin in ipairs(constants.BETA_ADMIN_NAMES) do
    if normalizeName(admin) == name then
      return true
    end
  end
  return false
end

-- Role of `name` according to the local guild roster, or nil when the roster does not know them
-- (not in the guild, or the roster has not loaded yet). nil never grants anything, and neither
-- does the beta exception: it only applies to someone the roster knows.
function PermissionService.RoleOf(guildRoster, name, mapping)
  local entry = guildRoster:Lookup(name)
  if not entry then
    return nil
  end
  if PermissionService.IsBetaAdmin(name) then
    return "admin"
  end
  return PermissionService.RoleForRank(entry.rankName, mapping)
end

-- Own role from the own guild rank. Without a rank (not in a guild) there is no role, beta
-- exception included.
function PermissionService.OwnRole(platform, mapping)
  local role = PermissionService.RoleForRank(platform.GetOwnGuildRank(), mapping)
  if role ~= nil and PermissionService.IsBetaAdmin(platform.GetIdentityKey()) then
    return "admin"
  end
  return role
end

function PermissionService.Can(role, action)
  local allowed = ACTIONS[action]
  return allowed ~= nil and role ~= nil and allowed[role] == true
end

ns.PermissionService = PermissionService
