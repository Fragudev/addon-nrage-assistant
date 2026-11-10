local _, ns = ...

-- Rank mapping (docs/ANNOUNCEMENTS_MODULES_PVP_PLAN.md, part D): which addon role each guild rank has, keyed by the
-- rank INDEX, so renaming a rank in the game keeps the role of its members. Pure: no client API, no storage.
--
--   rankMap = { rev, updatedAt, by, ranks = { [rankIndex] = { role = "cogm", name = "Comandante" } } }
--
-- Index 0 (the guild master) is never stored: it is always `gm`, and `gm` can not be assigned to another rank. `name`
-- is the rank name when the map was saved, used only to show a rename and never to decide anything.
local RankMapModel = {}

local V = ns.Validate
local isInt, isText = V.Int, V.Text

local NO_MAP = { ranks = {} }
local MAX_REV = 2147483647
local MAX_TIMESTAMP = 4102444800 -- 2100-01-01, as in Protocol

RankMapModel.MAX_INDEX = 9
RankMapModel.MAX_NAME = 32
RankMapModel.ASSIGNABLE = { "cogm", "officer", "rl", "roster", "member", "alter" }

local ASSIGNABLE_SET = {}
for _, role in ipairs(RankMapModel.ASSIGNABLE) do
  ASSIGNABLE_SET[role] = true
end

-- Every role but gm.
function RankMapModel.IsAssignable(role)
  return type(role) == "string" and ASSIGNABLE_SET[role] == true
end

-- The role of the saved row for `rankIndex`, or nil when there is none (or it is not usable).
local function mappedRole(rankMap, rankIndex)
  if type(rankMap) ~= "table" or type(rankMap.ranks) ~= "table" or type(rankIndex) ~= "number" then
    return nil
  end
  local row = rankMap.ranks[rankIndex]
  if type(row) == "table" and RankMapModel.IsAssignable(row.role) then
    return row.role
  end
  return nil
end

-- The addon role of a guild rank:
--   1. index 0 is `gm`;
--   2. an index the map covers gives its role, whatever the rank is called now;
--   3. any other rank keeps today's lookup by name (Constants.RANK_ROLES, "alter" when it is not listed), so with no
--      map saved the addon behaves exactly as it always did.
-- nil only when the name is needed and missing.
function RankMapModel.Resolve(rankMap, rankName, rankIndex)
  if rankIndex == ns.Constants.GUILD_MASTER_RANK_INDEX then
    return "gm"
  end
  return mappedRole(rankMap, rankIndex) or ns.PermissionService.RoleForRank(rankName)
end

