local _, ns = ...

-- Gate: the addon only activates for Nrage members on the Alliance side of the PvP ruleset.
local AccessGuard = {}

-- Returns true, or false plus a reason code:
-- "not_in_guild" | "wrong_guild" | "wrong_faction" | "wrong_ruleset" | "pending"
-- "pending" means the client has not given a value yet, which happens around login: nothing is known either way.
function AccessGuard.Evaluate(platform, constants)
  if not platform.IsInGuild() then
    return false, "not_in_guild"
  end

  if constants.GUILD_CLUB_ID then
    local clubId = platform.GetGuildClubId()
    if clubId == nil then
      return false, "pending"
    end
    if clubId ~= constants.GUILD_CLUB_ID then
      return false, "wrong_guild"
    end
  else
    local name = platform.GetGuildName()
    if name == nil then
      return false, "pending"
    end
    if name ~= constants.GUILD_NAME then
      return false, "wrong_guild"
    end
  end

  local faction = platform.GetFaction()
  if faction == nil then
    return false, "pending"
  end
  if faction ~= constants.FACTION then
    return false, "wrong_faction"
  end

  local realm = platform.GetRealmName()
  if realm == nil or realm == "" then
    return false, "pending"
  end
  if not realm:find(constants.RULESET_REALM_MARKER, 1, true) then
    return false, "wrong_ruleset"
  end

  return true
end

-- The client can also report "not in a guild" for a moment, at login or on a loading screen, so that answer is not
-- trusted until it holds.
local INCONCLUSIVE = { pending = true, not_in_guild = true }

local Monitor = {}
Monitor.__index = Monitor

-- Decides when the addon turns on and off, waiting out the answers that may still change.
-- deps = { evaluate = function() -> ok, reason,
--          isActive = function() -> boolean,
--          activate = function(),
--          deactivate = function(reason),
--          schedule = function(seconds, fn),
--          onWait = function() (optional: runs on every wait, to ask the client for the data),
--          retrySeconds, retryMax }
function AccessGuard.NewMonitor(deps)
  return setmetatable({ deps = deps, attempts = 0, waiting = false }, Monitor)
end

function Monitor:Check()
  local deps = self.deps
  local ok, reason = deps.evaluate()
  if ok then
    self.attempts = 0
    if not deps.isActive() then
      deps.activate()
    end
    return
  end
  if INCONCLUSIVE[reason] and self.attempts < deps.retryMax then
    self:Wait()
    return
  end
  deps.deactivate(reason)
end

-- One retry at a time, however many events arrive while it waits.
function Monitor:Wait()
  if self.waiting then
    return
  end
  self.waiting = true
  if self.deps.onWait then
    self.deps.onWait()
  end
  self.deps.schedule(self.deps.retrySeconds, function()
    self.waiting = false
    self.attempts = self.attempts + 1
    self:Check()
  end)
end

ns.AccessGuard = AccessGuard
