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

-- Rank name of the player in their own guild, then the rank index (0 is the guild master), or nil.
-- The index is the third value of GetGuildInfo; whether Forever returns it is not measured yet (API_NOTES).
function Platform.GetOwnGuildRank()
  local _, rankName, rankIndex = GetGuildInfo("player")
  if type(rankIndex) ~= "number" then
    rankIndex = nil
  end
  return rankName, rankIndex
end

-- The rank names of the player's guild as { [rankIndex] = name }, with 0 for the guild master. Assumes that
-- `GuildControlGetRankName(i)` is 1-based and maps to rankIndex `i - 1`, the index GetGuildRosterInfo and GetGuildInfo
-- give (M10 in docs/API_NOTES.md, not measured yet). {} when the client cannot say.
function Platform.GetGuildRanks()
  local ranks = {}
  -- Read through _G: these two are not in the luacheck client list and nothing else uses them.
  local getNumRanks, getRankName = _G.GuildControlGetNumRanks, _G.GuildControlGetRankName
  if not (getNumRanks and getRankName) then
    return ranks
  end
  local ok, total = pcall(getNumRanks)
  if not ok or type(total) ~= "number" then
    return ranks
  end
  for position = 1, total do
    local named, name = pcall(getRankName, position)
    if named and type(name) == "string" and name ~= "" then
      ranks[position - 1] = name
    end
  end
  return ranks
end

-- true when the client says the player is the guild master, false when it says not, nil when it cannot say
-- (no such API, or it raised). Not measured on Forever yet (API_NOTES); the rank index is the primary source.
function Platform.IsGuildLeader()
  if not IsGuildLeader then
    return nil
  end
  local ok, leader = pcall(IsGuildLeader)
  if not ok or type(leader) ~= "boolean" then
    return nil
  end
  return leader
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

-- { name, rankName, rankIndex, level, class, guid, online } for roster row `index`, or nil. `online` is the ninth
-- value of GetGuildRosterInfo (isOnline); it is nil when the client does not give a boolean there.
function Platform.GetGuildRosterEntry(index)
  local name, rankName, rankIndex, level, _, _, _, _, online, _, class, _, _, _, _, _, guid = GetGuildRosterInfo(index)
  if not name then
    return nil
  end
  if type(online) ~= "boolean" then
    online = nil
  end
  return {
    name = name,
    rankName = rankName,
    rankIndex = rankIndex,
    level = level,
    class = class,
    guid = guid,
    online = online,
  }
end

function Platform.GetFaction()
  local faction = UnitFactionGroup("player")
  return faction
end

-- The normalized realm name. WoW Forever now blanks it ("" or nothing), so the home realm of the guild stands in:
-- it keeps the keys built from the realm (the saved data of each character, the rank map of the guild) as they were.
-- Nil when the client gives nothing and there is no home realm.
function Platform.GetRealmName()
  local realm = GetNormalizedRealmName()
  if type(realm) == "string" and realm ~= "" then
    return realm
  end
  return ns.Constants and ns.Constants.HOME_REALM or nil
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

-- List of { name, skill, max, secondary }; empty when the client has no profession API. `secondary` is true for
-- the slots after the two primary ones (archaeology, fishing, cooking). Whether Forever fills those slots is not
-- measured yet (API_NOTES): when it does not, only the primary professions are listed.
-- The icon of each profession seen on this client, by name, so a profession read from another member's profile can
-- show the same icon. Icons are local only: they are never part of a published profile.
local professionIcons = {}

function Platform.ProfessionIcon(name)
  return professionIcons[name]
end

