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
