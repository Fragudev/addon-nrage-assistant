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

-- Rank name of the player in their own guild, or nil.
function Platform.GetOwnGuildRank()
  local _, rankName = GetGuildInfo("player")
  return rankName
end

-- Asks the server for a fresh guild roster; the answer arrives as GUILD_ROSTER_UPDATE.
function Platform.RequestGuildRoster()
  if C_GuildInfo and C_GuildInfo.GuildRoster then
    C_GuildInfo.GuildRoster()
  end
end

function Platform.GetNumGuildMembers()
  local total = GetNumGuildMembers()
  return total or 0
end

-- { name, rankName, rankIndex, level, class, guid } for roster row `index`, or nil.
function Platform.GetGuildRosterEntry(index)
  local name, rankName, rankIndex, level, _, _, _, _, _, _, class, _, _, _, _, _, guid = GetGuildRosterInfo(index)
  if not name then
    return nil
  end
  return { name = name, rankName = rankName, rankIndex = rankIndex, level = level, class = class, guid = guid }
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

-- "Name-Realm" built from UnitName. On Forever this is NOT the name the guild roster uses: character
-- names can have several words ("Yonemon Gg") and UnitName gives only the first one. Kept as the key of
-- the saved data of this character, which must not change; use GetIdentityKey for anything shared.
function Platform.GetLegacyIdentityKey()
  return ("%s-%s"):format(tostring(Platform.GetPlayerName()), tostring(Platform.GetRealmName()))
end

local canonicalName

-- Sets the full name of this character as the guild roster gives it (found by GUID once the roster has
-- loaded). Pass nil to go back to the UnitName-based key.
function Platform.SetCanonicalName(name)
  canonicalName = name
end

-- The name other members and the guild roster know this character by: the roster's full name without a
-- realm suffix, as soon as it is known; until then the UnitName-based key.
function Platform.GetIdentityKey()
  return canonicalName or Platform.GetLegacyIdentityKey()
end

-- Drops a "-<this realm>" suffix, so a name received as "Name-Realm" and one from the roster ("Name")
-- compare equal. Names from another realm keep their suffix. Not a string: returned unchanged.
function Platform.NormalizeName(name)
  if type(name) ~= "string" then
    return name
  end
  local realm = Platform.GetRealmName()
  if type(realm) == "string" and realm ~= "" then
    local suffix = "-" .. realm
    if #name > #suffix and name:sub(-#suffix) == suffix then
      return name:sub(1, #name - #suffix)
    end
  end
  return name
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

-- The icon texture of an item, from whichever API this client offers (they differ between clients and none is
-- confirmed on Forever yet), or a question mark when the client does not know the item. An item that is not in
-- the client's cache may have no icon until it is seen once.
Platform.ITEM_FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

function Platform.GetItemIcon(itemId)
  if type(itemId) ~= "number" then
    return Platform.ITEM_FALLBACK_ICON
  end
  -- Only the APIs this client has, in order of preference (a nil in the middle would end an ipairs).
  local lookups = {}
  if C_Item and C_Item.GetItemIconByID then
    lookups[#lookups + 1] = C_Item.GetItemIconByID
  end
  if GetItemIcon then
    lookups[#lookups + 1] = GetItemIcon
  end
  if GetItemInfoInstant then
    lookups[#lookups + 1] = function(id)
      return select(5, GetItemInfoInstant(id))
    end
  end
  for _, lookup in ipairs(lookups) do
    local ok, icon = pcall(lookup, itemId)
    if ok and icon then
      return icon
    end
  end
  return Platform.ITEM_FALLBACK_ICON
end

-- The client's interface number (build 16001 on the Forever beta).
function Platform.GetBuildNumber()
  return select(4, GetBuildInfo())
end

-- "2026-10-01 20:30" in the client's local time.
function Platform.FormatDate(timestamp)
  return date("%Y-%m-%d %H:%M", timestamp)
end

-- "2026-10-01 20:30" (local time) -> timestamp, or nil when the text is not a real date and time.
-- A date that would roll over (2026-02-31) is refused instead of silently becoming March.
function Platform.ParseDate(text)
  if type(text) ~= "string" then
    return nil
  end
  local year, month, day, hour, minute = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)%s+(%d%d):(%d%d)$")
  if not year then
    return nil
  end
  local timestamp = time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(minute),
  })
  if not timestamp then
    return nil
  end
  local expected = ("%s-%s-%s %s:%s"):format(year, month, day, hour, minute)
  if date("%Y-%m-%d %H:%M", timestamp) ~= expected then
    return nil
  end
  return timestamp
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
