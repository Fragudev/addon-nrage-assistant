local _, ns = ...

-- Tells the guild the own layer: when it changes, and again every Constants.LAYER_REPUBLISH_SECONDS (so a member
-- who logs in later learns it), never more than once per Constants.LAYER_PUBLISH_MIN_SECONDS. Turning sharing off
-- sends one `layer = 0` ("forget me"). Nothing here touches the client; everything is injected.
--
-- deps = { now = function() -> seconds (monotonic), schedule = function(delay, fn),
--          send = function(payload) -> ok, current = function() -> { map, layer, zone } or nil,
--          enabled = function() -> boolean (the "Share my layer" setting) }
local LayerPublisher = {}
LayerPublisher.__index = LayerPublisher

function LayerPublisher.New(deps)
  return setmetatable({ deps = deps, lastSentAt = nil, pending = false, published = false }, LayerPublisher)
end

local function sendPayload(self, payload)
  local ok, sent = pcall(self.deps.send, payload)
  return ok and sent == true
end

-- Sends the current layer now when the throttle allows. Returns true when a message went out.
function LayerPublisher:Flush()
  if not self.deps.enabled() then
    return false
  end
  local current = self.deps.current()
  if not current then
    return false
  end
  local now = self.deps.now()
  if self.lastSentAt and now - self.lastSentAt < ns.Constants.LAYER_PUBLISH_MIN_SECONDS then
    return false
  end
  if not sendPayload(self, { map = current.map, layer = current.layer, zone = current.zone }) then
    return false
  end
  self.lastSentAt = now
  self.published = true
  return true
end

-- The own layer changed, or sharing was switched on: send it, or at the end of the throttle window.
function LayerPublisher:Changed()
  if not (self.deps.enabled() and self.deps.current()) or self.pending then
    return
  end
  if self:Flush() then
    return
  end
  local wait = ns.Constants.LAYER_PUBLISH_MIN_SECONDS
  if self.lastSentAt then
    wait = math.max(0, ns.Constants.LAYER_PUBLISH_MIN_SECONDS - (self.deps.now() - self.lastSentAt))
  end
  self.pending = true
  self.deps.schedule(wait, function()
    self.pending = false
    self:Flush()
  end)
end

-- The periodic republication; a no-op while sharing is off or the layer is unknown.
function LayerPublisher:Tick()
  self:Flush()
end

-- Sharing was switched off: tell the guild once to forget this member. Not throttled, because it is a privacy action.
function LayerPublisher:Forget()
  -- Sent whatever the flag says: after a /reload it is false until the first publish, yet the guild still holds the
  -- last one. It is a rare, user-driven action.
  if sendPayload(self, { map = 0, layer = 0 }) then
    self.published = false
    self.lastSentAt = nil
    return true
  end
  return false
end

ns.LayerPublisher = LayerPublisher
