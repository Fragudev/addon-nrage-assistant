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

-- The rows an editor starts from (RankMapModel.Draft) for the saved map of the current guild.
function RankMapService:Draft(currentRanks)
  return Model.Draft(self:Current(), currentRanks)
end

-- Who changes role if `ranks` replaced the saved map (RankMapModel.Preview).
function RankMapService:Preview(guildRoster, ranks)
  return Model.Preview(guildRoster, self:Current(), ranks)
end

ns.RankMapService = RankMapService
