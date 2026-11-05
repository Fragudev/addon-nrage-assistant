local _, ns = ...

-- The layers the guild members said they are on. In memory only; nothing is saved or put in a snapshot. Nothing
-- here touches the client: the clock and the guild membership are injected.
--
--   * Apply(sender, state) keeps { map, layer, at } per member, replacing the older one. `layer = 0` means "forget
--     me" (a member who stopped sharing).
--   * An entry older than Constants.LAYER_STATE_TTL, or of someone who left the guild roster, is not listed.
--
-- deps = { now = function() -> seconds (monotonic), isMember = function(name) -> boolean (optional: everyone) }
local LayerDirectory = {}
LayerDirectory.__index = LayerDirectory

function LayerDirectory.New(deps)
  return setmetatable({ deps = deps, entries = {}, count = 0 }, LayerDirectory)
end

-- Returns true, or false plus "bad_state" | "limit".
function LayerDirectory:Apply(sender, state)
  local constants = ns.Constants
  if type(sender) ~= "string" or sender == "" or type(state) ~= "table" then
    return false, "bad_state"
  end
  if
    not (
      ns.Validate.Int(state.map, 0, constants.LAYER_MAP_MAX) and ns.Validate.Int(state.layer, 0, constants.LAYER_ID_MAX)
    )
  then
    return false, "bad_state"
  end
  if state.layer == 0 then
    self:Remove(sender)
    return true
  end
  if not self.entries[sender] then
    if self.count >= constants.GUILD_ROSTER_MAX then
      -- Stale entries are never listed anyway: drop them before refusing a new sender.
      self:Prune()
      if self.count >= constants.GUILD_ROSTER_MAX then
        return false, "limit"
      end
    end
    self.count = self.count + 1
  end
  self.entries[sender] = { map = state.map, layer = state.layer, at = self.deps.now() }
  return true
end

-- Drops the entries older than Constants.LAYER_STATE_TTL. Returns how many.
function LayerDirectory:Prune()
  local now = self.deps.now()
  local removed = 0
  for name, entry in pairs(self.entries) do
    if now - entry.at > ns.Constants.LAYER_STATE_TTL then
      self.entries[name] = nil
      self.count = self.count - 1
      removed = removed + 1
    end
  end
  return removed
end

function LayerDirectory:Remove(sender)
  if self.entries[sender] then
    self.entries[sender] = nil
    self.count = self.count - 1
  end
end

-- The names that are fresh and still in the guild, with their entry, sorted by name.
function LayerDirectory:Fresh()
  local now = self.deps.now()
  local list = {}
  for name, entry in pairs(self.entries) do
    local member = true
    if self.deps.isMember then
      local ok, result = pcall(self.deps.isMember, name)
      member = ok and result == true
    end
    if member and now - entry.at <= ns.Constants.LAYER_STATE_TTL then
      list[#list + 1] = { name = name, map = entry.map, layer = entry.layer }
    end
  end
  table.sort(list, function(a, b)
    return a.name < b.name
  end)
  return list
end

-- The layers of the continent `map` (every continent when nil), each as { map, layer, members = {names}, count },
-- the most crowded first.
function LayerDirectory:Groups(map)
  local byKey, groups = {}, {}
  for _, entry in ipairs(self:Fresh()) do
    if map == nil or entry.map == map then
      local key = ns.LayerModel.Key(entry.map, entry.layer)
      local group = byKey[key]
      if not group then
        group = { map = entry.map, layer = entry.layer, members = {}, count = 0 }
        byKey[key] = group
        groups[#groups + 1] = group
      end
      group.members[#group.members + 1] = entry.name
      group.count = group.count + 1
    end
  end
  table.sort(groups, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    if a.map ~= b.map then
      return a.map < b.map
    end
    return a.layer < b.layer
  end)
  return groups
end

function LayerDirectory:MembersOn(map, layer)
  local names = {}
  for _, entry in ipairs(self:Fresh()) do
    if entry.map == map and entry.layer == layer then
      names[#names + 1] = entry.name
    end
  end
  return names
end

ns.LayerDirectory = LayerDirectory
