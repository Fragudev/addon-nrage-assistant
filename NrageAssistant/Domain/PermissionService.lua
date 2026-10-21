local _, ns = ...

-- Who may do what (plan section 12). A message never gets to say what its sender is allowed to do: roles are worked
-- out by the receiver from its own data.
-- Roles: member, rl (raid leader), council (loot council) and admin. A raid leader votes and awards loot like the
-- council (issue #24), but only the council and admins open sessions.
--
-- Where a role comes from (Constants.ROLE_SOURCE, plan 3.4.2):
--   "assigned" (now): the guild master is the only admin, recognised by the guild rank index 0 and never by name.
--                     Everybody else has the role the guild master assigned in the Members tab (synced as MEMBER
--                     records), or "member" when nothing was assigned. `admin` can never be assigned.
--   "rank":           the old behaviour, from the rank name through Constants.RANK_ROLES.
local PermissionService = {}

local ACTIONS = {
  view = { member = true, rl = true, council = true, admin = true },
  edit_own_profile = { member = true, rl = true, council = true, admin = true },
  manage_events = { rl = true, admin = true },
  record_attendance = { rl = true, admin = true },
  manage_assignments = { rl = true, admin = true },
  loot_apply = { member = true, rl = true, council = true, admin = true },
  loot_open = { council = true, admin = true },
  loot_vote = { rl = true, council = true, admin = true },
  loot_award = { rl = true, council = true, admin = true },
  -- Sharing the own layer and taking part in a layer swap: every member.
  layer_share = { member = true, rl = true, council = true, admin = true },
  -- Sharing the own map position and showing the others: every member (same rule as layer_share).
  position_share = { member = true, rl = true, council = true, admin = true },
  pvp_publish = { member = true, rl = true, council = true, admin = true },
  -- The blacklist is open to add to and closed to remove from: anyone can warn the guild about a player, only an
  -- admin can take the warning back.
  blacklist_add = { member = true, rl = true, council = true, admin = true },
  blacklist_remove = { admin = true },
  -- Changing the reason of a player who is already listed: the member who added the entry may (see
  -- BlacklistService.CanEdit), and so may an admin, for any entry.
  blacklist_edit_any = { admin = true },
  -- Setting the readiness rules the whole guild is measured against. Admin only, confirmed with the rest of the
  -- authority matrix in issue #41.
  rules_edit = { admin = true },
  moderate = { admin = true },
  -- Raid rosters (plan 3.4.1): defining them and assigning members and raid leaders to them, and seeing every roster.
  roster_manage = { admin = true },
  roster_view_all = { admin = true },
  -- Everybody shares the recipes of their own character (plan 3.10).
  recipes_publish = { member = true, rl = true, council = true, admin = true },
  -- PvP seasons (docs/PVP_MISSIONS_PLAN.md section 3). Every member claims; an admin does everything else. A PvP
  -- officer (a flag, not a role: see CanPvP) may also decide claims and mark deliveries.
  pvp_claim = { member = true, rl = true, council = true, admin = true },
  pvp_claim_decide = { admin = true },
  pvp_delivery_mark = { admin = true },
  pvp_grant_direct = { admin = true },
  pvp_grant_void = { admin = true },
  pvp_season_manage = { admin = true },
  pvp_mission_manage = { admin = true },
  pvp_prize_manage = { admin = true },
  pvp_officer_assign = { admin = true },
}

-- What the PvP officer flag adds on top of the role. Anything else stays with the role.
local OFFICER_ACTIONS = { pvp_claim_decide = true, pvp_delivery_mark = true }

-- The assignments table the role lookups read when none is passed: db.global.members. Set once at startup.
local configured = {}

-- options: { members = db.global.members }. Anything else keeps its value.
function PermissionService.Configure(options)
  for key, value in pairs(options or {}) do
    configured[key] = value
  end
end

-- Maps a rank name to a role using `mapping` (default: Constants.RANK_ROLES). Unlisted ranks are
-- plain members; a missing rank name gives nil.
function PermissionService.RoleForRank(rankName, mapping)
  if type(rankName) ~= "string" or rankName == "" then
    return nil
  end
  mapping = mapping or ns.Constants.RANK_ROLES
  return mapping[rankName:lower()] or "member"
end

local function isAssignable(role)
  for _, allowed in ipairs(ns.Constants.ASSIGNABLE_ROLES) do
    if role == allowed then
      return true
    end
  end
  return false
end

-- The role the guild master assigned to `key`, or nil. `members` = db.global.members. `admin` is never returned: a
-- record that says so (an old or modified client) counts as nothing.
function PermissionService.AssignedRole(members, key)
  local record = members and key and members[key]
  if type(record) == "table" and isAssignable(record.role) then
    return record.role
  end
  return nil
end

local function sourceOf(options)
  return (options and options.source) or ns.Constants.ROLE_SOURCE
end

local function membersOf(options)
  return (options and options.members) or configured.members
end

-- true for the guild master: rank index 0.
function PermissionService.IsGuildMasterIndex(rankIndex)
  return rankIndex == ns.Constants.GUILD_MASTER_RANK_INDEX
end

-- Role of `name` according to the local guild roster, or nil when the roster does not know them (not in the guild,
-- or the roster has not loaded yet). nil never grants anything.
-- options (optional): { members = assignments table, source = "assigned" | "rank", mapping = rank mapping }.
function PermissionService.RoleOf(guildRoster, name, options)
  local entry = guildRoster:Lookup(name)
  if not entry then
    return nil
  end
  if sourceOf(options) == "rank" then
    return PermissionService.RoleForRank(entry.rankName, options and options.mapping)
  end
  if PermissionService.IsGuildMasterIndex(entry.rankIndex) then
    return "admin"
  end
  return PermissionService.AssignedRole(membersOf(options), name) or "member"
end

-- Own role. Without a rank (not in a guild) there is no role. The guild master is recognised by the rank index of
-- GetGuildInfo or by IsGuildLeader, whichever the client gives; the other roles come from the assignments.
function PermissionService.OwnRole(platform, options)
  local rankName, rankIndex = platform.GetOwnGuildRank()
  if type(rankName) ~= "string" or rankName == "" then
    return nil
  end
  if sourceOf(options) == "rank" then
    return PermissionService.RoleForRank(rankName, options and options.mapping)
  end
  if
    PermissionService.IsGuildMasterIndex(rankIndex) or (platform.IsGuildLeader and platform.IsGuildLeader() == true)
  then
    return "admin"
  end
  local key = platform.GetIdentityKey and platform.GetIdentityKey()
  return PermissionService.AssignedRole(membersOf(options), key) or "member"
end

function PermissionService.Can(role, action)
  local allowed = ACTIONS[action]
  return allowed ~= nil and role ~= nil and allowed[role] == true
end

-- Like Can, plus the PvP officer flag. `isOfficer` comes from the receiver's own officer records (never from a
-- message), and a sender the roster does not know (nil role) gets nothing either way.
function PermissionService.CanPvP(role, isOfficer, action)
  if PermissionService.Can(role, action) then
    return true
  end
  return role ~= nil and isOfficer == true and OFFICER_ACTIONS[action] == true
end

ns.PermissionService = PermissionService
