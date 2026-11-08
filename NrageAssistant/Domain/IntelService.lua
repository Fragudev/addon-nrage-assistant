local _, ns = ...

-- The lists of Intel (docs/PVP_INTEL_PLAN.md): the enemy players met, the ones nearby now, the personal Kill On Sight
-- and Ignore lists, and a read-only view of the guild Kill On Sight list. Pure logic over plain tables with an
-- injected store and clocks, so it is tested without a client.
--
--   intel.players[key] = { name, class, race, level, levelEstimated, guild, faction, firstSeen, lastSeen, seen, wins,
--                          losses, lastMap, lastX, lastY }        (saved; wall-clock seconds)
--   intel.kos[key]     = { name, category, reason, addedAt }       personal, never sent
--   intel.ignore[key]  = { name, addedAt }                         personal, never sent
--   intel.zones[mapId] = contacts
--   guildKos[key]      = the guild list (GuildKosService owns it; only read here)
-- `key` is IntelModel.Key(name). Nearby is kept in memory only, in monotonic seconds.
--
-- deps = { intel = db.global.intel, guildKos = db.global.guildKos, settings = function() -> Settings.Intel,
--          now = function() -> monotonic seconds, wall = function() -> server time in seconds }
local IntelService = {}
IntelService.__index = IntelService

local Model = ns.IntelModel

local function ensure(parent, key)
  if type(parent[key]) ~= "table" then
    parent[key] = {}
  end
  return parent[key]
end

local function countKeys(tbl)
  local count = 0
  for _ in pairs(tbl) do
    count = count + 1
  end
  return count
end

local function copy(value)
  local result = {}
  for key, inner in pairs(value) do
    result[key] = inner
  end
  return result
end

function IntelService.New(deps)
  local intel = deps.intel
  for _, name in ipairs({ "players", "kos", "ignore", "zones" }) do
    ensure(intel, name)
  end
  return setmetatable({
    deps = deps,
    intel = intel,
    guildKos = deps.guildKos or {},
    nearby = {},
    playerCount = countKeys(intel.players),
    session = IntelService.NewSession(),
  }, IntelService)
end

-- The counters of this session, kept in memory only (IntelReport.Session reads them): contacts, wins, losses and
-- Kill On Sight entries added, how often each enemy was met (`seen`), killed the player (`lostTo`), and in which map
-- contacts happened (`zones`); `names` gives the name behind a key.
function IntelService.NewSession()
  return { contacts = 0, wins = 0, losses = 0, newKos = 0, seen = {}, lostTo = {}, zones = {}, names = {} }
end

-- The seconds an entry stays in Nearby, or 0 for "never leaves".
function IntelService:Delay()
  local minutes = self.deps.settings().removeMinutes
  return type(minutes) == "number" and minutes * 60 or 0
end

local function alive(entry, now, delay)
  return delay == 0 or now - entry.lastSeen <= delay
end

-- "personal", "guild" or nil, plus the entry, for a name (or a key).
function IntelService:IsKos(name)
  local key = Model.Key(name)
  if not key then
    return nil
  end
  if self.intel.kos[key] then
    return "personal", self.intel.kos[key]
  end
  if self.guildKos[key] then
    return "guild", self.guildKos[key]
  end
  return nil
end

function IntelService:IsIgnored(name)
  local key = Model.Key(name)
  return key ~= nil and self.intel.ignore[key] ~= nil
end

-- Makes room for one more player record. When the list is full, the PLAYER_EVICT_SHARE oldest records (by lastSeen)
-- go in one pass, so the full scan runs once per batch of new enemies instead of once per new enemy.
local PLAYER_EVICT_SHARE = 0.05

