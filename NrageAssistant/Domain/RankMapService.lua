local _, ns = ...

-- The rank maps of the guilds this account knows (db.global.rankMaps) and the questions the interface asks about them
-- (docs/ANNOUNCEMENTS_MODULES_PVP_PLAN.md, part D). Pure: the guild comes from `deps.guildKey`, the roster from the
-- caller. Saving and receiving go through RankMapSync, which is where the authority checks live.
local RankMapService = {}
RankMapService.__index = RankMapService

local Model = ns.RankMapModel

-- "<guild name>-<realm>", the key of a guild in db.global.rankMaps, or nil while either is unknown. Keyed by guild so
-- characters in other guilds (or a fork of the addon for another guild) never share a map.
function RankMapService.GuildKey(guildName, realm)
  if type(guildName) ~= "string" or guildName == "" or type(realm) ~= "string" or realm == "" then
    return nil
  end
  return guildName .. "-" .. realm
end

-- deps: maps (db.global.rankMaps), guildKey = function() -> key or nil.
function RankMapService.New(deps)
  return setmetatable({ maps = deps.maps, guildKey = deps.guildKey }, RankMapService)
end

-- The rank map of the current guild, or nil while none was saved (the roles then come from the rank names).
function RankMapService:Current()
  local key = self.guildKey()
  local rankMap = key and self.maps[key] or nil
  if type(rankMap) == "table" and type(rankMap.ranks) == "table" then
    return rankMap
  end
  return nil
end

-- The function PermissionService reads (ns.rankMap).
function RankMapService:Provider()
  return function()
    return self:Current()
  end
end

-- The rows an editor starts from: the saved ones, plus today's name lookup for every rank the map does not cover.
-- Returns { [index] = { role, name } } for the ranks of the game (index 1 and up).
function RankMapService:Draft(currentRanks)
  local draft = Model.Defaults(currentRanks)
  local saved = self:Current()
  if saved then
    for index, row in pairs(saved.ranks) do
      if draft[index] and type(row) == "table" and Model.IsAssignable(row.role) then
        draft[index].role = row.role
      end
    end
  end
  return draft
end

-- Who changes role if `ranks` replaced the saved map: { name, rankName, from, to } for each guild member whose role
-- would differ, sorted by name. `guildRoster` needs Names() and Lookup(name); the members of rank 0 never change.
function RankMapService:Preview(guildRoster, ranks)
  local candidate = { ranks = ranks }
  local saved = self:Current()
  local changes = {}
  for _, name in ipairs(guildRoster:Names()) do
    local entry = guildRoster:Lookup(name)
    if entry and entry.rankIndex ~= ns.Constants.GUILD_MASTER_RANK_INDEX then
      local from = ns.PermissionService.RoleFor(entry.rankName, entry.rankIndex, saved)
      local to = ns.PermissionService.RoleFor(entry.rankName, entry.rankIndex, candidate)
      if from ~= to then
        changes[#changes + 1] = { name = name, rankName = entry.rankName, from = from, to = to }
      end
    end
  end
  return changes
end

ns.RankMapService = RankMapService
