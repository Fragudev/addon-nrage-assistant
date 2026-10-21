local _, ns = ...

-- The positions the guild members shared. In memory only; nothing is saved or put in a snapshot. Nothing here
-- touches the client: the clock is injected.
--
--   * Apply(sender, decoded) keeps { map, x, y, at } per member, replacing the older one. A `forget` removes the
--     member. At most Constants.POSITION_DIRECTORY_MAX members are kept: new ones are refused when it is full.
--   * An entry older than Constants.POSITION_TTL is removed by Prune() and is not listed.
--   * onChange() fires after anything was added, replaced or removed, so the pins can be redrawn.
--
-- deps = { now = function() -> seconds (monotonic), onChange = function() (optional) }
local PositionDirectory = {}
PositionDirectory.__index = PositionDirectory

function PositionDirectory.New(deps)
  return setmetatable({ deps = deps, entries = {}, count = 0 }, PositionDirectory)
end

local function changed(self)
  if self.deps.onChange then
    pcall(self.deps.onChange)
  end
end

-- Returns true, or false plus "bad_sender" | "bad_state" | "limit".
function PositionDirectory:Apply(sender, decoded)
  local constants = ns.Constants
  if type(sender) ~= "string" or sender == "" then
    return false, "bad_sender"
  end
  if type(decoded) ~= "table" then
    return false, "bad_state"
  end
  if decoded.forget == true then
    self:Remove(sender)
    return true
  end
  if
    not (
      ns.Validate.Int(decoded.map, 1, constants.LAYER_MAP_MAX)
      and ns.Validate.Int(decoded.x, 0, constants.POSITION_SCALE)
      and ns.Validate.Int(decoded.y, 0, constants.POSITION_SCALE)
    )
  then
    return false, "bad_state"
  end
  if not self.entries[sender] then
    if self.count >= constants.POSITION_DIRECTORY_MAX then
      return false, "limit"
    end
    self.count = self.count + 1
  end
  self.entries[sender] = { map = decoded.map, x = decoded.x, y = decoded.y, at = self.deps.now() }
  changed(self)
  return true
end

-- Forgets a member. Returns true when there was one.
function PositionDirectory:Remove(sender)
  if not self.entries[sender] then
    return false
  end
  self.entries[sender] = nil
  self.count = self.count - 1
  changed(self)
  return true
end

-- Removes the entries older than the TTL. Returns true when something was removed.
function PositionDirectory:Prune()
  local now, removed = self.deps.now(), false
  for name, entry in pairs(self.entries) do
    if now - entry.at > ns.Constants.POSITION_TTL then
      self.entries[name] = nil
      self.count = self.count - 1
      removed = true
    end
  end
  if removed then
    changed(self)
  end
  return removed
end

-- The live entries as { name, map, x, y, at }, sorted by name.
function PositionDirectory:List()
  local now, list = self.deps.now(), {}
  for name, entry in pairs(self.entries) do
    if now - entry.at <= ns.Constants.POSITION_TTL then
      list[#list + 1] = { name = name, map = entry.map, x = entry.x, y = entry.y, at = entry.at }
    end
  end
  table.sort(list, function(a, b)
    return a.name < b.name
  end)
  return list
end

ns.PositionDirectory = PositionDirectory
