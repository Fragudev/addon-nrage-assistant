local _, ns = ...

-- Decides when the own PvP counters are sent to the guild. Nothing here touches the client: the clocks, the
-- timer and the transport are injected, so the rules are tested with fakes.
--
--   * A change of the counters schedules one send, no sooner than PVP_SYNC_MIN_DELAY_SECONDS (a burst of kills
--     is one message) and no more often than every PVP_SYNC_INTERVAL_SECONDS. Changes that arrive while a send
--     is scheduled are sent by it, so they coalesce; the send reads the counters when it fires.
--   * Once after login the counters are sent after a random delay, unless there is nothing to tell yet.
--   * Every message carries the next revision, kept in the saved data of the character (`sync.rev`).
--     A send that fails does not use up a revision.
--
-- deps = { sync = char.pvpSync ({ rev }), stats = the saved counters, send = function(payload) -> ok,
--          now = function() -> seconds (monotonic), serverTime = function() -> seconds,
--          day = function() -> "YYYY-MM-DD" or nil, blowsAvailable = function() -> boolean,
--          schedule = function(delaySeconds, fn), random = function(low, high) -> number }
local PvPPublisher = {}
PvPPublisher.__index = PvPPublisher

function PvPPublisher.New(deps)
  return setmetatable({
    deps = deps,
    dirty = false,
    pending = false,
    lastSentAt = nil,
  }, PvPPublisher)
end

function PvPPublisher:Schedule()
  if self.pending then
    return
  end
  local constants = ns.Constants
  local now = self.deps.now()
  local delay = constants.PVP_SYNC_MIN_DELAY_SECONDS
  if self.lastSentAt then
    delay = math.max(delay, self.lastSentAt + constants.PVP_SYNC_INTERVAL_SECONDS - now)
  end
  self.pending = true
  self.deps.schedule(delay, function()
    self.pending = false
    self:Send()
  end)
end

-- The counters changed.
function PvPPublisher:Changed()
  self.dirty = true
  self:Schedule()
end

-- Sends the counters when something changed since the last send. Returns true, or false plus
-- "unchanged" | "no_day" | the reason the transport gave.
function PvPPublisher:Send()
  if not self.dirty then
    return false, "unchanged"
  end
  local deps = self.deps
  local day = deps.day()
  if not day then
    -- No server day yet: try again later, the counters stay dirty.
    self:Schedule()
    return false, "no_day"
  end

  local rev = deps.sync.rev + 1
  local payload = ns.PvPSync.OwnPayload(deps.stats, rev, deps.serverTime(), day, deps.blowsAvailable())
  local ok, reason = deps.send(payload)
  -- A failure is retried at the pace of the interval, not at once.
  self.lastSentAt = deps.now()
  if not ok then
    self:Schedule()
    return false, reason
  end
  deps.sync.rev = rev
  self.dirty = false
  return true
end

local function hasCounts(stats)
  local totals = ns.PvPService.Totals(stats)
  return totals.honor.total > 0 or totals.blows.total > 0
end

-- Schedules the one send after login. Skipped when a send already happened by then, and when this character
-- has nothing to tell (no kills, never published).
function PvPPublisher:SendAtLogin()
  local constants = ns.Constants
  local delay = self.deps.random(constants.PVP_LOGIN_SEND_DELAY_MIN, constants.PVP_LOGIN_SEND_DELAY_MAX)
  self.deps.schedule(delay, function()
    if self.lastSentAt == nil and (self.deps.sync.rev > 0 or hasCounts(self.deps.stats)) then
      self.dirty = true
      self:Send()
    end
  end)
end

-- An admin reset this character: the next revision has to be above the one of the reset, and the zeroed
-- counters are told to the guild.
function PvPPublisher:OnReset(rev)
  local sync = self.deps.sync
  sync.rev = math.max(sync.rev, rev)
  self:Changed()
end

ns.PvPPublisher = PvPPublisher
