local _, ns = ...

-- Who may do what (docs/NAV_PERMISSIONS_PLAN.md section 1). A message never gets to say what its sender is allowed to
-- do: roles are worked out by the receiver from its own data.
--
-- The role is the guild rank, matched by name through Constants.RANK_ROLES, in order of authority:
--   gm, cogm, officer, rl (raid leader), roster, member, alter.
-- The guild master is always `gm`, recognised by the rank index 0 and never by name. A rank that is not listed in
-- RANK_ROLES is an `alter` (least privilege). Nothing stored in the addon assigns a role.
--
-- The rank says what a player can do, the roster (RosterService) says where. Each action gives, per role, a scope:
--   "all": on every roster      "own": only on the roster of the player      absent: not allowed.
local PermissionService = {}

local ORDER = { "gm", "cogm", "officer", "rl", "roster", "member", "alter" }
local RANK = {}
for index, role in ipairs(ORDER) do
  RANK[role] = index - 1
end

local ALL, OWN = "all", "own"

-- Every rank can do these, on anything (they are about the player's own data or open to the whole guild).
local EVERYONE = { gm = ALL, cogm = ALL, officer = ALL, rl = ALL, roster = ALL, member = ALL, alter = ALL }
-- Only the guild master and the co-guild master.
local GLOBAL_ONLY = { gm = ALL, cogm = ALL }

local ACTIONS = {
  -- The Admin group of the sidebar: officer, rl and above.
  admin_view = { gm = ALL, cogm = ALL, officer = ALL, rl = ALL },
  events_view = { gm = ALL, cogm = ALL, officer = OWN, rl = OWN, roster = OWN },
  event_signup = { gm = ALL, cogm = ALL, officer = OWN, rl = OWN, roster = OWN },
  raidcheck_view = { gm = ALL, cogm = ALL, officer = OWN, rl = OWN, roster = OWN },
  -- Creating and changing events, attendance, assignments and templates.
  raid_manage = { gm = ALL, cogm = ALL, officer = OWN, rl = OWN },
  loot_view = { gm = ALL, cogm = ALL, officer = OWN, rl = OWN, roster = OWN },
  -- Opening a session, voting and awarding.
  loot_manage = { gm = ALL, cogm = ALL, officer = OWN, rl = OWN },
  -- Putting yourself forward as a candidate: roster and above, on the roster of the event.
  loot_apply = { gm = ALL, cogm = ALL, officer = OWN, rl = OWN, roster = OWN },
  -- Raid rosters and the assignment of members to them. Officer reads, rl will assign to its own roster (later phases).
  members_view = { gm = ALL, cogm = ALL, officer = ALL, rl = OWN },
  members_manage = { gm = ALL, cogm = ALL, rl = OWN },
  rules_view = { gm = ALL, cogm = ALL, officer = ALL, rl = OWN },
  -- Setting the readiness rules the roster is measured against.
  rules_edit = { gm = ALL, cogm = ALL, rl = OWN },
  pvp_admin = GLOBAL_ONLY,
  -- The Installed check tab: who runs the addon and which version.
  install_check = GLOBAL_ONLY,

  edit_own_profile = EVERYONE,
  -- Sharing the own layer and taking part in a layer swap.
  layer_share = EVERYONE,
  -- Posting a group, applying to one and inviting an applicant (docs/LFG_PLAN.md).
  lfg_use = EVERYONE,
  -- Sharing the own map position and showing the others.
  position_share = EVERYONE,
  pvp_publish = EVERYONE,
  pvp_claim = EVERYONE,
  -- Everybody shares the recipes of their own character (plan 3.10).
  recipes_publish = EVERYONE,
  -- The blacklist is open to add to and closed to remove from: anyone can warn the guild about a player, only the
  -- guild master and the co-guild master can take the warning back.
  blacklist_add = EVERYONE,
  blacklist_remove = GLOBAL_ONLY,
  -- Changing the reason of a player who is already listed: the member who added the entry may (see
  -- BlacklistService.CanEdit), and so may gm and cogm, for any entry.
  blacklist_edit_any = GLOBAL_ONLY,
  -- Intel (docs/PVP_INTEL_PLAN.md): sharing the sightings of enemy players, and the guild Kill On Sight list. Every
  -- member adds; the member who added an entry changes and removes it (GuildKosService.CanEdit, CanRemove), and so
  -- may gm and cogm, for any entry.
  intel_share = EVERYONE,
  kos_add = EVERYONE,
  kos_edit_any = GLOBAL_ONLY,
  kos_remove_any = GLOBAL_ONLY,
  moderate = GLOBAL_ONLY,
  -- PvP seasons (docs/PVP_MISSIONS_PLAN.md section 3): every member claims, gm and cogm do everything else.
  pvp_claim_decide = GLOBAL_ONLY,
  pvp_delivery_mark = GLOBAL_ONLY,
  pvp_grant_direct = GLOBAL_ONLY,
  pvp_grant_void = GLOBAL_ONLY,
  pvp_season_manage = GLOBAL_ONLY,
  pvp_mission_manage = GLOBAL_ONLY,
  pvp_prize_manage = GLOBAL_ONLY,
  -- Publishing, editing and deleting guild announcements (docs/ANNOUNCEMENTS_MODULES_PVP_PLAN.md part B). The receiver
  -- applies an announcement only from a sender who has this action.
  announce_manage = GLOBAL_ONLY,
}

-- Maps a rank name to a role using `mapping` (default: Constants.RANK_ROLES). The name is trimmed and compared in
-- lowercase; a rank that is not listed is an `alter`. A missing rank name gives nil.
function PermissionService.RoleForRank(rankName, mapping)
  if type(rankName) ~= "string" or rankName == "" then
    return nil
  end
  mapping = mapping or ns.Constants.RANK_ROLES
  local name = rankName:match("^%s*(.-)%s*$"):lower()
  return mapping[name] or "alter"
end

-- true for the guild master: rank index 0.
function PermissionService.IsGuildMasterIndex(rankIndex)
  return rankIndex == ns.Constants.GUILD_MASTER_RANK_INDEX
end

-- Role of a guild roster entry ({ rankName, rankIndex }), or nil when it has no rank. The guild master is `gm`
-- whatever the rank is called.
function PermissionService.RoleOfEntry(entry, mapping)
  if type(entry) ~= "table" then
    return nil
  end
  if PermissionService.IsGuildMasterIndex(entry.rankIndex) then
    return "gm"
  end
  return PermissionService.RoleForRank(entry.rankName, mapping)
end

-- Role of `name` according to the local guild roster, or nil when the roster does not know them (not in the guild,
-- or the roster has not loaded yet). nil never grants anything.
-- options (optional): { mapping = rank mapping }.
function PermissionService.RoleOf(guildRoster, name, options)
  return PermissionService.RoleOfEntry(guildRoster:Lookup(name), options and options.mapping)
end

-- Own role. Without a rank (not in a guild) there is no role. The guild master is recognised by the rank index of
-- GetGuildInfo or by IsGuildLeader, whichever the client gives; the other roles come from the rank name.
function PermissionService.OwnRole(platform, options)
  local rankName, rankIndex = platform.GetOwnGuildRank()
  if type(rankName) ~= "string" or rankName == "" then
    return nil
  end
  if
    PermissionService.IsGuildMasterIndex(rankIndex) or (platform.IsGuildLeader and platform.IsGuildLeader() == true)
  then
    return "gm"
  end
  return PermissionService.RoleForRank(rankName, options and options.mapping)
end

-- Order of authority: 0 for gm up to 6 for alter, nil for anything else. For `Rank(role) <= Rank("rl")` checks.
function PermissionService.Rank(role)
  return RANK[role]
end

-- gm and cogm see and act on every roster.
function PermissionService.IsGlobal(role)
  return role == "gm" or role == "cogm"
end

-- Where `role` may do `action`: "all", "own" or "none". "own" needs a roster: without one it is "none".
function PermissionService.Scope(role, action, ownRosterId)
  local actionScopes = ACTIONS[action]
  local scope = actionScopes and role ~= nil and actionScopes[role] or nil
  if scope == ALL then
    return "all"
  elseif scope == OWN and ownRosterId ~= nil then
    return "own"
  end
  return "none"
end

-- Does the role have the action at any scope? A role that has it on its own roster only still counts: the callers
-- that need more than that check IsGlobal, or the roster with RosterService.MayAct.
function PermissionService.Can(role, action)
  local actionScopes = ACTIONS[action]
  return actionScopes ~= nil and role ~= nil and actionScopes[role] ~= nil
end

-- Does the role have the action on every roster? For what an `own` scope must not do yet (see the callers).
function PermissionService.CanAll(role, action)
  return PermissionService.Scope(role, action) == "all"
end

ns.PermissionService = PermissionService
