local _, ns = ...

-- Reads the sightings of enemy players the guild shares (prefix Constants.INTEL_PREFIX, see docs/PROTOCOL.md). They do
-- not go through the NRAGE envelope: a message is a short strict text (IntelModel.DecodeSighting), so there is no
-- decoder to attack, and the seen cache of the main inbox is not shared with them. Every byte is hostile: the sender is
-- the one the client reported, never anything from the text, and whether the sender may share comes from the receiver's
-- own guild roster. A message from somebody who is not in the guild (a battleground group mate) has no role and is
-- dropped.
--
-- deps = { platform, inbox = a dedicated Inbox (rate only, never MarkSeen), roleOf = function(sender) -> role or nil,
--          directory = IntelDirectory, now = function() -> seconds (monotonic) }
local IntelSync = {}
IntelSync.__index = IntelSync

-- Where a sighting may arrive from: the guild in the open world, the group in a battleground.
IntelSync.CHANNELS = { GUILD = true, RAID = true, PARTY = true, INSTANCE_CHAT = true }

function IntelSync.New(deps)
  return setmetatable({
    platform = deps.platform,
    inbox = deps.inbox,
    roleOf = deps.roleOf,
    directory = deps.directory,
    now = deps.now,
    received = 0,
    drops = {},
  }, IntelSync)
end

local function drop(self, reason)
  self.drops[reason] = (self.drops[reason] or 0) + 1
  return false, reason
end

-- The whole pipeline, cheapest check first. Returns true, or false plus the reason the message was dropped:
-- "wrong_channel" | "bad_sender" | "own_message" | "rate_limited" | "unknown_sender" | "forbidden" | "too_long" |
-- "bad_format" | "out_of_range" | the reason of the directory.
function IntelSync:Handle(text, channel, sender)
  if not IntelSync.CHANNELS[channel] then
    return drop(self, "wrong_channel")
  end
  if type(sender) ~= "string" or sender == "" then
    return drop(self, "bad_sender")
  end
  -- The client may deliver "Name-Realm" where the guild roster has "Name": compare without the realm.
  sender = self.platform.NormalizeName(sender)
  if sender == self.platform.GetIdentityKey() then
    return drop(self, "own_message")
  end
  if not self.inbox:AllowRate(sender, self.now()) then
    return drop(self, "rate_limited")
  end
  local denied = ns.SyncRules.Authorize(self.roleOf(sender), "intel_share")
  if denied then
    return drop(self, denied)
  end
  local decoded, reason = ns.IntelModel.DecodeSighting(text)
  if not decoded then
    return drop(self, reason)
  end
  local ok, why = self.directory:Apply(sender, decoded)
  if not ok then
    return drop(self, why)
  end
  self.received = self.received + 1
  return true
end

ns.IntelSync = IntelSync