function IntelService:MakePlayerRoom()
  local max = ns.Constants.INTEL_PLAYERS_MAX
  if self.playerCount < max then
    return
  end
  local list = {}
  for key, record in pairs(self.intel.players) do
    list[#list + 1] =
      { key = key, at = type(record) == "table" and type(record.lastSeen) == "number" and record.lastSeen or 0 }
  end
  table.sort(list, function(a, b)
    if a.at ~= b.at then
      return a.at < b.at
    end
    return a.key < b.key
  end)
  local evict = math.max(1, math.floor(max * PLAYER_EVICT_SHARE))
  for index = 1, math.min(evict, #list) do
    self.intel.players[list[index].key] = nil
  end
  self.playerCount = #list - math.min(evict, #list)
end

-- Counts one contact on a map. A map that is new when the list is full is not counted.
function IntelService:CountZone(map)
  local zones = self.intel.zones
  if zones[map] then
    zones[map] = zones[map] + 1
  elseif countKeys(zones) < ns.Constants.INTEL_ZONES_MAX then
    zones[map] = 1
  end
end

-- A saved record that has what the views read; a damaged one is skipped.
local function usable(record)
  return type(record) == "table"
    and type(record.name) == "string"
    and type(record.lastSeen) == "number"
    and type(record.wins) == "number"
    and type(record.losses) == "number"
end

local function updateRecord(record, details, name)
  record.name = name
  record.class = details.class or record.class
  record.race = details.race or record.race
  record.guild = details.guild or record.guild
  record.faction = details.faction or record.faction
  if type(details.level) == "number" then
    record.level = details.level
    record.levelEstimated = details.levelEstimated == true
  end
end

-- An enemy was read: `details` = { name, class, race, level, levelEstimated, guild, faction, stealth }, `where` =
-- { map, x, y } (the reporter's position, any part may be nil). Updates the record, the zone count and the Nearby
-- entry. Returns { isNew, record, key, kos, ignored } (isNew: the player was not in Nearby), or nil plus "bad_name".
-- An ignored player is recorded but never enters Nearby.
function IntelService:OnSeen(details, where)
  local name = type(details) == "table" and Model.CleanName(details.name) or nil
  if not name then
    return nil, "bad_name"
  end
  where = type(where) == "table" and where or {}
  local key = Model.Key(name)
  local now, wall, delay = self.deps.now(), self.deps.wall(), self:Delay()

  local entry = self.nearby[key]
  local isNew = not (entry and alive(entry, now, delay))

  local players = self.intel.players
  local record = players[key]
  -- A damaged saved record is replaced, like Touch does: the counters below must be numbers.
  if not (usable(record) and type(record.seen) == "number") then
    if record == nil then
      self:MakePlayerRoom()
      self.playerCount = self.playerCount + 1
    end
    record = { firstSeen = wall, seen = 0, wins = 0, losses = 0 }
    players[key] = record
  end
  updateRecord(record, details, name)
  record.lastSeen = wall
  if where.map then
    record.lastMap, record.lastX, record.lastY = where.map, where.x, where.y
  end

  local kos = self:IsKos(key)
  if self:IsIgnored(key) then
    return { isNew = false, record = record, key = key, kos = kos, ignored = true }
  end

  if isNew then
    record.seen = record.seen + 1
    local session = self.session
    session.contacts = session.contacts + 1
    session.seen[key] = (session.seen[key] or 0) + 1
    session.names[key] = name
    if where.map then
      self:CountZone(where.map)
      session.zones[where.map] = (session.zones[where.map] or 0) + 1
    end
    entry = { key = key, firstSeen = now }
    self.nearby[key] = entry
  end
  entry.lastSeen = now
  entry.name = name
  entry.class, entry.race = details.class or entry.class, details.race or entry.race
  entry.guild, entry.faction = details.guild or entry.guild, details.faction or entry.faction
  if type(details.level) == "number" then
    entry.level, entry.levelEstimated = details.level, details.levelEstimated == true
  end
  entry.stealth = details.stealth == true
  entry.map, entry.x, entry.y = where.map or entry.map, where.x or entry.x, where.y or entry.y
  return { isNew = isNew, record = record, key = key, kos = kos }
end

-- The saved record of a player met, or nil.
function IntelService:Player(name)
  local key = Model.Key(name)
  local record = key and self.intel.players[key]
  if usable(record) then
    return record, key
  end
  return nil
end

-- The record of `name`, made when the player was never met (a kill or a death can name one the nameplates never
-- showed). Returns the record plus its key, or nil plus "bad_name".
function IntelService:Touch(name)
  local clean = Model.CleanName(name)
  if not clean then
    return nil, "bad_name"
  end
  local key = Model.Key(clean)
  local record = self.intel.players[key]
  if not usable(record) then
    if not record then
      self:MakePlayerRoom()
      self.playerCount = self.playerCount + 1
    end
    local wall = self.deps.wall()
    record = { firstSeen = wall, lastSeen = wall, seen = 0, wins = 0, losses = 0 }
    self.intel.players[key] = record
  end
  record.name = clean
  return record, key
end

-- The player was the victim of an honour kill credited to the own character. Returns the record plus its key, or nil
-- plus "bad_name".
function IntelService:OnWin(victim)
  local record, key = self:Touch(victim)
  if not record then
    return nil, key
  end
  record.wins = record.wins + 1
  record.lastSeen = self.deps.wall()
  self.session.wins = self.session.wins + 1
  self.session.names[key] = record.name
  return record, key
end

-- The player killed the own character. Returns the record plus its key, or nil plus "bad_name".
function IntelService:OnLoss(killer)
  local record, key = self:Touch(killer)
  if not record then
    return nil, key
  end
  record.losses = record.losses + 1
  record.lastSeen = self.deps.wall()
  self.session.losses = self.session.losses + 1
  self.session.lostTo[key] = (self.session.lostTo[key] or 0) + 1
  self.session.names[key] = record.name
  return record, key
end

-- Marks the enemy of `name` that is in Nearby as having cast a stealth ability. Returns true when it is there.
function IntelService:MarkStealth(name)
  local entry = self.nearby[Model.Key(name) or ""]
  if not entry then
    return false
  end
  entry.stealth = true
  return true
end

local function byKosThenRecent(a, b)
  local aKos, bKos = a.kos ~= nil, b.kos ~= nil
  if aKos ~= bKos then
    return aKos
  end
  if a.lastSeen ~= b.lastSeen then
    return a.lastSeen > b.lastSeen
  end
  return a.name < b.name
end

-- The players nearby now: { key, name, class, race, level, levelEstimated, guild, faction, stealth, map, x, y, age,
-- faded, kos, lastSeen, source }, Kill On Sight first and then the most recent. An entry fades at half the delay and
-- is dropped when it is older than the delay (a delay of 0 keeps it). `remote` (optional) is a list of sightings
-- received from the guild, already limited to the own map: { key, name, class, race, level, estimated, stealth, map,
-- x, y, at (monotonic), source }. They follow the same rules and never replace an enemy that was seen here.
function IntelService:Nearby(now, remote)
  local delay = self:Delay()
  local list = {}
  for key, entry in pairs(self.nearby) do
    if alive(entry, now, delay) then
      local item = copy(entry)
      item.age = now - entry.lastSeen
      item.faded = delay > 0 and item.age >= delay / 2
      item.kos = self:IsKos(key)
      list[#list + 1] = item
    else
      self.nearby[key] = nil
    end
  end
  for _, sighting in ipairs(remote or {}) do
    local key = sighting.key or Model.Key(sighting.name)
    local item = { lastSeen = sighting.at }
    if key and not self.nearby[key] and not self:IsIgnored(key) and alive(item, now, delay) then
      item.key, item.name = key, sighting.name
      item.class, item.race = sighting.class, sighting.race
      item.level, item.levelEstimated = sighting.level, sighting.estimated == true
      item.stealth = sighting.stealth == true
      item.map, item.x, item.y = sighting.map, sighting.x, sighting.y
      item.source = sighting.source
      item.age = now - sighting.at
      item.faded = delay > 0 and item.age >= delay / 2
      item.kos = self:IsKos(key)
      list[#list + 1] = item
    end
  end
  table.sort(list, byKosThenRecent)
  return list
end

-- The guilds of the Kill On Sight players (personal and guild list) as a set of lower-case names, from the records of
-- the players met. A player never met, or met without a guild, adds nothing.
function IntelService:KosGuilds()
  local set = {}
  for _, source in ipairs({ self.intel.kos, self.guildKos }) do
    for key in pairs(source) do
      local record = self.intel.players[key]
      if type(record) == "table" and type(record.guild) == "string" and record.guild ~= "" then
        set[record.guild:lower()] = true
      end
    end
  end
  return set
end

-- A copy of a record with its key and its Kill On Sight scope.
function IntelService:View(key, record)
  local item = copy(record)
  item.key = key
  item.kos = self:IsKos(key)
  return item
end

-- The players seen in the last hour (wall-clock `now`), most recent first. Ignored players are left out.
function IntelService:LastHour(now)
  local since = now - ns.Constants.INTEL_LAST_HOUR_SECONDS
  local list = {}
  for key, record in pairs(self.intel.players) do
    if usable(record) and record.lastSeen >= since and not self.intel.ignore[key] then
      list[#list + 1] = self:View(key, record)
    end
  end
  table.sort(list, function(a, b)
    if a.lastSeen ~= b.lastSeen then
      return a.lastSeen > b.lastSeen
    end
    return a.name < b.name
  end)
  return list
end

-- Sort keys and the direction each one starts with.
local SORTS = {
  lastSeen = { descending = true },
  name = { descending = false, text = true },
  level = { descending = true },
  guild = { descending = false, text = true },
  wins = { descending = true },
  losses = { descending = true },
}

IntelService.SORT_KEYS = { "lastSeen", "name", "level", "guild", "wins", "losses" }

local function matches(item, filter)
  if filter.text and filter.text ~= "" then
    local needle = filter.text:lower()
    if not (item.name:lower():find(needle, 1, true) or (item.guild and item.guild:lower():find(needle, 1, true))) then
      return false
    end
  end
  if filter.kos and not item.kos then
    return false
  end
  if filter.wins and item.wins <= 0 then
    return false
  end
  if filter.losses and item.losses <= 0 then
    return false
  end
  if filter.category then
    if not (item.kosEntry and item.kosEntry.category == filter.category) then
      return false
    end
  end
  return true
end

-- Every player met, as copies with `key` and `kos`. `filter` (optional) = { text (name or guild, any case), kos,
-- wins, losses (booleans), category (a Kill On Sight category) }. `sort` is a key of IntelService.SORT_KEYS, or
-- { key, descending }; the default is the most recently seen first. Ties are broken by name.
function IntelService:Stats(filter, sort)
  filter = type(filter) == "table" and filter or {}
  local key, descending = "lastSeen", nil
  if type(sort) == "string" then
    key = sort
  elseif type(sort) == "table" then
    key, descending = sort.key or key, sort.descending
  end
  local spec = SORTS[key] or SORTS.lastSeen
  if not SORTS[key] then
    key = "lastSeen"
  end
  if descending == nil then
    descending = spec.descending
  end

  local list = {}
  for playerKey, record in pairs(self.intel.players) do
    if usable(record) then
      local item = self:View(playerKey, record)
      if filter.category then
        item.kosEntry = select(2, self:IsKos(playerKey))
      end
      if matches(item, filter) then
        item.kosEntry = nil
        list[#list + 1] = item
      end
    end
  end
  table.sort(list, function(a, b)
    local left, right = a[key], b[key]
    if spec.text then
      left, right = (left or ""):lower(), (right or ""):lower()
      -- A blank value (a player with no guild) goes last whichever way the list runs.
      if (left == "") ~= (right == "") then
        return right == ""
      end
    else
      left, right = left or -1, right or -1
    end
    if left ~= right then
      if descending then
        return left > right
      end
      return left < right
    end
    return a.name:lower() < b.name:lower()
  end)
  return list
end

-- The Kill On Sight entries of "personal" or "guild" as copies with their `key`, sorted by name.
function IntelService:KosList(scope)
  local source = scope == "guild" and self.guildKos or self.intel.kos
  local list = {}
  for key, entry in pairs(source) do
    if type(entry) == "table" and type(entry.name) == "string" then
      local item = copy(entry)
      item.key = key
      list[#list + 1] = item
    end
  end
  table.sort(list, function(a, b)
    local left, right = a.name:lower(), b.name:lower()
    if left ~= right then
      return left < right
    end
    return a.key < b.key
  end)
  return list
end

-- Adds a player to the personal Kill On Sight list, or changes the category and reason of one that is there. The
-- player leaves the Ignore list. Returns the entry plus its key, or nil plus a ValidateKos reason | "limit".
function IntelService:AddKos(fields)
  local clean, why = Model.ValidateKos(fields)
  if not clean then
    return nil, why
  end
  local kos = self.intel.kos
  local entry = kos[clean.key]
  if not entry then
    if countKeys(kos) >= ns.Constants.INTEL_KOS_MAX then
      return nil, "limit"
    end
    entry = { addedAt = self.deps.wall() }
    kos[clean.key] = entry
    self.session.newKos = self.session.newKos + 1
  end
  entry.name, entry.category, entry.reason = clean.name, clean.category, clean.reason
  self.intel.ignore[clean.key] = nil
  return entry, clean.key
end

-- Returns true when the player was on the personal list.
function IntelService:RemoveKos(key)
  if type(key) ~= "string" or not self.intel.kos[key] then
    return false
  end
  self.intel.kos[key] = nil
  return true
end

-- Adds a player to the Ignore list (and takes it off the personal Kill On Sight list). It also leaves Nearby.
-- Returns the entry plus its key, or nil plus "bad_name" | "limit".
function IntelService:AddIgnore(name)
  local clean = Model.CleanName(name)
  if not clean then
    return nil, "bad_name"
  end
  local key = Model.Key(clean)
  local ignore = self.intel.ignore
  if not ignore[key] then
    if countKeys(ignore) >= ns.Constants.INTEL_IGNORE_MAX then
      return nil, "limit"
    end
    ignore[key] = { name = clean, addedAt = self.deps.wall() }
  end
  self.intel.kos[key] = nil
  self.nearby[key] = nil
  return ignore[key], key
end

function IntelService:RemoveIgnore(key)
  if type(key) ~= "string" or not self.intel.ignore[key] then
    return false
  end
  self.intel.ignore[key] = nil
  return true
end

-- The ignored players as copies with their `key`, sorted by name.
function IntelService:IgnoreList()
  local list = {}
  for key, entry in pairs(self.intel.ignore) do
    if type(entry) == "table" and type(entry.name) == "string" then
      local item = copy(entry)
      item.key = key
      list[#list + 1] = item
    end
  end
  table.sort(list, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  return list
end

function IntelService:ClearNearby()
  self.nearby = {}
end

-- Takes one player out of Nearby (the menu of the window). Returns true when he was there.
function IntelService:RemoveNearby(key)
  if type(key) ~= "string" or not self.nearby[key] then
    return false
  end
  self.nearby[key] = nil
  return true
end

-- Forgets the players met and the contact counts, and Nearby. The personal lists are the player's own work and stay.
function IntelService:Reset()
  self.intel.players = {}
  self.intel.zones = {}
  self.playerCount = 0
  self.nearby = {}
  self.session = IntelService.NewSession()
end

-- Removes the player records not seen for Constants.INTEL_RETENTION_DAYS (wall-clock `now`). Returns how many.
function IntelService:Prune(now)
  local limit = now - ns.Constants.INTEL_RETENTION_DAYS * 86400
  local removed = 0
  for key, record in pairs(self.intel.players) do
    if type(record) ~= "table" or type(record.lastSeen) ~= "number" or record.lastSeen < limit then
      self.intel.players[key] = nil
      removed = removed + 1
    end
  end
  self.playerCount = self.playerCount - removed
  return removed
end

-- How many records each list holds, for /nrage intel debug.
function IntelService:Counts()
  return {
    players = self.playerCount,
    kos = countKeys(self.intel.kos),
    ignore = countKeys(self.intel.ignore),
    zones = countKeys(self.intel.zones),
    guildKos = countKeys(self.guildKos),
    nearby = countKeys(self.nearby),
  }
end

ns.IntelService = IntelService
