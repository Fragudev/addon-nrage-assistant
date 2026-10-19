local _, ns = ...

-- Runs a function at most once per interval: a call that comes too soon is postponed, once, to the end of the interval
-- (the last one wins, because the function reads the latest state when it runs). Used for the redraws that follow a
-- burst of events (the auras of the player, a snapshot).
--   deps: run(), now() -> seconds, schedule(delaySeconds, fn), interval (seconds)
local Throttle = {}
Throttle.__index = Throttle

function Throttle.New(deps)
  return setmetatable({
    run = deps.run,
    now = deps.now,
    schedule = deps.schedule,
    interval = deps.interval,
    lastAt = nil,
    pending = false,
  }, Throttle)
end

function Throttle:Call()
  local now = self.now()
  local wait = self.lastAt and (self.interval - (now - self.lastAt)) or 0
  if wait > 0 then
    if not self.pending then
      self.pending = true
      self.schedule(wait, function()
        self.pending = false
        self:Call()
      end)
    end
    return false
  end
  self.lastAt = now
  self.run()
  return true
end

ns.Throttle = Throttle
