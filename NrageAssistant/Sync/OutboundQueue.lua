local _, ns = ...

-- Every outgoing message goes through here. While the chat messaging lockdown is active the
-- message waits (bounded, with a TTL); once it ends the queue drains with random jitter so a
-- whole raid does not transmit in the same instant.
--   guard: needs :CanSend()          send: function(text, target) -> transmits (guild when no target)
--   now:   function() -> seconds     jitter: function(maxSeconds) -> seconds
local OutboundQueue = {}
OutboundQueue.__index = OutboundQueue

function OutboundQueue.New(options)
  local constants = ns.Constants
  return setmetatable({
    guard = options.guard,
    send = options.send,
    now = options.now,
    jitter = options.jitter or function(maxSeconds) return math.random() * maxSeconds end,
    maxItems = options.maxItems or constants.QUEUE_MAX_ITEMS,
    ttl = options.ttl or constants.QUEUE_TTL_SECONDS,
    maxJitter = options.maxJitter or constants.QUEUE_MAX_JITTER_SECONDS,
    items = {},
  }, OutboundQueue)
end

function OutboundQueue:Pending()
  return #self.items
end

-- True while messages are being held back by the lockdown.
function OutboundQueue:IsPaused()
  return #self.items > 0 and not self.guard:CanSend()
end

function OutboundQueue:DropExpired(now)
  local kept = {}
  for _, item in ipairs(self.items) do
    if now - item.queuedAt < self.ttl then
      kept[#kept + 1] = item
    end
  end
  self.items = kept
end

-- `key` (optional) replaces an older queued message with the same key, so a newer PROFILE
-- supersedes a stale one instead of both being sent. `target` (optional) is a whisper recipient.
-- Returns true, or false plus "full".
function OutboundQueue:Enqueue(text, key, target)
  local now = self.now()
  self:DropExpired(now)

  if key then
    for index, item in ipairs(self.items) do
      if item.key == key then
        table.remove(self.items, index)
        break
      end
    end
  end

  if #self.items >= self.maxItems then
    return false, "full"
  end

  local free = self.guard:CanSend()
  self.items[#self.items + 1] = {
    text = text,
    key = key,
    target = target,
    queuedAt = now,
    -- Sent right away when nothing blocks it; otherwise the jitter is drawn once the lockdown ends.
    readyAt = free and now or nil,
  }
  return true
end

-- Sends everything that is ready. Returns the number of messages sent, or 0 plus "paused".
function OutboundQueue:Flush()
  local now = self.now()
  self:DropExpired(now)

  if not self.guard:CanSend() then
    return 0, "paused"
  end

  local sent = 0
  local remaining = {}
  for _, item in ipairs(self.items) do
    if not item.readyAt then
      item.readyAt = now + self.jitter(self.maxJitter)
    end
    if item.readyAt <= now then
      local ok = pcall(self.send, item.text, item.target)
      if ok then
        sent = sent + 1
      end
    else
      remaining[#remaining + 1] = item
    end
  end
  self.items = remaining
  return sent
end

function OutboundQueue:Clear()
  self.items = {}
end

ns.OutboundQueue = OutboundQueue
