local _, ns = ...

-- Single seam over the WoW client API. Everything else asks Platform, so specs can
-- substitute a fake and API changes between Mainline and Forever stay in one file.
local Platform = {}

function Platform.IsInGuild()
  return IsInGuild() and true or false
end

function Platform.GetGuildClubId()
  if C_Club and C_Club.GetGuildClubId then
    return C_Club.GetGuildClubId()
  end
  return nil
end

function Platform.GetGuildName()
  local name = GetGuildInfo("player")
  return name
end

function Platform.GetFaction()
  local faction = UnitFactionGroup("player")
  return faction
end

function Platform.GetRealmName()
  return GetNormalizedRealmName()
end

function Platform.IsChatMessagingLockedDown()
  if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
    return C_ChatInfo.InChatMessagingLockdown() and true or false
  end
  return false
end

function Platform.GetPlayerName()
  local name = UnitName("player")
  return name
end

-- "Name-Realm", the same shape the guild roster uses (confirmed in phase 0: realm is
-- the normalized realm name).
function Platform.GetIdentityKey()
  return ("%s-%s"):format(tostring(Platform.GetPlayerName()), tostring(Platform.GetRealmName()))
end

function Platform.GetGUID()
  return UnitGUID("player")
end

-- Returns the class file token (e.g. "WARRIOR"), which does not depend on the client locale.
function Platform.GetClass()
  local _, token = UnitClass("player")
  return token
end

function Platform.GetLevel()
  return UnitLevel("player")
end

-- Equipped item level, or nil when the API is missing or returns something unusable.
function Platform.GetAverageItemLevel()
  if not GetAverageItemLevel then
    return nil
  end
  local _, equipped = GetAverageItemLevel()
  if type(equipped) ~= "number" then
    return nil
  end
  return math.floor(equipped)
end

-- List of { name, skill, max }; empty when the client has no profession API.
function Platform.GetProfessions()
  local result = {}
  if not (GetProfessions and GetProfessionInfo) then
    return result
  end
  -- Up to five slots (two primary, archaeology, fishing, cooking); empty slots are nil.
  local indexes = { GetProfessions() }
  for slot = 1, 5 do
    if indexes[slot] then
      local name, _, skill, maxSkill = GetProfessionInfo(indexes[slot])
      if name then
        result[#result + 1] = { name = name, skill = skill, max = maxSkill }
      end
    end
  end
  return result
end

function Platform.ServerTime()
  return GetServerTime()
end

function Platform.Now()
  return GetTime()
end

function Platform.WallClock()
  return date("%H:%M:%S")
end

function Platform.RegisterPrefix(prefix)
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    return C_ChatInfo.RegisterAddonMessagePrefix(prefix)
  end
  return false
end

function Platform.SendGuildMessage(prefix, text)
  return C_ChatInfo.SendAddonMessage(prefix, text, "GUILD")
end

ns.Platform = Platform
