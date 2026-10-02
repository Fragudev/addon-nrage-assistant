local _, ns = ...

-- Warns about blacklisted players in the group. Nothing here touches the client: the group, the own names and the
-- warning itself are injected, so the rules are tested with fakes.
--
-- Check() compares the members of the group with the blacklist and calls `alert` for each match that has not been
-- warned about yet; a player is warned about once per group. The memory is cleared when the player is no longer
-- in a group, so the same player in the next group warns again. The player is never warned about themselves.
--
-- deps = { blacklist = db.global.blacklist, isGrouped = function() -> boolean,
--          members = function() -> list of names, ownNames = function() -> list of names (every spelling of the own
--          name: the full one and the one UnitName gives), alert = function(match) }
local BlacklistWatcher = {}
BlacklistWatcher.__index = BlacklistWatcher

function BlacklistWatcher.New(deps)
  return setmetatable({ deps = deps, alerted = {} }, BlacklistWatcher)
end

-- The keys under which the player is known to themselves: each name, and its first word (what UnitName gives).
function BlacklistWatcher:OwnKeys()
  local keys = {}
  for _, name in ipairs(self.deps.ownNames()) do
    local key = ns.BlacklistService.Key(name)
    if key then
      keys[key] = true
    end
    local first = type(name) == "string" and ns.BlacklistService.FirstWord(name)
    if first then
      keys[ns.BlacklistService.Key(first)] = true
    end
  end
  return keys
end

-- Looks at the group now. Returns the matches that were warned about this time.
function BlacklistWatcher:Check()
  local deps = self.deps
  if not deps.isGrouped() then
    self.alerted = {}
    return {}
  end
  if next(deps.blacklist) == nil then
    return {}
  end

  local own = self:OwnKeys()
  local warned = {}
  for _, match in ipairs(ns.BlacklistService.Match(deps.blacklist, deps.members())) do
    local member = ns.BlacklistService.Key(match.member)
    if not own[member] and not self.alerted[member] then
      self.alerted[member] = true
      warned[#warned + 1] = match
      -- A failing alert must not stop the others.
      pcall(deps.alert, match)
    end
  end
  return warned
end

ns.BlacklistWatcher = BlacklistWatcher
