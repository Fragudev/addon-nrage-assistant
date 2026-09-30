local _, ns = ...

-- Guards applied to every received message before its content is used:
--   1. per-sender rate limit (fixed window), bounded number of tracked senders;
--   2. idempotency by (sender, message id) with a bounded cache of what was already seen.
-- `sender` must come from the client event, never from the payload.
local Inbox = {}
Inbox.__index = Inbox

function Inbox.New(options)
  local constants = ns.Constants
  options = options or {}
  return setmetatable({
    seenLimit = options.seenLimit or constants.INBOX_SEEN_LIMIT,
    maxPerWindow = options.maxPerWindow or constants.INBOX_MAX_PER_WINDOW,
    window = options.window or constants.INBOX_WINDOW_SECONDS,
    maxSenders = options.maxSenders or constants.INBOX_MAX_SENDERS,
    windows = {},
    senderCount = 0,
    seen = {},
    ring = {},
    ringStart = 1,
    ringSize = 0,
  }, Inbox)
end

function Inbox:PruneExpiredWindows(now)
  for sender, state in pairs(self.windows) do
    if now - state.start >= self.window then
      self.windows[sender] = nil
      self.senderCount = self.senderCount - 1
    end
  end
end

-- Counts one message from `sender`. Returns false when the sender is over its limit or the tracker
-- is full of active senders (new senders are refused rather than evicting old ones).
function Inbox:AllowRate(sender, now)
  local state = self.windows[sender]
  if state and now - state.start >= self.window then
    state = nil
    self.windows[sender] = nil
    self.senderCount = self.senderCount - 1
  end

  if not state then
    if self.senderCount >= self.maxSenders then
      self:PruneExpiredWindows(now)
      if self.senderCount >= self.maxSenders then
        return false
      end
    end
    state = { start = now, count = 0 }
    self.windows[sender] = state
    self.senderCount = self.senderCount + 1
  end

  if state.count >= self.maxPerWindow then
    return false
  end
  state.count = state.count + 1
  return true
end

-- Records the key and returns true if it is new, false if it was already seen.
function Inbox:MarkSeen(key)
  if self.seen[key] then
    return false
  end

  if self.ringSize >= self.seenLimit then
    local oldest = self.ring[self.ringStart]
    self.seen[oldest] = nil
    self.ring[self.ringStart] = nil
    self.ringStart = self.ringStart + 1
    self.ringSize = self.ringSize - 1
  end

  self.ring[self.ringStart + self.ringSize] = key
  self.ringSize = self.ringSize + 1
  self.seen[key] = true
  return true
end

-- Returns true, or false plus "bad_sender" | "rate_limited" | "duplicate".
function Inbox:Accept(sender, id, now)
  if type(sender) ~= "string" or sender == "" then
    return false, "bad_sender"
  end
  if not self:AllowRate(sender, now) then
    return false, "rate_limited"
  end
  if not self:MarkSeen(sender .. "\n" .. tostring(id)) then
    return false, "duplicate"
  end
  return true
end

ns.Inbox = Inbox