function Platform.GetProfessions()
  local result = {}
  if not (GetProfessions and GetProfessionInfo) then
    return result
  end
  -- Up to five slots (two primary, archaeology, fishing, cooking); empty slots are nil.
  local ok, indexes = pcall(function()
    return { GetProfessions() }
  end)
  if not ok then
    return result
  end
  for slot = 1, 5 do
    if indexes[slot] then
      local read, name, icon, skill, maxSkill = pcall(GetProfessionInfo, indexes[slot])
      if read and name and type(skill) == "number" then
        if type(icon) ~= "number" and type(icon) ~= "string" then
          icon = nil
        end
        if icon ~= nil then
          professionIcons[name] = icon
        end
        result[#result + 1] = { name = name, icon = icon, skill = skill, max = maxSkill, secondary = slot > 2 or nil }
      end
    end
  end
  return result
end

-- Equipment slots 1..19 (head to ranged); the shirt (4) and tabard (19) never carry an enchant.
local ENCHANT_SLOT_FIRST, ENCHANT_SLOT_LAST = 1, 18

-- Enchant id of every equipped item, as { [slot] = enchantId } (0 means not enchanted). A slot with no item,
-- or whose link is unreadable (secret, or an unexpected format), is left out: unknown, never a guess.
-- Returns nil when the client has no such API.
function Platform.GetEquippedEnchants()
  if not GetInventoryItemLink then
    return nil
  end
  local result = {}
  for slot = ENCHANT_SLOT_FIRST, ENCHANT_SLOT_LAST do
    local ok, enchantId = pcall(function()
      local link = GetInventoryItemLink("player", slot)
      if type(link) ~= "string" then
        return nil
      end
      -- |Hitem:itemId:enchantId:...
      local id = link:match("|Hitem:%d+:(%d*)")
      if id == nil then
        return nil
      end
      return tonumber(id) or 0
    end)
    if ok and enchantId then
      result[slot] = enchantId
    end
  end
  return result
end

-- Active buffs of the player as a list of { name, spellId }. Entries the client hides (secret values) are
-- dropped. Returns nil when the client has no buff API.
local MAX_BUFFS = 40

function Platform.GetActiveBuffs()
  if not UnitBuff then
    return nil
  end
  local result = {}
  for index = 1, MAX_BUFFS do
    local ok, name, spellId = pcall(function()
      local buffName, _, _, _, _, _, _, _, _, id = UnitBuff("player", index)
      return buffName, id
    end)
    if not ok then
      break
    end
    if name == nil then
      break
    end
    if type(name) == "string" and type(spellId) == "number" then
      result[#result + 1] = { name = name, spellId = spellId }
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

-- What the client knows about an item: { level = item level, slot = "Two-Hand", ... } with only what it
-- reports, or nil when it does not know the item (not cached yet) or has no such API. Nothing is guessed.
function Platform.GetItemDetails(itemId)
  if type(itemId) ~= "number" then
    return nil
  end
  local lookup = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not lookup then
    return nil
  end
  local ok, _, _, _, level, _, _, _, _, equipLoc = pcall(lookup, itemId)
  if not ok then
    return nil
  end
  local details = {}
  if type(level) == "number" and level > 0 then
    details.level = level
  end
  if type(equipLoc) == "string" and equipLoc ~= "" then
    local text = _G[equipLoc]
    details.slot = type(text) == "string" and text or nil
  end
  return next(details) and details or nil
end

-- The name the client gives a spell in its own language, or nil (no such API, unknown spell, not a string).
function Platform.GetSpellName(spellId)
  if type(spellId) ~= "number" then
    return nil
  end
  local ok, name = pcall(function()
    if C_Spell and C_Spell.GetSpellInfo then
      local spell = C_Spell.GetSpellInfo(spellId)
      return spell and spell.name
    elseif GetSpellInfo then
      return (GetSpellInfo(spellId))
    end
  end)
  if ok and type(name) == "string" and name ~= "" then
    return name
  end
  return nil
end

-- The client's interface number (build 16001 on the Forever beta).
-- The client's locale code ("enUS", "esES"...); "enUS" when the client does not say.
function Platform.GetLocale()
  return GetLocale and GetLocale() or "enUS"
end

function Platform.GetBuildNumber()
  return select(4, GetBuildInfo())
end

-- "2026-10-01 20:30" in the client's local time.
function Platform.FormatDate(timestamp)
  return date("%Y-%m-%d %H:%M", timestamp)
end

-- "20:30" in the client's local time.
function Platform.FormatClock(timestamp)
  return date("%H:%M", timestamp)
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

-- "YYYY-MM-DD" of a server timestamp in UTC (the "!" prefix), or nil when it cannot be formatted. UTC and not
-- the local time zone, so every member agrees on where a day starts and ends.
function Platform.ServerDay(timestamp)
  if type(timestamp) ~= "number" then
    return nil
  end
  local ok, day = pcall(date, "!%Y-%m-%d", timestamp)
  if ok and type(day) == "string" then
    return day
  end
  return nil
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

-- PvP. None of these APIs is measured on Forever yet (issue #99), so each one is guarded: a missing API, an
-- error or a secret value (which raises when compared) gives nil and the caller treats the data as unavailable.

-- Honourable kills of this session, from the first value of GetPVPSessionStats, or nil.
function Platform.GetPvPSessionKills()
  if not GetPVPSessionStats then
    return nil
  end
  local ok, kills = pcall(GetPVPSessionStats)
  if not ok or type(kills) ~= "number" then
    return nil
  end
  -- The comparison is the probe for a secret value: it raises on one.
  local readable, whole = pcall(function()
    return kills >= 0 and kills % 1 == 0
  end)
  if readable and whole then
    return kills
  end
  return nil
end

-- true in a battleground (instance type "pvp"), false anywhere else, nil when the client does not say.
function Platform.IsInBattleground()
  if not IsInInstance then
    return nil
  end
  local ok, result = pcall(function()
    local _, instanceType = IsInInstance()
    if type(instanceType) ~= "string" then
      return nil
    end
    return instanceType == "pvp"
  end)
  if ok then
    return result
  end
  return nil
end

-- Registers `event` on `frame`; false when the client refuses it (an unknown event or a restricted one).
function Platform.TryRegisterEvent(frame, event)
  local ok = pcall(frame.RegisterEvent, frame, event)
  return ok
end

-- Registers `event` on `frame` for one unit only (UNIT_AURA for "player"): the client then sends nothing about other
-- units. Falls back to the plain registration, which the handler has to filter. False when the client refuses both.
function Platform.TryRegisterUnitEvent(frame, event, unit)
  if frame.RegisterUnitEvent then
    local ok = pcall(frame.RegisterUnitEvent, frame, event, unit)
    if ok then
      return true
    end
  end
  return Platform.TryRegisterEvent(frame, event)
end

-- The text of a name from the client as a plain string without a realm suffix, or nil when it is not readable
-- (not a string, empty, or a secret value, which raises when it is measured or concatenated).
local function readableName(name)
  local ok, copy = pcall(function()
    if type(name) == "string" and #name > 0 then
      return name .. ""
    end
    return nil
  end)
  if not (ok and copy) then
    return nil
  end
  local normalizedOk, normalized = pcall(Platform.NormalizeName, copy)
  return normalizedOk and type(normalized) == "string" and normalized or copy
end

-- PvP missions (docs/PVP_MISSIONS_PLAN.md, sections 2 and 5). Nothing here is measured on Forever yet (M1, M3, M5):
-- each reader gives nil when the API is missing, raises or returns a secret value, and the caller then treats the
-- data as unknown instead of guessing.

-- The uiMapId of the zone the player is in, or nil.
function Platform.GetPlayerMapId()
  if not (C_Map and C_Map.GetBestMapForUnit) then
    return nil
  end
  local ok, mapId = pcall(function()
    local value = C_Map.GetBestMapForUnit("player")
    if type(value) == "number" and value > 0 and value % 1 == 0 then
      return value
    end
    return nil
  end)
  return ok and mapId or nil
end

-- An upper-case file token ("WARRIOR", "SCOURGE") from the second return of UnitClass / UnitRace, or nil.
local function fileToken(value)
  if type(value) == "string" and value:find("^%a+$") then
    return value:upper()
  end
  return nil
end

-- What is known of the enemy player on `unit` ("target", "mouseover", "nameplate3"): { name, class, race } with the
-- full name as the client gives it and the class and race file tokens (which do not depend on the locale); `class`
-- and `race` are nil when one is not readable. Nil when the unit is not an enemy player or nothing is readable.
function Platform.GetEnemyPlayerInfo(unit)
  if type(unit) ~= "string" or not (UnitIsPlayer and UnitIsEnemy and UnitClass and UnitRace) then
    return nil
  end
  local ok, info = pcall(function()
    if UnitIsPlayer(unit) ~= true or UnitIsEnemy("player", unit) ~= true then
      return nil
    end
    local name = readableName(GetUnitName and GetUnitName(unit, true) or UnitName(unit))
    local class = fileToken(select(2, UnitClass(unit)))
    local race = fileToken(select(2, UnitRace(unit)))
    if not name or not (class or race) then
      return nil
    end
    return { name = name, class = class, race = race }
  end)
  return ok and info or nil
end

-- Intel (docs/PVP_INTEL_PLAN.md). Not measured on Forever yet (M3, M4, M6, M7): every reader is guarded and gives nil
-- (or false for a switch) when the API is missing, raises or returns a secret value.

-- A plain string copy of text from the client, or nil when it is not a readable non-empty string. A secret value
-- raises when it is measured or concatenated.
local function readableText(value)
  local ok, copy = pcall(function()
    if type(value) == "string" and #value > 0 then
      return value .. ""
    end
    return nil
  end)
  return ok and copy or nil
end

local function factionOf(unit)
  if not UnitFactionGroup then
    return nil
  end
  local ok, faction = pcall(function()
    local value = UnitFactionGroup(unit)
    if value == "Alliance" or value == "Horde" then
      return value
    end
    return nil
  end)
  return ok and faction or nil
end

-- What is known of the enemy player on `unit`: { name, class, race, level, skull, guild, faction }. `class` and `race`
-- are upper-case file tokens, `level` is a whole number (nil when unreadable, and for a skull level, which sets
-- `skull = true`), `guild` and `faction` are nil when unreadable. Nil when the unit is not an enemy player of the
-- other faction (a duel opponent has the own one) or its name cannot be read. GetEnemyPlayerInfo, which the missions
-- use, is left as it is.
function Platform.GetEnemyDetails(unit)
  if type(unit) ~= "string" or not (UnitIsPlayer and UnitIsEnemy) then
    return nil
  end
  local ok, details = pcall(function()
    if UnitIsPlayer(unit) ~= true or UnitIsEnemy("player", unit) ~= true then
      return nil
    end
    local faction = factionOf(unit)
    if faction and faction == factionOf("player") then
      return nil
    end
    local name = readableName(GetUnitName and GetUnitName(unit, true) or UnitName(unit))
    if not name then
      return nil
    end
    local class = UnitClass and fileToken(select(2, UnitClass(unit))) or nil
    local race = UnitRace and fileToken(select(2, UnitRace(unit))) or nil
    local level, skull
    if UnitLevel then
      local value = UnitLevel(unit)
      if type(value) == "number" and value % 1 == 0 then
        if value == -1 then
          skull = true
        elseif value >= 1 then
          level = value
        end
      end
    end
    local guild = GetGuildInfo and readableText((GetGuildInfo(unit))) or nil
    return { name = name, class = class, race = race, level = level, skull = skull, guild = guild, faction = faction }
  end)
  return ok and details or nil
end

-- true when the enemy on `unit` has the player as its target, false when not, nil when the client does not say.
function Platform.IsEnemyTargetingPlayer(unit)
  if type(unit) ~= "string" or not UnitIsUnit then
    return nil
  end
  local ok, result = pcall(function()
    local value = UnitIsUnit(unit .. "target", "player")
    if value == true or value == 1 then
      return true
    elseif value == false or value == nil then
      return false
    end
    return nil
  end)
  if ok then
    return result
  end
  return nil
end

-- The PvP type of the zone ("sanctuary", "friendly", "hostile", "contested", "combat", "arena"), or nil.
function Platform.GetZonePvPType()
  if not GetZonePVPInfo then
    return nil
  end
  local ok, kind = pcall(function()
    local value = GetZonePVPInfo()
    if type(value) == "string" and value:find("^%a+$") then
      return value
    end
    return nil
  end)
  return ok and kind or nil
end

local INSTANCE_KINDS = { none = true, pvp = true, arena = true, party = true, raid = true }

-- "none", "pvp" (battleground), "arena", "party" (dungeon) or "raid"; nil when the client does not say. Any other kind
-- (a scenario) counts as a dungeon.
function Platform.GetInstanceKind()
  if not IsInInstance then
    return nil
  end
  local ok, kind = pcall(function()
    local _, instanceType = IsInInstance()
    if type(instanceType) ~= "string" then
      return nil
    end
    return INSTANCE_KINDS[instanceType] and instanceType or "party"
  end)
  return ok and kind or nil
end

-- Are the enemy nameplates on? nil when the client does not say.
function Platform.EnemyNameplatesEnabled()
  local reader = C_CVar and C_CVar.GetCVar or GetCVar
  if not reader then
    return nil
  end
  local ok, value = pcall(reader, "nameplateShowEnemies")
  if not ok then
    return nil
  end
  if value == "1" or value == 1 or value == true then
    return true
  elseif value == "0" or value == 0 or value == false then
    return false
  end
  return nil
end

-- Turns the enemy nameplates on. Refused in combat (the setting is protected there). Returns true when it was set.
function Platform.EnableEnemyNameplates()
  if Platform.IsInCombat() then
    return false
  end
  local writer = C_CVar and C_CVar.SetCVar or SetCVar
  if not writer then
    return false
  end
  return (pcall(writer, "nameplateShowEnemies", "1"))
end

-- The addon channel a message to the group goes to: "INSTANCE_CHAT" in an instance group (a battleground), "RAID" in a
-- raid, "PARTY" in a party, nil when the player is alone or the client does not say.
function Platform.GroupDistribution()
  local ok, channel = pcall(function()
    if IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
      return "INSTANCE_CHAT"
    end
    if IsInRaid and IsInRaid() then
      return "RAID"
    end
    if IsInGroup and IsInGroup() then
      return "PARTY"
    end
    return nil
  end)
  return ok and channel or nil
end

local CONTINENT_MAP_TYPE = 2
local ZONE_MAP_TYPE = 3
local MAP_PARENT_STEPS = 10

-- The uiMapId of `mapId` or of its closest parent of the map type `mapType` (the value of `enumName` in
-- Enum.UIMapType, else `fallback`), or nil.
local function ancestorOfType(mapId, enumName, fallback)
  if type(mapId) ~= "number" or not (C_Map and C_Map.GetMapInfo) then
    return nil
  end
  local ok, found = pcall(function()
    local current = mapId
    for _ = 1, MAP_PARENT_STEPS do
      local info = C_Map.GetMapInfo(current)
      if type(info) ~= "table" then
        return nil
      end
      local wanted = Enum and Enum.UIMapType and Enum.UIMapType[enumName] or fallback
      if info.mapType == wanted then
        return current
      end
      local parent = info.parentMapID
      if type(parent) ~= "number" or parent <= 0 then
        return nil
      end
      current = parent
    end
    return nil
  end)
  return ok and found or nil
end

-- The uiMapId of the continent that holds `mapId`, found through the parents of the map, or nil.
function Platform.GetContinentMapId(mapId)
  return ancestorOfType(mapId, "Continent", CONTINENT_MAP_TYPE)
end

-- The uiMapId of the zone that holds `mapId` (the map itself when it is a zone; a city is a zone too), or nil.
function Platform.GetZoneMapId(mapId)
  return ancestorOfType(mapId, "Zone", ZONE_MAP_TYPE)
end

-- Can this client say who won a battleground?
function Platform.HasBattlegroundWinner()
  return type(GetBattlefieldWinner) == "function"
end

-- "Alliance" or "Horde" once the battleground is decided, nil while it is not, for a draw or when unreadable.
function Platform.GetBattlegroundWinner()
  if not Platform.HasBattlegroundWinner() then
    return nil
  end
  local ok, winner = pcall(function()
    local value = GetBattlefieldWinner()
    if value == 1 then
      return "Alliance"
    elseif value == 0 then
      return "Horde"
    end
    return nil
  end)
  return ok and winner or nil
end

-- The faction of the player ("Alliance" | "Horde"), or nil.
function Platform.GetPlayerFaction()
  if not UnitFactionGroup then
    return nil
  end
  local ok, faction = pcall(function()
    local value = UnitFactionGroup("player")
    if value == "Alliance" or value == "Horde" then
      return value
    end
    return nil
  end)
  return ok and faction or nil
end

-- A Lua pattern for a client format string such as "%1$s has defeated %2$s in a duel" (or with plain "%s"), plus the
-- number of the argument each capture holds. Nil when the format is not a string or has fewer than two arguments.
local function formatPattern(format)
  if type(format) ~= "string" then
    return nil
  end
  local parts, order, index, auto = {}, {}, 1, 0
  while true do
    local first, last, number = format:find("%%(%d*)%$?s", index)
    if not first then
      parts[#parts + 1] = format:sub(index):gsub("%p", "%%%0")
      break
    end
    parts[#parts + 1] = format:sub(index, first - 1):gsub("%p", "%%%0")
    parts[#parts + 1] = "(.-)"
    auto = auto + 1
    order[#order + 1] = tonumber(number) or auto
    index = last + 1
  end
  if #order < 2 then
    return nil
  end
  return "^" .. table.concat(parts) .. "$", order
end

-- The name without a "-Realm" suffix (a name of several words keeps its spaces).
local function withoutRealm(name)
  return (name:gsub("%-[^%s%-]+$", ""))
end

-- Does this client define both duel message formats? (Without them a duel result cannot be read.)
function Platform.HasDuelResult()
  local ok, found = pcall(function()
    return formatPattern(_G.DUEL_WINNER_KNOCKOUT) ~= nil and formatPattern(_G.DUEL_WINNER_RETREAT) ~= nil
  end)
  return ok and found == true
end

-- The winner and the loser of a duel from the system message the client prints (CHAT_MSG_SYSTEM), or nil when the text
-- is not a duel result or the client does not define the message formats. The formats are the client globals
-- DUEL_WINNER_KNOCKOUT and DUEL_WINNER_RETREAT; in both, argument 1 is the winner and argument 2 the loser. Read from
-- _G: these globals are not in the luacheck list (API_NOTES M10).
function Platform.ParseDuelResult(message)
  if type(message) ~= "string" then
    return nil
  end
  for _, global in ipairs({ "DUEL_WINNER_KNOCKOUT", "DUEL_WINNER_RETREAT" }) do
    local ok, winner, loser = pcall(function()
      local pattern, order = formatPattern(_G[global])
      if not pattern then
        return nil
      end
      local captures = { message:match(pattern) }
      if #captures == 0 then
        return nil
      end
      local byArgument = {}
      for position, argument in ipairs(order) do
        byArgument[argument] = captures[position]
      end
      return byArgument[1], byArgument[2]
    end)
    if ok and winner and loser and winner ~= "" and loser ~= "" then
      return withoutRealm(winner), withoutRealm(loser)
    end
  end
  return nil
end

-- The map id of the battleground instance the player is in (the eighth return of GetInstanceInfo: 489 for Warsong
-- Gulch, 529 for Arathi Basin, 30 for Alterac Valley; not measured on Forever yet, API_NOTES M9), or nil outside a
-- battleground or when the client does not say. It names the battleground type, not one match.
function Platform.GetBattlegroundInstance()
  -- Read from _G: this client call is not in the luacheck globals list yet.
  local getInstanceInfo = _G.GetInstanceInfo
  if not (IsInInstance and getInstanceInfo) then
    return nil
  end
  local ok, mapId = pcall(function()
    local _, instanceType = IsInInstance()
    if instanceType ~= "pvp" then
      return nil
    end
    local value = select(8, getInstanceInfo())
    if type(value) == "number" and value > 0 and value % 1 == 0 then
      return value
    end
    return nil
  end)
  return ok and mapId or nil
end

-- Asks the client for the score data, which makes it fire UPDATE_BATTLEFIELD_SCORE (and with it the winner, once the
-- battleground is decided). True when the request was made.
function Platform.RequestBattlegroundScore()
  local request = _G.RequestBattlefieldScoreData
  if type(request) ~= "function" then
    return false
  end
  return (pcall(request))
end

-- Group (party or raid). The names are those the client gives: on Forever `UnitName` returns only the first word
-- of a multi-word name, and what `GetRaidRosterInfo` returns for one has not been measured yet (see API_NOTES).
-- Every call is guarded, so a missing API or a secret value leaves a name out instead of raising.

-- true when the player is in a party or a raid; false when not or when the client does not say.
function Platform.IsInGroup()
  if not IsInGroup then
    return false
  end
  local ok, grouped = pcall(IsInGroup)
  return ok and grouped == true
end

-- The name of a unit or roster row without any realm suffix, or nil when it is not readable.
local function groupName(read)
  local ok, name = pcall(read)
  local readable = ok and readableName(name) or nil
  return readable and readable:match("^([^%-]+)") or nil
end

-- The names of the other members of the group, and of the player in a raid (the roster lists everyone): a list of
-- strings, empty when not in a group or when nothing is readable.
function Platform.GetGroupMemberNames()
  local names = {}
  if not Platform.IsInGroup() then
    return names
  end
  local inRaid = IsInRaid and select(2, pcall(IsInRaid)) == true
  if inRaid and GetRaidRosterInfo and GetNumGroupMembers then
    local ok, total = pcall(GetNumGroupMembers)
    for index = 1, ok and type(total) == "number" and total or 0 do
      names[#names + 1] = groupName(function()
        return (GetRaidRosterInfo(index))
      end)
    end
  elseif not inRaid then
    for index = 1, 4 do
      names[#names + 1] = groupName(function()
        return (UnitName("party" .. index))
      end)
    end
  end
  return names
end

-- The seats of a raid from its roster, the player first, or an empty list when the roster cannot be read whole.
local function raidClasses()
  local seats = {}
  if not (GetRaidRosterInfo and GetNumGroupMembers) then
    return seats
  end
  local okTotal, total = pcall(GetNumGroupMembers)
  if not (okTotal and type(total) == "number") then
    return seats
  end
  local own = groupName(function()
    return (UnitName("player"))
  end)
  local moved = false
  for index = 1, total do
    local ok, name, _, _, _, _, class = pcall(GetRaidRosterInfo, index)
    if not ok then
      return {}
    end
    local seat = {
      name = groupName(function()
        return name
      end),
      class = fileToken(class),
    }
    -- UnitName gives only the first word of a multi-word name on Forever, the roster gives it whole.
    if not moved and own and seat.name and (seat.name == own or seat.name:match("^(%S+)") == own) then
      moved = true
      table.insert(seats, 1, seat)
    else
      seats[#seats + 1] = seat
    end
  end
  return seats
end

-- The seats of the player's group, the player first: { { name, class } } where `class` is a file token ("WARRIOR") or
-- nil when it is not readable. In a raid they come from the raid roster. Empty when not readable at all.
function Platform.GetPartyClasses()
  local seats = {}
  local inRaid = IsInRaid and select(2, pcall(IsInRaid)) == true
  if inRaid then
    return raidClasses()
  end
  if not UnitClass then
    return seats
  end
  local function seat(unit)
    local okClass, _, class = pcall(UnitClass, unit)
    return {
      name = groupName(function()
        return (UnitName(unit))
      end),
      class = okClass and fileToken(class) or nil,
    }
  end
  seats[1] = seat("player")
  if Platform.IsInGroup() then
    for index = 1, 4 do
      local unit = "party" .. index
      local okExists, exists = pcall(UnitExists or function()
        return false
      end, unit)
      if okExists and exists then
        seats[#seats + 1] = seat(unit)
      end
    end
  end
  return seats
end

-- Shows `text` as a raid warning in the middle of the screen. False when the client has no such frame.
-- Reloads the interface (a module switched on after login starts on the next load). Only from a click.
function Platform.ReloadUI()
  if ReloadUI then
    ReloadUI()
  end
end

function Platform.ShowRaidNotice(text)
  if not (RaidNotice_AddMessage and RaidWarningFrame) then
    return false
  end
  local ok = pcall(RaidNotice_AddMessage, RaidWarningFrame, text, ChatTypeInfo and ChatTypeInfo["RAID_WARNING"])
  return ok
end

-- The raid warning sound. False when the client has none or refuses it.
function Platform.PlayAlertSound()
  if not PlaySound then
    return false
  end
  local ok = pcall(PlaySound, SOUNDKIT and SOUNDKIT.RAID_WARNING or "RaidWarning")
  return ok
end

local combatInfo = {}

-- { subevent, sourceGUID, destGUID, destName } of the combat log event being handled, only for PARTY_KILL (the
-- one subevent that matters here), else nil. `destName` is the victim's name, or nil when it is not readable.
-- The table is reused to keep the combat log free of allocations, so it must be read before the next event.
-- The GUIDs may be secret: they are not inspected beyond that test.
function Platform.GetCombatLogInfo()
  if not CombatLogGetCurrentEventInfo then
    return nil
  end
  local ok, wanted = pcall(function()
    local _, subevent, _, sourceGUID, _, _, _, destGUID, destName = CombatLogGetCurrentEventInfo()
    if subevent ~= "PARTY_KILL" then
      return false
    end
    combatInfo.subevent, combatInfo.sourceGUID, combatInfo.destGUID = subevent, sourceGUID, destGUID
    combatInfo.destName = readableName(destName)
    return true
  end)
  if ok and wanted then
    return combatInfo
  end
  return nil
end

-- The client's own text for an honourable kill message: COMBATLOG_HONORGAIN ("%s dies, honorable kill Rank:
-- %s (%d Honor Points)") and the variant without a rank. Not measured on Forever yet (issue #99).
local HONOR_FORMATS = { "COMBATLOG_HONORGAIN", "COMBATLOG_HONORGAIN_NO_RANK" }

-- Turns a client format string into an anchored Lua pattern: the text is matched literally, "%s" becomes a lazy
-- capture and "%d" a number capture. Returns the pattern and the number of the capture that holds the first
-- argument (the victim; a positional format such as "%2$s" can reorder them), or nil when `format` is not a
-- usable string or has no "%s" for a first argument.
function Platform.HonorGainPattern(format)
  if type(format) ~= "string" or format == "" then
    return nil
  end
  local parts, captures, victim = {}, 0, nil
  local index = 1
  while index <= #format do
    local char = format:sub(index, index)
    if char == "%" then
      local position, kind = format:match("^%%(%d+)%$([sd])", index)
      local length
      if position then
        length = #position + 3
      else
        kind = format:match("^%%([sd])", index)
        length = 2
      end
      if kind then
        captures = captures + 1
        if (position and tonumber(position) or captures) == 1 and kind == "s" then
          victim = captures
        end
        parts[#parts + 1] = kind == "s" and "(.-)" or "(%d+)"
        index = index + length
      elseif format:sub(index + 1, index + 1) == "%" then
        parts[#parts + 1] = "%%"
        index = index + 2
      else
        return nil
      end
    else
      parts[#parts + 1] = (char:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
      index = index + 1
    end
  end
  if not victim then
    return nil
  end
  return "^" .. table.concat(parts) .. "$", victim
end

-- Is there a client text from which the victim of an honourable kill can be read?
function Platform.HasHonorVictimSource()
  for _, name in ipairs(HONOR_FORMATS) do
    if Platform.HonorGainPattern(_G[name]) then
      return true
    end
  end
  return false
end

-- The victim named by the text of a CHAT_MSG_COMBAT_HONOR_GAIN event, or nil when the client has no such format,
-- the text does not match it (a different message, such as bonus honour) or it is not readable (a secret value
-- raises on any use). Never raises.
function Platform.ParseHonorVictim(text)
  if type(text) ~= "string" then
    return nil
  end
  for _, name in ipairs(HONOR_FORMATS) do
    local pattern, victim = Platform.HonorGainPattern(_G[name])
    if pattern then
      local ok, captured = pcall(function()
        local found = { text:match(pattern) }
        return found[victim]
      end)
      if ok and type(captured) == "string" and captured ~= "" then
        return captured
      end
    end
  end
  return nil
end

-- The own position on the map as { map, x, y }: the map id and the zone coordinates 0..1. nil inside an instance,
-- when the API is missing, when either call gives nothing usable, or on an error or secret value. Not measured on
-- Forever yet (docs/API_NOTES.md).
function Platform.PlayerMapPosition()
  if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then
    return nil
  end
  local ok, position = pcall(function()
    if IsInInstance and IsInInstance() then
      return nil
    end
    local map = C_Map.GetBestMapForUnit("player")
    if type(map) ~= "number" or map <= 0 then
      return nil
    end
    local point = C_Map.GetPlayerMapPosition(map, "player")
    if type(point) ~= "table" or not point.GetXY then
      return nil
    end
    local x, y = point:GetXY()
    if type(x) ~= "number" or type(y) ~= "number" or x < 0 or x > 1 or y < 0 or y > 1 then
      return nil
    end
    return { map = map, x = x, y = y }
  end)
  if ok then
    return position
  end
  return nil
end

-- true when `name` is in the player's party or raid (UnitInRaid gives the raid index, UnitInParty a flag); false when
-- not, when the API is missing or on an error.
function Platform.IsGroupMember(name)
  if type(name) ~= "string" or name == "" then
    return false
  end
  local ok, member = pcall(function()
    return (UnitInParty and UnitInParty(name)) or (UnitInRaid and UnitInRaid(name))
  end)
  return ok and (member == true or type(member) == "number")
end

-- true while the player is in combat; false when not or when the client does not say.
function Platform.IsInCombat()
  local lockdown = InCombatLockdown or UnitAffectingCombat and function()
    return UnitAffectingCombat("player")
  end
  if not lockdown then
    return false
  end
  local ok, inCombat = pcall(lockdown)
  return ok and (inCombat == true or inCombat == 1)
end

function Platform.IsInRaid()
  if not IsInRaid then
    return false
  end
  local ok, inRaid = pcall(IsInRaid)
  return ok and inRaid == true
end

-- The number of players in the group (the player included), or 0 when alone or unknown.
function Platform.GetGroupSize()
  if not (GetNumGroupMembers and Platform.IsInGroup()) then
    return 0
  end
  local ok, total = pcall(GetNumGroupMembers)
  if ok and type(total) == "number" and total >= 0 then
    return total
  end
  return 0
end

-- true when the player leads the group; false when not or when the client does not say.
function Platform.IsGroupLeader()
  if not UnitIsGroupLeader then
    return false
  end
  local ok, leader = pcall(UnitIsGroupLeader, "player")
  return ok and leader == true
end

-- Invites `name` to the party. Returns true, or false plus "unavailable" | "error". Whether it needs a hardware
-- event, and whether a multi-word name works, is not measured yet: the caller only ever calls it from a click.
function Platform.InviteByName(name)
  if type(name) ~= "string" or name == "" then
    return false, "error"
  end
  local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
  if not invite then
    return false, "unavailable"
  end
  local ok = pcall(invite, name)
  return ok, not ok and "error" or nil
end

-- Turns the player's party into a raid (a raid post of Groups does it before an invite). Returns true when the client
-- took the call, false when it has no such call or refused it. Not measured on Forever yet.
function Platform.ConvertToRaid()
  local convert = (C_PartyInfo and C_PartyInfo.ConvertToRaid) or ConvertToRaid
  if not convert then
    return false
  end
  return (pcall(convert))
end

-- The group APIs "Fill from current group" needs. None is measured on Forever yet (API_NOTES, P0): the feature is
-- offered only when every one of them exists, and it works with whatever names GetGroupMemberNames can read.
function Platform.GroupApiAvailable()
  return IsInGroup ~= nil and IsInRaid ~= nil and GetNumGroupMembers ~= nil and GetRaidRosterInfo ~= nil
end

-- The names of everybody in the current group, the player included, without duplicates. Empty when not grouped or
-- when nothing is readable. In a party the client lists the others only, so the player is added from the identity.
function Platform.GetFullGroupNames()
  local names, seen = {}, {}
  if not Platform.IsInGroup() then
    return names
  end
  local function add(name)
    if type(name) == "string" and name ~= "" and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  for _, name in ipairs(Platform.GetGroupMemberNames()) do
    add(name)
  end
  add(Platform.GetIdentityKey())
  return names
end

-- Recipes (the Professions tab). The profession API of Mainline only lists recipes while a profession window is
-- open, and nothing here is measured on Forever yet (API_NOTES, P0). Every call is guarded, and the tab ships
-- disabled when this says false.
function Platform.RecipeScanAvailable()
  local api = C_TradeSkillUI
  return type(api) == "table"
    and type(api.GetAllRecipeIDs) == "function"
    and type(api.GetRecipeInfo) == "function"
    and type(api.GetBaseProfessionInfo) == "function"
end

-- Reads the recipes the player has learned in the profession window that is open now:
--   { professionId = skill line id, professionName = text, ids = { recipe ids } }
-- or nil plus a reason: "unavailable" (no API), "not_open" (no window or no profession data), "linked" (it is
-- somebody else's profession, a linked one or an NPC crafter: never scanned), "unreadable" (secret or invalid data).
function Platform.ScanKnownRecipes()
  if not Platform.RecipeScanAvailable() then
    return nil, "unavailable"
  end
  local api = C_TradeSkillUI
  for _, check in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsNPCCrafting" }) do
    if type(api[check]) == "function" then
      local ok, other = pcall(api[check])
      if ok and other == true then
        return nil, "linked"
      end
    end
  end
  local ok, scanned = pcall(function()
    local info = api.GetBaseProfessionInfo()
    if type(info) ~= "table" or type(info.professionID) ~= "number" or info.professionID < 1 then
      return nil
    end
    local all = api.GetAllRecipeIDs()
    if type(all) ~= "table" then
      return nil
    end
    local ids = {}
    for _, recipeId in ipairs(all) do
      local recipe = api.GetRecipeInfo(recipeId)
      if type(recipe) == "table" and recipe.learned == true and type(recipeId) == "number" then
        ids[#ids + 1] = recipeId
      end
    end
    return {
      professionId = info.professionID,
      professionName = type(info.professionName) == "string" and info.professionName or tostring(info.professionID),
      ids = ids,
    }
  end)
  if not ok then
    return nil, "unreadable"
  end
  if not scanned then
    return nil, "not_open"
  end
  return scanned
end

-- { name, icon, link } the client knows for a recipe id, each field only when readable. The name comes from the
-- recipe info, else from the spell the recipe teaches; the link is the crafted item's when the client says it.
function Platform.GetRecipeInfo(recipeId)
  if type(recipeId) ~= "number" then
    return nil
  end
  local result = {}
  local api = C_TradeSkillUI
  if type(api) == "table" and type(api.GetRecipeInfo) == "function" then
    local ok, recipe = pcall(api.GetRecipeInfo, recipeId)
    if ok and type(recipe) == "table" then
      result.name = type(recipe.name) == "string" and recipe.name or nil
      result.icon = recipe.icon
    end
  end
  if type(api) == "table" and type(api.GetRecipeOutputItemData) == "function" then
    local ok, data = pcall(api.GetRecipeOutputItemData, recipeId)
    if ok and type(data) == "table" and type(data.hyperlink) == "string" then
      result.link = data.hyperlink
    end
  end
  if not result.name then
    local ok, name, icon = pcall(function()
      if C_Spell and C_Spell.GetSpellInfo then
        local spell = C_Spell.GetSpellInfo(recipeId)
        return spell and spell.name, spell and spell.iconID
      elseif GetSpellInfo then
        local spellName, _, spellIcon = GetSpellInfo(recipeId)
        return spellName, spellIcon
      end
    end)
    if ok and type(name) == "string" then
      result.name = name
      result.icon = result.icon or icon
    end
  end
  return next(result) and result or nil
end

-- Opens the chat edit box with `text` typed in, so the player decides whether to press Enter. The addon never
-- sends a whisper itself. false when the client has no such call (not measured on Forever yet).
function Platform.CanPrefillChat()
  return (ChatFrameUtil ~= nil and ChatFrameUtil.OpenChat ~= nil) or ChatFrame_OpenChat ~= nil
end

function Platform.PrefillChat(text)
  if type(text) ~= "string" then
    return false
  end
  local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
  if not open then
    return false
  end
  local ok = pcall(open, text)
  return ok
end

-- The items in the loot window that is open now: a list of { slot, link, name, icon } for the item slots whose
-- link is readable. Nil when the client has no loot window API. Item links can arrive as secret values; those
-- slots are left out. Not measured on Forever yet (API_NOTES, P0): the "last boss loot" strip ships only when
-- this answers.
function Platform.LootWindowAvailable()
  return GetNumLootItems ~= nil and GetLootSlotLink ~= nil
end

function Platform.GetLootWindowItems()
  if not Platform.LootWindowAvailable() then
    return nil
  end
  local ok, items = pcall(function()
    local list = {}
    for slot = 1, GetNumLootItems() do
      local link = GetLootSlotLink(slot)
      if type(link) == "string" and link:find("|Hitem:", 1, true) then
        local icon, name
        if GetLootSlotInfo then
          icon, name = GetLootSlotInfo(slot)
        end
        list[#list + 1] = { slot = slot, link = link, name = type(name) == "string" and name or nil, icon = icon }
      end
    end
    return list
  end)
  if not ok then
    return nil
  end
  return items
end

-- Intel alerts and results (docs/PVP_INTEL_PLAN.md section 3.3). Not measured on Forever yet (M7, M8, M9): every reader
-- is guarded and gives nil (or false) for a missing API, an error or a secret value.

-- Shows `text` in the red error area at the top of the screen. False when the client has no such frame.
function Platform.ShowErrorText(text)
  if type(text) ~= "string" or not (UIErrorsFrame and UIErrorsFrame.AddMessage) then
    return false
  end
  return (pcall(UIErrorsFrame.AddMessage, UIErrorsFrame, text, 1, 0.1, 0.1, 1))
end

-- Shows `text` in the same area in gold, for news that is not a warning (a new group). False when there is none.
function Platform.ShowNoticeText(text)
  if type(text) ~= "string" or not (UIErrorsFrame and UIErrorsFrame.AddMessage) then
    return false
  end
  return (pcall(UIErrorsFrame.AddMessage, UIErrorsFrame, text, 1, 0.82, 0, 1))
end

-- The name of a map ("Stranglethorn Vale"), or nil when the client does not say.
function Platform.GetMapName(mapId)
  if type(mapId) ~= "number" or not (C_Map and C_Map.GetMapInfo) then
    return nil
  end
  local ok, name = pcall(function()
    local info = C_Map.GetMapInfo(mapId)
    if type(info) == "table" and type(info.name) == "string" and #info.name > 0 then
      return info.name .. ""
    end
    return nil
  end)
  return ok and name or nil
end

-- The sound of each kind of Intel alert: the SOUNDKIT name and the legacy sound name used when the client has none.
local INTEL_SOUNDS = {
  kos = { "RAID_WARNING", "RaidWarning" },
  kosGuild = { "ALARM_CLOCK_WARNING_3", "AlarmClockWarning3" },
  stealth = { "ALARM_CLOCK_WARNING_2", "AlarmClockWarning2" },
  race = { "IG_QUEST_LIST_OPEN", "igQuestListOpen" },
  new = { "IG_MAINMENU_OPEN", "igMainMenuOpen" },
}

-- Plays the sound of an alert kind. False when the kind is unknown or the client has no sound or refuses it.
function Platform.PlayIntelSound(kind)
  local sound = INTEL_SOUNDS[kind]
  if not (sound and PlaySound) then
    return false
  end
  return (pcall(PlaySound, SOUNDKIT and SOUNDKIT[sound[1]] or sound[2]))
end

-- The unit and the spell id of an UNIT_SPELLCAST_SUCCEEDED event as `unit, spellId`, or nil when either is missing or
-- not plain (during an encounter the arguments can be secret values, which raise when they are used).
function Platform.ReadSpellEvent(unit, _, spellId)
  local ok, readUnit, readSpell = pcall(function()
    if type(unit) ~= "string" or type(spellId) ~= "number" then
      return nil
    end
    local plain = unit .. ""
    local id = spellId + 0
    if #plain == 0 or id % 1 ~= 0 or id < 1 then
      return nil
    end
    return plain, id
  end)
  if ok and readUnit then
    return readUnit, readSpell
  end
  return nil
end

local LOCAL_DEFENSE_NAMES = { "localdefense", "defensalocal" }

-- The id of the Local Defense channel the player has joined, or nil. The channel name is localised, so it is matched
-- by the names of the known clients. Not measured yet.
local function localDefenseId()
  if not GetChannelList then
    return nil
  end
  local list = { GetChannelList() }
  for index = 1, #list - 1, 3 do
    local id, name = list[index], list[index + 1]
    if type(id) == "number" and type(name) == "string" then
      local lowered = name:lower():gsub("[%s_]", "")
      for _, known in ipairs(LOCAL_DEFENSE_NAMES) do
        if lowered:find(known, 1, true) then
          return id
        end
      end
    end
  end
  return nil
end

local CHAT_CHANNELS = { SAY = true, PARTY = true, RAID = true, GUILD = true, INSTANCE_CHAT = true }

-- Sends one chat line. `channel` is SAY, PARTY, RAID, GUILD, INSTANCE_CHAT or LOCALDEFENSE (which needs a hardware
-- event: call it from a click or a typed command). Nothing is sent during the encounter lockdown. False when it was
-- not sent.
function Platform.SendChatLine(channel, text)
  -- Clients with the Midnight API moved the function under C_ChatInfo.
  local sendChat = SendChatMessage or (C_ChatInfo and C_ChatInfo.SendChatMessage)
  if type(text) ~= "string" or text == "" or not sendChat or Platform.IsChatMessagingLockedDown() then
    return false
  end
  local ok = pcall(function()
    if channel == "LOCALDEFENSE" then
      local id = localDefenseId()
      if not id then
        error("no channel")
      end
      sendChat(text, "CHANNEL", nil, id)
    elseif CHAT_CHANNELS[channel] then
      sendChat(text, channel)
    else
      error("bad channel")
    end
  end)
  return ok
end

-- The name of the player the death recap blames for the death of the player, or nil when the recap is missing, empty
-- or unreadable (including a secret value). Not measured yet (M8): the functions of the retail recap are tried in turn.
function Platform.GetDeathKiller()
  local ok, killer = pcall(function()
    local events
    if DeathRecap_GetEvents then
      events = DeathRecap_GetEvents()
    elseif C_DeathRecap and C_DeathRecap.GetRecapEvents then
      events = C_DeathRecap.GetRecapEvents()
    end
    if type(events) ~= "table" then
      return nil
    end
    local best
    for _, event in ipairs(events) do
      if type(event) == "table" and type(event.sourceName) == "string" and #event.sourceName > 0 then
        local at = type(event.timestamp) == "number" and event.timestamp or 0
        if not best or at >= best.at then
          best = { at = at, name = event.sourceName .. "" }
        end
      end
    end
    return best and best.name or nil
  end)
  return ok and killer or nil
end

-- Which modifier keys are held now, as `shift, ctrl, alt` (booleans; false when the client does not say).
function Platform.ModifierKeys()
  local function down(read)
    if not read then
      return false
    end
    local ok, value = pcall(read)
    return ok and value == true
  end
  return down(IsShiftKeyDown), down(IsControlKeyDown), down(IsAltKeyDown)
end

-- Is the world map open now? False when it is closed or the client has none.
function Platform.WorldMapOpen()
  local ok, open = pcall(function()
    return WorldMapFrame ~= nil and WorldMapFrame:IsShown() == true
  end)
  return ok and open == true
end

-- Makes an open world map show `mapId`. Does nothing, and gives false, when the map is closed, the id is not a map or
-- the client refuses (the map can be busy). Not measured yet.
function Platform.ShowWorldMap(mapId)
  if type(mapId) ~= "number" or not Platform.WorldMapOpen() then
    return false
  end
  return (
    pcall(function()
      if WorldMapFrame.GetMapID and WorldMapFrame:GetMapID() == mapId then
        return
      end
      WorldMapFrame:SetMapID(mapId)
    end)
  )
end

-- Adds an entry to the menu of enemy players (the right-click menu of a unit), when the client has the menu API.
-- `label(name)` gives the text and `onPick(name)` runs on a click; `name` is the plain name the menu is about, and an
-- entry is only added when it can be read. Returns true when the hook was installed. Not measured yet (M12).
function Platform.AddEnemyPlayerMenuEntry(label, onPick)
  if not (Menu and Menu.ModifyMenu) then
    return false
  end
  return (
    pcall(Menu.ModifyMenu, "MENU_UNIT_ENEMY_PLAYER", function(_, root, context)
      pcall(function()
        local name = type(context) == "table" and readableText(context.name) or nil
        if not name then
          return
        end
        root:CreateDivider()
        root:CreateButton(label(name), function()
          onPick(name)
        end)
      end)
    end)
  )
end

ns.Platform = Platform
