local _, ns = ...

-- Tracks the chat messaging lockdown (active during encounters). Sending must be gated on
-- CanSend(); Poll() and Note() build a timeline used to measure when the lockdown starts and ends.
local LockdownGuard = {}
LockdownGuard.__index = LockdownGuard

local MAX_LOG = 200

function LockdownGuard.New(platform)
  return setmetatable({
    platform = platform,
    locked = platform.IsChatMessagingLockedDown(),
    context = "init",
    log = {},
  }, LockdownGuard)
end

-- Always asks the client: the cached state is only for detecting transitions.
function LockdownGuard:CanSend()
  return not self.platform.IsChatMessagingLockedDown()
end

function LockdownGuard:Append(kind, detail)
  local log = self.log
  log[#log + 1] = {
    t = self.platform.Now(),
    wall = self.platform.WallClock(),
    kind = kind,
    detail = detail,
    locked = self.locked,
  }
  if #log > MAX_LOG then
    table.remove(log, 1)
  end
end

-- Records a client event (encounter start/end, combat, zone change) as context for transitions.
function LockdownGuard:Note(context)
  self.context = context
  self:Append("event", context)
end

-- Returns true when the lockdown state changed since the previous call.
function LockdownGuard:Poll()
  local locked = self.platform.IsChatMessagingLockedDown()
  if locked == self.locked then
    return false
  end
  self.locked = locked
  self:Append("lockdown", (locked and "started" or "ended") .. " after " .. self.context)
  return true
end

function LockdownGuard:Record(kind, detail)
  self:Append(kind, detail)
end

function LockdownGuard:GetLog()
  return self.log
end

function LockdownGuard:Clear()
  self.log = {}
end

ns.LockdownGuard = LockdownGuard
