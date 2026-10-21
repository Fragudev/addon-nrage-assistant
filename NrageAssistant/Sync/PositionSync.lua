local _, ns = ...

-- Reads the position messages of the guild (prefix Constants.POSITION_PREFIX, see docs/PROTOCOL.md). They do not go
-- through the NRAGE envelope: a message is a short strict text, so there is no decoder to attack, and the seen cache
-- of the main inbox is not shared with them. Every byte is hostile: the sender is the one the client reported, never
-- anything from the text.
--
-- deps = { platform, inbox = a dedicated Inbox (rate only, never MarkSeen), roleOf = function(sender) -> role or nil,
--          directory = PositionDirectory, now = function() -> seconds (monotonic) }
local PositionSync = {}
PositionSync.__index = PositionSync

function PositionSync.New(deps)
  return setmetatable({
    platform = deps.platform,
    inbox = deps.inbox,
    roleOf = deps.roleOf,
    directory = deps.directory,
    now = deps.now,
  }, PositionSync)
end

-- The whole pipeline, cheapest check first. Returns true, or false plus the reason the message was dropped:
-- "wrong_channel" | "bad_sender" | "own_message" | "rate_limited" | "unknown_sender" | "forbidden" | "too_long" |
-- "bad_format" | "out_of_range" | the reason of the directory.
function PositionSync:Handle(text, channel, sender)
  if channel ~= "GUILD" then
    return false, "wrong_channel"
  end
  if type(sender) ~= "string" or sender == "" then
    return false, "bad_sender"
  end
  -- The client may deliver "Name-Realm" where the guild roster has "Name": compare without the realm.
  sender = self.platform.NormalizeName(sender)
  if sender == self.platform.GetIdentityKey() then
    return false, "own_message"
  end
  if not self.inbox:AllowRate(sender, self.now()) then
    return false, "rate_limited"
  end
  local denied = ns.SyncRules.Authorize(self.roleOf(sender), "position_share")
  if denied then
    return false, denied
  end
  local decoded, reason = ns.PositionModel.Decode(text)
  if not decoded then
    return false, reason
  end
  return self.directory:Apply(sender, decoded)
end

ns.PositionSync = PositionSync