-- The ranks `rankMap` and the game disagree about, in index order, as { index, savedName, currentName }: a rank
-- renamed has both names; one that appeared since has only currentName; one that is gone only savedName. Index 0 is
-- skipped. `currentRanks` = { [index] = name } (Platform.GetGuildRanks).
function RankMapModel.Drift(rankMap, currentRanks)
  local drift = {}
  if type(rankMap) ~= "table" or type(rankMap.ranks) ~= "table" or type(currentRanks) ~= "table" then
    return drift
  end
  local seen = {}
  for index in pairs(rankMap.ranks) do
    if type(index) == "number" and index > 0 then
      seen[index] = true
    end
  end
  for index in pairs(currentRanks) do
    if type(index) == "number" and index > 0 then
      seen[index] = true
    end
  end
  local indexes = {}
  for index in pairs(seen) do
    indexes[#indexes + 1] = index
  end
  table.sort(indexes)
  for _, index in ipairs(indexes) do
    local row = rankMap.ranks[index]
    local savedName = type(row) == "table" and row.name or nil
    local currentName = currentRanks[index]
    if savedName ~= currentName then
      drift[#drift + 1] = { index = index, savedName = savedName, currentName = currentName }
    end
  end
  return drift
end

-- The rows a first save would hold: every rank of the game but the guild master, with the role today's name lookup
-- gives it (never `gm`: a rank called like the guild master's is an alter, since only index 0 is the guild master).
-- Saving them changes nobody's role.
function RankMapModel.Defaults(currentRanks)
  local ranks = {}
  for index, name in pairs(currentRanks or {}) do
    if type(index) == "number" and index > 0 and index <= RankMapModel.MAX_INDEX and type(name) == "string" then
      local role = ns.PermissionService.RoleForRank(name)
      ranks[index] = { role = RankMapModel.IsAssignable(role) and role or "alter", name = name }
    end
  end
  return ranks
end

-- The rows an editor starts from: the saved ones where the game still has the rank, plus today's name lookup for every
-- other rank. { [index] = { role, name } } for the ranks of the game, index 1 and up.
function RankMapModel.Draft(rankMap, currentRanks)
  local draft = RankMapModel.Defaults(currentRanks)
  if type(rankMap) == "table" and type(rankMap.ranks) == "table" then
    for index, row in pairs(rankMap.ranks) do
      if draft[index] and type(row) == "table" and RankMapModel.IsAssignable(row.role) then
        draft[index].role = row.role
      end
    end
  end
  return draft
end

-- Who changes role if `ranks` replaced `rankMap`: { name, rankName, from, to } for each guild member whose role would
-- differ, sorted by name. `guildRoster` needs Names() and Lookup(name). The guild master never changes.
function RankMapModel.Preview(guildRoster, rankMap, ranks)
  local candidate = { ranks = ranks }
  local changes = {}
  for _, name in ipairs(guildRoster:Names()) do
    local entry = guildRoster:Lookup(name)
    if entry and entry.rankIndex ~= ns.Constants.GUILD_MASTER_RANK_INDEX then
      local from = ns.PermissionService.RoleFor(entry.rankName, entry.rankIndex, rankMap or NO_MAP)
      local to = ns.PermissionService.RoleFor(entry.rankName, entry.rankIndex, candidate)
      if from ~= to then
        changes[#changes + 1] = { name = name, rankName = entry.rankName, from = from, to = to }
      end
    end
  end
  return changes
end

-- A rank name as the wire carries it: no escape bars or control characters, at most MAX_NAME bytes, cut on a
-- character boundary.
local function wireName(name)
  if type(name) ~= "string" then
    return nil
  end
  name = name:gsub("|", ""):gsub("%c", "")
  if #name > RankMapModel.MAX_NAME then
    local cut = RankMapModel.MAX_NAME
    -- Step back over UTF-8 continuation bytes so a multi-byte character is not split.
    while cut > 0 do
      local byte = name:byte(cut + 1)
      if not byte or byte < 0x80 or byte >= 0xC0 then
        break
      end
      cut = cut - 1
    end
    name = name:sub(1, cut)
  end
  if name == "" then
    return nil
  end
  return name
end

-- A stored map as the RANK_MAP payload: { rev, updatedAt, ranks = { { i, r, n }, ... } } in index order. Rows that
-- are not usable are left out.
function RankMapModel.ToWire(rankMap)
  local rows = {}
  for index, row in pairs(rankMap.ranks or {}) do
    local name = type(row) == "table" and wireName(row.name) or nil
    if isInt(index, 1, RankMapModel.MAX_INDEX) and name and RankMapModel.IsAssignable(row.role) then
      rows[#rows + 1] = { i = index, r = row.role, n = name }
    end
  end
  table.sort(rows, function(a, b)
    return a.i < b.i
  end)
  return { rev = rankMap.rev, updatedAt = rankMap.updatedAt, ranks = rows }
end

-- The clean payload or nil: rev and updatedAt in range, at most MAX_INDEX rows, each with an index of 1 to MAX_INDEX
-- that appears once, an assignable role and a plain name. Unknown fields are dropped. Never trusts the roles in it:
-- the receiver decides who may send it (RankMapSync).
function RankMapModel.ValidateWire(payload)
  if type(payload) ~= "table" or type(payload.ranks) ~= "table" then
    return nil
  end
  if not (isInt(payload.rev, 1, MAX_REV) and isInt(payload.updatedAt, 0, MAX_TIMESTAMP)) then
    return nil
  end
  if #payload.ranks > RankMapModel.MAX_INDEX then
    return nil
  end
  local rows, used = {}, {}
  for position, row in ipairs(payload.ranks) do
    if
      type(row) ~= "table"
      or not isInt(row.i, 1, RankMapModel.MAX_INDEX)
      or used[row.i]
      or not RankMapModel.IsAssignable(row.r)
      or not isText(row.n, RankMapModel.MAX_NAME)
    then
      return nil
    end
    used[row.i] = true
    rows[position] = { i = row.i, r = row.r, n = row.n }
  end
  table.sort(rows, function(a, b)
    return a.i < b.i
  end)
  return { rev = payload.rev, updatedAt = payload.updatedAt, ranks = rows }
end

-- The stored form of a validated payload (the author is the sender, set by the caller).
function RankMapModel.FromWire(payload)
  local ranks = {}
  for _, row in ipairs(payload.ranks) do
    ranks[row.i] = { role = row.r, name = row.n }
  end
  return { rev = payload.rev, updatedAt = payload.updatedAt, ranks = ranks }
end

-- A copy of the rows, for editing without touching the stored map.
function RankMapModel.CopyRanks(ranks)
  local copy = {}
  for index, row in pairs(ranks or {}) do
    if type(row) == "table" then
      copy[index] = { role = row.role, name = row.name }
    end
  end
  return copy
end

ns.RankMapModel = RankMapModel
