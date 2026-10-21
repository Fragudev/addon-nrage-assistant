local _, ns = ...

-- Tells the guild the own map position: on each tick when it moved, when the map changed, or after
-- Constants.POSITION_HEARTBEAT_SECONDS, never more than one message per Constants.POSITION_TICK_SECONDS. When the
-- position disappears (an instance, a loading screen) after one was sent, it sends one "forget me"; switching sharing
-- off sends another one at once. Nothing here touches the client; everything is injected.
--
-- deps = { now = function() -> seconds (monotonic),
--          current = function() -> { map, x, y } (x and y integers 0..10000) or nil,
--          enabled = function() -> boolean (the "Share my position" setting),
--          canSend = function() -> boolean (false during the encounter lockdown),
--          send = function(text) -> ok }
local PositionPublisher = {}
PositionPublisher.__index = PositionPublisher

function PositionPublisher.New(deps)
  return setmetatable({ deps = deps, last = nil, lastAt = nil, published = false }, PositionPublisher)
end

local function sendText(self, text)
  local ok, sent = pcall(self.deps.send, text)
  return ok and sent == true
end

local function canSend(self)
  local ok, allowed = pcall(self.deps.canSend)
  return ok and allowed == true
end

-- Sends "forget me" and clears what was published. Returns true when the message went out.
local function forget(self)
  if not sendText(self, ns.PositionModel.EncodeForget()) then
    return false
  end
  self.published = false
  self.last = nil
  self.lastAt = nil
  return true
end

-- The periodic check. Returns true when a message went out.
function PositionPublisher:Tick()
  if not (self.deps.enabled() and canSend(self)) then
    return false
  end
  local now = self.deps.now()
  if self.lastAt and now - self.lastAt < ns.Constants.POSITION_TICK_SECONDS then
    return false
  end
  local current = self.deps.current()
  if not current then
    -- The position is gone: the guild is told once.
    return self.published and forget(self)
  end
  local due = self.last == nil
    or ns.PositionModel.Moved(self.last, current)
    or now - self.lastAt >= ns.Constants.POSITION_HEARTBEAT_SECONDS
  if not due then
    return false
  end
  local text = ns.PositionModel.Encode(current)
  if not (text and sendText(self, text)) then
    return false
  end
  self.last = { map = current.map, x = current.x, y = current.y }
  self.lastAt = now
  self.published = true
  return true
end

-- Sharing was switched off: tell the guild once to forget this member. Not throttled, because it is a privacy action.
function PositionPublisher:Forget()
  if not self.published then
    return false
  end
  return forget(self)
end

ns.PositionPublisher = PositionPublisher
