local _, ns = ...

-- Publishes the own profile by itself (plan 0.1): when something that is shared changes (gear, level, professions) it
-- waits a few seconds for the changes to settle, refreshes the profile and publishes it if it differs from what was
-- last sent. A change made inside the publish cooldown is never lost: one retry is scheduled for when the cooldown
-- ends (one pending timer, however many changes arrive). During an encounter lockdown it waits and tries again.
--   deps: refresh() reads the profile again, publish() -> ok, reason (PublishService.PublishIfChanged),
--         cooldownLeft() -> seconds until a publication is allowed, schedule(delaySeconds, fn),
--         isLocked() -> boolean (optional), debounce (seconds, default 3)
local AutoPublisher = {}
AutoPublisher.__index = AutoPublisher

local LOCK_RETRY_SECONDS = 5
local RETRY_MARGIN_SECONDS = 1

function AutoPublisher.New(deps)
  return setmetatable({
    refresh = deps.refresh,
    publish = deps.publish,
    cooldownLeft = deps.cooldownLeft,
    schedule = deps.schedule,
    isLocked = deps.isLocked,
    debounce = deps.debounce or 3,
    armed = false,
  }, AutoPublisher)
end

-- Is a timer waiting? There is never more than one.
function AutoPublisher:IsPending()
  return self.armed
end

function AutoPublisher:Arm(delay)
  if self.armed then
    return
  end
  self.armed = true
  self.schedule(delay, function()
    self.armed = false
    self:Run()
  end)
end

-- Reads the profile again and publishes it when it changed. Returns what the publication said.
function AutoPublisher:Run()
  if self.isLocked and self.isLocked() then
    self:Arm(LOCK_RETRY_SECONDS)
    return false, "locked"
  end
  self.refresh()
  local ok, reason = self.publish()
  if reason == "cooldown" then
    self:Arm(math.max(self.cooldownLeft(), 0) + RETRY_MARGIN_SECONDS)
  end
  return ok, reason
end

-- Something that is shared may have changed (an equipment, level or profession event). Bursts of events count once.
function AutoPublisher:Changed()
  self:Arm(self.debounce)
end

ns.AutoPublisher = AutoPublisher
