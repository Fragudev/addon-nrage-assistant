-- Platform is the seam over the client API; only the date helpers are pure enough to test here
-- (the stubs give it the standard library's time and date, like the real client).
local function load_platform()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Platform.lua"))("NrageAssistant", ns)
  return ns.Platform
end

local Platform = load_platform()

describe("Platform.ParseDate", function()
  it("parses a local date and time and round-trips through FormatDate", function()
    local timestamp = Platform.ParseDate("2026-10-03 20:30")
    assert.is_number(timestamp)
    assert.are.equal("2026-10-03 20:30", Platform.FormatDate(timestamp))
  end)

  it("orders dates chronologically", function()
    assert.is_true(Platform.ParseDate("2026-10-03 20:30") < Platform.ParseDate("2026-10-03 20:31"))
    assert.is_true(Platform.ParseDate("2026-10-03 23:59") < Platform.ParseDate("2026-10-04 00:00"))
  end)

  it("refuses text that is not in the expected format", function()
    for _, text in ipairs({
      "",
      "tomorrow",
      "2026-10-03",
      "20:30",
      "2026/10/03 20:30",
      "2026-10-3 20:30",
      "2026-10-03T20:30",
      "2026-10-03 8:30",
      "2026-10-03 20:30:00",
      "  2026-10-03 20:30",
      "2026-10-03 20:30 ",
    }) do
      assert.is_nil(Platform.ParseDate(text), text)
    end
    assert.is_nil(Platform.ParseDate(nil))
    assert.is_nil(Platform.ParseDate(5))
  end)

  it("refuses dates that do not exist instead of rolling them over", function()
    for _, text in ipairs({
      "2026-02-31 10:00",
      "2026-13-01 10:00",
      "2026-00-10 10:00",
      "2026-10-00 10:00",
      "2026-10-03 24:00",
      "2026-10-03 10:60",
      "2026-04-31 12:00",
    }) do
      assert.is_nil(Platform.ParseDate(text), text)
    end
  end)
end)

-- Runs `fn` with some client globals replaced, then puts them back.
local function with_globals(values, fn)
  local saved = {}
  for name, value in pairs(values) do
    saved[name] = _G[name]
    _G[name] = value
  end
  local ok, err = pcall(fn)
  for name in pairs(values) do
    _G[name] = saved[name]
  end
  assert(ok, err)
end

describe("Platform.NormalizeName", function()
  local function normalize(name)
    local result
    with_globals({
      GetNormalizedRealmName = function()
        return "ClassicBetaPvP"
      end,
    }, function()
      result = load_platform().NormalizeName(name)
    end)
    return result
  end

  it("drops the suffix of this realm, so a received name matches the roster's", function()
    assert.are.equal("Yonemon Gg", normalize("Yonemon Gg-ClassicBetaPvP"))
    assert.are.equal("Black Coffee", normalize("Black Coffee-ClassicBetaPvP"))
  end)

  it("leaves names without a suffix, or with another realm, as they are", function()
    assert.are.equal("Yonemon Gg", normalize("Yonemon Gg"))
    assert.are.equal("Yonemon-OtherRealm", normalize("Yonemon-OtherRealm"))
    assert.are.equal("A-ClassicBetaPvPX", normalize("A-ClassicBetaPvPX"))
  end)

  it("never returns an empty name, and passes non-strings through", function()
    assert.are.equal("-ClassicBetaPvP", normalize("-ClassicBetaPvP"))
    assert.is_nil(normalize(nil))
    assert.are.equal(5, normalize(5))
  end)

  it("does nothing when the realm is unknown", function()
    local result
    with_globals({
      GetNormalizedRealmName = function()
        return nil
      end,
    }, function()
      result = load_platform().NormalizeName("Name-Realm")
    end)
    assert.are.equal("Name-Realm", result)
  end)
end)

describe("Platform identity key", function()
  local function client()
    return {
      UnitName = function()
        return "Yonemon"
      end,
      GetNormalizedRealmName = function()
        return "ClassicBetaPvP"
      end,
    }
  end

  it("starts as the UnitName-based key, which is also the stable key of the saved data", function()
    with_globals(client(), function()
      local platform = load_platform()
      assert.are.equal("Yonemon-ClassicBetaPvP", platform.GetIdentityKey())
      assert.are.equal("Yonemon-ClassicBetaPvP", platform.GetLegacyIdentityKey())
    end)
  end)

  it("becomes the roster's full name once it is known, without touching the saved-data key", function()
    with_globals(client(), function()
      local platform = load_platform()
      platform.SetCanonicalName("Yonemon Gg")
      assert.are.equal("Yonemon Gg", platform.GetIdentityKey())
      assert.are.equal("Yonemon-ClassicBetaPvP", platform.GetLegacyIdentityKey())

      platform.SetCanonicalName(nil)
      assert.are.equal("Yonemon-ClassicBetaPvP", platform.GetIdentityKey())
    end)
  end)
end)

describe("Platform.GetGuildRosterEntry", function()
  it("returns the GUID, the seventeenth value of the roster row", function()
    local row = {
      "Yonemon Gg",
      "Soldado",
      3,
      60,
      "Warrior",
      "Zone",
      "",
      "",
      true,
      0,
      "WARRIOR",
      0,
      0,
      false,
      false,
      0,
      "Player-1-ABC",
    }
    with_globals({
      GetGuildRosterInfo = function()
        return unpack(row)
      end,
    }, function()
      local entry = load_platform().GetGuildRosterEntry(1)
      assert.are.same({
        name = "Yonemon Gg",
        rankName = "Soldado",
        rankIndex = 3,
        level = 60,
        class = "WARRIOR",
        guid = "Player-1-ABC",
        online = true,
      }, entry)
    end)
  end)

  it("returns nothing for an empty row", function()
    with_globals({
      GetGuildRosterInfo = function()
        return nil
      end,
    }, function()
      assert.is_nil(load_platform().GetGuildRosterEntry(1))
    end)
  end)
end)

describe("Platform.GetItemIcon", function()
  local saved = {}
  local names = { "C_Item", "GetItemIcon", "GetItemInfoInstant" }

  before_each(function()
    for _, name in ipairs(names) do
      saved[name] = _G[name]
      _G[name] = nil
    end
  end)

  after_each(function()
    for _, name in ipairs(names) do
      _G[name] = saved[name]
    end
  end)

  it("asks the modern API first, then the older ones", function()
    _G.C_Item = {
      GetItemIconByID = function()
        return "modern"
      end,
    }
    _G.GetItemIcon = function()
      return "old"
    end
    assert.are.equal("modern", Platform.GetItemIcon(19019))

    _G.C_Item = nil
    assert.are.equal("old", Platform.GetItemIcon(19019))

    _G.GetItemIcon = nil
    _G.GetItemInfoInstant = function(id)
      return id, "Weapon", "Sword", "INVTYPE_WEAPON", "instant"
    end
    assert.are.equal("instant", Platform.GetItemIcon(19019))
  end)

  it("falls back to a question mark when no API knows the item, errors, or the id is not a number", function()
    assert.are.equal(Platform.ITEM_FALLBACK_ICON, Platform.GetItemIcon(19019))
    _G.GetItemIcon = function()
      error("boom")
    end
    assert.are.equal(Platform.ITEM_FALLBACK_ICON, Platform.GetItemIcon(19019))
    _G.GetItemIcon = function()
      return "old"
    end
    assert.are.equal(Platform.ITEM_FALLBACK_ICON, Platform.GetItemIcon(nil))
    assert.are.equal(Platform.ITEM_FALLBACK_ICON, Platform.GetItemIcon("19019"))
  end)

  it("skips an API that answers with nothing and tries the next", function()
    _G.C_Item = {
      GetItemIconByID = function() end,
    }
    _G.GetItemIcon = function()
      return "old"
    end
    assert.are.equal("old", Platform.GetItemIcon(1))
  end)
end)

describe("Platform.GetItemDetails", function()
  local saved = {}
  local names = { "C_Item", "GetItemInfo", "INVTYPE_2HWEAPON" }

  before_each(function()
    for _, name in ipairs(names) do
      saved[name] = _G[name]
      _G[name] = nil
    end
  end)

  after_each(function()
    for _, name in ipairs(names) do
      _G[name] = saved[name]
    end
  end)

  it("reads the item level and slot from the client", function()
    _G.INVTYPE_2HWEAPON = "Two-Hand"
    _G.GetItemInfo = function()
      return "Thunderfury", "link", 5, 213, 60, "Weapon", "Sword", 1, "INVTYPE_2HWEAPON"
    end
    assert.are.same({ level = 213, slot = "Two-Hand" }, Platform.GetItemDetails(19019))
  end)

  it("prefers C_Item.GetItemInfo when the client has it", function()
    _G.C_Item = {
      GetItemInfo = function()
        return "Sword", "link", 4, 100, 1, "Weapon", "Sword", 1, ""
      end,
    }
    _G.GetItemInfo = function()
      error("should not be called")
    end
    assert.are.same({ level = 100 }, Platform.GetItemDetails(1))
  end)

  it("says nothing it does not know: an uncached item, a missing API, an error, a bad id", function()
    assert.is_nil(Platform.GetItemDetails(19019))
    _G.GetItemInfo = function() end
    assert.is_nil(Platform.GetItemDetails(19019))
    _G.GetItemInfo = function()
      error("boom")
    end
    assert.is_nil(Platform.GetItemDetails(19019))
    assert.is_nil(Platform.GetItemDetails(nil))
    assert.is_nil(Platform.GetItemDetails("19019"))
  end)
end)

describe("Platform PvP reads", function()
  local saved = {}
  local names = { "GetPVPSessionStats", "IsInInstance", "CombatLogGetCurrentEventInfo" }

  before_each(function()
    for _, name in ipairs(names) do
      saved[name] = _G[name]
    end
  end)

  after_each(function()
    for _, name in ipairs(names) do
      _G[name] = saved[name]
    end
  end)

  local function secret()
    return setmetatable({}, {
      __lt = function()
        error("secret")
      end,
      __le = function()
        error("secret")
      end,
    })
  end

  it("reads the honourable kills of the session", function()
    _G.GetPVPSessionStats = function()
      return 12, 3
    end
    assert.are.equal(12, Platform.GetPvPSessionKills())
  end)

  it("gives nil when the counter is missing, raises, or is not a count", function()
    _G.GetPVPSessionStats = nil
    assert.is_nil(Platform.GetPvPSessionKills())
    _G.GetPVPSessionStats = function()
      error("restricted")
    end
    assert.is_nil(Platform.GetPvPSessionKills())
    for _, value in ipairs({ "5", -1, 1.5 }) do
      _G.GetPVPSessionStats = function()
        return value
      end
      assert.is_nil(Platform.GetPvPSessionKills())
    end
    _G.GetPVPSessionStats = function() end
    assert.is_nil(Platform.GetPvPSessionKills())
  end)

  it("tells a battleground from the rest", function()
    _G.IsInInstance = function()
      return true, "pvp"
    end
    assert.is_true(Platform.IsInBattleground())
    for _, kind in ipairs({ "none", "party", "raid", "arena" }) do
      _G.IsInInstance = function()
        return kind ~= "none", kind
      end
      assert.is_false(Platform.IsInBattleground(), kind)
    end
  end)

  it("gives nil when the instance type is unreadable", function()
    _G.IsInInstance = nil
    assert.is_nil(Platform.IsInBattleground())
    _G.IsInInstance = function()
      error("restricted")
    end
    assert.is_nil(Platform.IsInBattleground())
    _G.IsInInstance = function()
      return true, secret()
    end
    assert.is_nil(Platform.IsInBattleground())
  end)

  it("formats the server day in UTC", function()
    assert.are.equal("1970-01-01", Platform.ServerDay(0))
    assert.are.equal("2026-10-01", Platform.ServerDay(1790812800))
    assert.are.equal("2026-10-01", Platform.ServerDay(1790812800 + 86399))
    assert.are.equal("2026-10-02", Platform.ServerDay(1790812800 + 86400))
  end)

  it("gives no day for something that is not a timestamp", function()
    assert.is_nil(Platform.ServerDay(nil))
    assert.is_nil(Platform.ServerDay("1000"))
    assert.is_nil(Platform.ServerDay(1e300))
  end)

  it("registers an event, and reports false when the client refuses it", function()
    local registered = {}
    local frame = {
      RegisterEvent = function(_, event)
        if event == "NOPE" then
          error("unknown event")
        end
        registered[#registered + 1] = event
      end,
    }
    assert.is_true(Platform.TryRegisterEvent(frame, "A"))
    assert.is_false(Platform.TryRegisterEvent(frame, "NOPE"))
    assert.are.same({ "A" }, registered)
  end)

  it("hands over only PARTY_KILL combat log events", function()
    _G.CombatLogGetCurrentEventInfo = function()
      return 1, "PARTY_KILL", false, "Player-1", "Me", 0, 0, "Player-2", "You"
    end
    assert.are.same(
      { subevent = "PARTY_KILL", sourceGUID = "Player-1", destGUID = "Player-2", destName = "You" },
      Platform.GetCombatLogInfo()
    )
    _G.CombatLogGetCurrentEventInfo = function()
      return 1, "SWING_DAMAGE", false, "Player-1", "Me", 0, 0, "Player-2", "You"
    end
    assert.is_nil(Platform.GetCombatLogInfo())
  end)

  it("gives nil when the combat log is missing, raises or is secret", function()
    _G.CombatLogGetCurrentEventInfo = nil
    assert.is_nil(Platform.GetCombatLogInfo())
    _G.CombatLogGetCurrentEventInfo = function()
      error("restricted")
    end
    assert.is_nil(Platform.GetCombatLogInfo())
    local value = setmetatable({}, {
      __eq = function()
        error("secret")
      end,
    })
    _G.CombatLogGetCurrentEventInfo = function()
      return 1, value
    end
    -- A table is never equal to a string without calling __eq, so it is simply not a PARTY_KILL.
    assert.is_nil(Platform.GetCombatLogInfo())
  end)
end)

describe("Platform honour kill victim", function()
  local saved = {}

  before_each(function()
    saved.rank, saved.noRank = _G.COMBATLOG_HONORGAIN, _G.COMBATLOG_HONORGAIN_NO_RANK
    _G.COMBATLOG_HONORGAIN = "%s dies, honorable kill Rank: %s (%d Honor Points)"
    _G.COMBATLOG_HONORGAIN_NO_RANK = nil
  end)

  after_each(function()
    _G.COMBATLOG_HONORGAIN, _G.COMBATLOG_HONORGAIN_NO_RANK = saved.rank, saved.noRank
  end)

  it("builds an anchored pattern with a capture per argument", function()
    local pattern, victim = Platform.HonorGainPattern("%s dies, honorable kill Rank: %s (%d Honor Points)")
    assert.are.equal("^(.-) dies, honorable kill Rank: (.-) %((%d+) Honor Points%)$", pattern)
    assert.are.equal(1, victim)
  end)

  it("escapes the magic characters of the text", function()
    local pattern = Platform.HonorGainPattern("[PvP] %s (100%%) +1 - done? ^$.*")
    assert.are.equal("^%[PvP%] (.-) %(100%%%) %+1 %- done%? %^%$%.%*$", pattern)
    assert.are.equal("Zed", ("[PvP] Zed (100%) +1 - done? ^$.*"):match(pattern))
  end)

  it("follows positional arguments to find the victim capture", function()
    local pattern, victim = Platform.HonorGainPattern("%2$s dies, rank %1$s")
    assert.are.equal("^(.-) dies, rank (.-)$", pattern)
    assert.are.equal(2, victim)
    assert.is_nil(Platform.HonorGainPattern("%d points"))
  end)

  it("gives nil for a format that is missing or not usable", function()
    assert.is_nil(Platform.HonorGainPattern(nil))
    assert.is_nil(Platform.HonorGainPattern(""))
    assert.is_nil(Platform.HonorGainPattern(42))
    assert.is_nil(Platform.HonorGainPattern("100% sure %s"))
  end)

  it("reads a single-word and a multi-word victim", function()
    assert.are.equal("Zed", Platform.ParseHonorVictim("Zed dies, honorable kill Rank: Knight (12 Honor Points)"))
    assert.are.equal(
      "Yonemon Gg",
      Platform.ParseHonorVictim("Yonemon Gg dies, honorable kill Rank: Grand Marshal (3 Honor Points)")
    )
  end)

  it("reads the variant without a rank", function()
    _G.COMBATLOG_HONORGAIN_NO_RANK = "%s dies, honorable kill (%d Honor Points)"
    assert.are.equal("Zed", Platform.ParseHonorVictim("Zed dies, honorable kill (12 Honor Points)"))
    -- The ranked text still wins when both exist.
    assert.are.equal("Zed", Platform.ParseHonorVictim("Zed dies, honorable kill Rank: Knight (12 Honor Points)"))
  end)

  it("gives nil when the text does not match", function()
    assert.is_nil(Platform.ParseHonorVictim("You have been awarded 12 honor."))
    assert.is_nil(Platform.ParseHonorVictim(""))
    assert.is_nil(Platform.ParseHonorVictim(nil))
  end)

  it("gives nil for text that is a secret value", function()
    local secret = setmetatable({}, {
      __tostring = function()
        error("secret")
      end,
      __concat = function()
        error("secret")
      end,
    })
    assert.is_nil(Platform.ParseHonorVictim(secret))
  end)

  it("gives nil when the client has no such format", function()
    _G.COMBATLOG_HONORGAIN = nil
    assert.is_nil(Platform.ParseHonorVictim("Zed dies, honorable kill Rank: Knight (12 Honor Points)"))
    assert.is_false(Platform.HasHonorVictimSource())
    _G.COMBATLOG_HONORGAIN = "%s dies"
    assert.is_true(Platform.HasHonorVictimSource())
  end)
end)

describe("Platform combat log victim name", function()
  local saved

  before_each(function()
    saved = _G.CombatLogGetCurrentEventInfo
  end)

  after_each(function()
    _G.CombatLogGetCurrentEventInfo = saved
  end)

  it("keeps the name of the victim when it is readable", function()
    _G.CombatLogGetCurrentEventInfo = function()
      return 1, "PARTY_KILL", false, "Player-1", "Me", 0, 0, "Player-2", "Yonemon Gg"
    end
    assert.are.equal("Yonemon Gg", Platform.GetCombatLogInfo().destName)
  end)

  it("leaves the name out when it is missing, empty or a secret value", function()
    local secret = setmetatable({}, {
      __concat = function()
        error("secret")
      end,
      __len = function()
        error("secret")
      end,
    })
    for _, name in ipairs({ "", secret, 42 }) do
      _G.CombatLogGetCurrentEventInfo = function()
        return 1, "PARTY_KILL", false, "Player-1", "Me", 0, 0, "Player-2", name
      end
      local info = Platform.GetCombatLogInfo()
      assert.are.equal("Player-2", info.destGUID)
      assert.is_nil(info.destName)
    end
  end)
end)

describe("Platform.FormatClock", function()
  it("formats the time of day", function()
    local timestamp = Platform.ParseDate("2026-10-03 20:30")
    assert.are.equal("20:30", Platform.FormatClock(timestamp))
  end)
end)

describe("Platform group", function()
  local saved = {}
  local names = {
    "IsInGroup",
    "IsInRaid",
    "GetNumGroupMembers",
    "GetRaidRosterInfo",
    "UnitName",
    "RaidNotice_AddMessage",
    "RaidWarningFrame",
    "ChatTypeInfo",
    "PlaySound",
    "SOUNDKIT",
    "GetNormalizedRealmName",
  }

  before_each(function()
    for _, name in ipairs(names) do
      saved[name] = _G[name]
    end
    _G.GetNormalizedRealmName = function()
      return "ClassicBetaPvP"
    end
  end)

  after_each(function()
    for _, name in ipairs(names) do
      _G[name] = saved[name]
    end
  end)

  local function party(units)
    _G.IsInGroup = function()
      return true
    end
    _G.IsInRaid = function()
      return false
    end
    _G.UnitName = function(unit)
      local value = units[unit]
      if type(value) == "table" then
        return value[1], value[2]
      end
      return value
    end
  end

  local function raid(rows)
    _G.IsInGroup = function()
      return true
    end
    _G.IsInRaid = function()
      return true
    end
    _G.GetNumGroupMembers = function()
      return #rows
    end
    _G.GetRaidRosterInfo = function(index)
      return rows[index]
    end
  end

  local function secret()
    return setmetatable({}, {
      __concat = function()
        error("secret")
      end,
      __len = function()
        error("secret")
      end,
    })
  end

  it("is empty when not in a group", function()
    _G.IsInGroup = function()
      return false
    end
    assert.is_false(Platform.IsInGroup())
    assert.are.same({}, Platform.GetGroupMemberNames())
  end)

  it("reads the party members, without realm suffixes", function()
    party({ party1 = "Ann", party2 = { "Bob", "OtherRealm" }, party3 = "Cid-ClassicBetaPvP", party4 = nil })
    assert.is_true(Platform.IsInGroup())
    assert.are.same({ "Ann", "Bob", "Cid" }, Platform.GetGroupMemberNames())
  end)

  it("reads the raid roster, without realm suffixes", function()
    raid({ "Ann", "Bob-ClassicBetaPvP", "Yonemon Gg" })
    assert.are.same({ "Ann", "Bob", "Yonemon Gg" }, Platform.GetGroupMemberNames())
  end)

  it("leaves out what cannot be read and keeps the rest", function()
    raid({ "Ann", "", secret(), 5, "Bob" })
    assert.are.same({ "Ann", "Bob" }, Platform.GetGroupMemberNames())
    party({ party1 = secret(), party2 = "Bob" })
    assert.are.same({ "Bob" }, Platform.GetGroupMemberNames())
  end)

  it("never raises, whatever the client does", function()
    raid({ "Ann" })
    _G.GetRaidRosterInfo = function()
      error("restricted")
    end
    assert.are.same({}, Platform.GetGroupMemberNames())
    _G.GetNumGroupMembers = function()
      error("restricted")
    end
    assert.are.same({}, Platform.GetGroupMemberNames())
    _G.IsInGroup = function()
      error("restricted")
    end
    assert.is_false(Platform.IsInGroup())
    assert.are.same({}, Platform.GetGroupMemberNames())
  end)

  it("gives an empty list when the group APIs are missing", function()
    _G.IsInGroup = nil
    assert.is_false(Platform.IsInGroup())
    assert.are.same({}, Platform.GetGroupMemberNames())
    _G.IsInGroup = function()
      return true
    end
    _G.IsInRaid = nil
    _G.GetRaidRosterInfo = nil
    _G.UnitName = nil
    assert.are.same({}, Platform.GetGroupMemberNames())
  end)

  it("shows a raid notice with the raid warning colour", function()
    local shown
    _G.RaidWarningFrame = {}
    _G.ChatTypeInfo = { RAID_WARNING = { r = 1, g = 0.5, b = 0 } }
    _G.RaidNotice_AddMessage = function(frame, text, color)
      shown = { frame = frame, text = text, color = color }
    end
    assert.is_true(Platform.ShowRaidNotice("watch out"))
    assert.are.equal(_G.RaidWarningFrame, shown.frame)
    assert.are.equal("watch out", shown.text)
    assert.are.equal(_G.ChatTypeInfo.RAID_WARNING, shown.color)
  end)

  it("does not raise when the raid notice is missing or fails", function()
    _G.RaidWarningFrame = nil
    assert.is_false(Platform.ShowRaidNotice("x"))
    _G.RaidWarningFrame = {}
    _G.ChatTypeInfo = nil
    _G.RaidNotice_AddMessage = function()
      error("boom")
    end
    assert.is_false(Platform.ShowRaidNotice("x"))
    _G.RaidNotice_AddMessage = nil
    assert.is_false(Platform.ShowRaidNotice("x"))
  end)

  it("plays the raid warning sound, and does not raise when it cannot", function()
    local played
    _G.SOUNDKIT = { RAID_WARNING = 8959 }
    _G.PlaySound = function(sound)
      played = sound
    end
    assert.is_true(Platform.PlayAlertSound())
    assert.are.equal(8959, played)

    _G.SOUNDKIT = nil
    assert.is_true(Platform.PlayAlertSound())
    assert.are.equal("RaidWarning", played)

    _G.PlaySound = function()
      error("boom")
    end
    assert.is_false(Platform.PlayAlertSound())
    _G.PlaySound = nil
    assert.is_false(Platform.PlayAlertSound())
  end)
end)

describe("Platform.GetEquippedEnchants", function()
  local saved

  before_each(function()
    saved = _G.GetInventoryItemLink
  end)

  after_each(function()
    _G.GetInventoryItemLink = saved
  end)

  it("returns nil when the client has no inventory API", function()
    _G.GetInventoryItemLink = nil
    assert.is_nil(Platform.GetEquippedEnchants())
  end)

  it("reads the enchant id of each equipped slot and leaves empty or unreadable slots out", function()
    local links = {
      [1] = "|cffffffff|Hitem:1234:2543:0:0|h[Helm]|h|r",
      [5] = "|cffffffff|Hitem:5678::0:0|h[Chest]|h|r",
      [6] = "garbage",
    }
    _G.GetInventoryItemLink = function(_, slot)
      return links[slot]
    end
    local result = Platform.GetEquippedEnchants()
    assert.are.equal(2543, result[1])
    assert.are.equal(0, result[5])
    assert.is_nil(result[6])
    assert.is_nil(result[2])
  end)

  it("drops a slot whose link raises instead of failing", function()
    _G.GetInventoryItemLink = function(_, slot)
      if slot == 1 then
        error("secret value")
      end
      return nil
    end
    assert.are.same({}, Platform.GetEquippedEnchants())
  end)
end)

describe("Platform.GetActiveBuffs", function()
  local saved

  before_each(function()
    saved = _G.UnitBuff
  end)

  after_each(function()
    _G.UnitBuff = saved
  end)

  it("returns nil when the client has no buff API", function()
    _G.UnitBuff = nil
    assert.is_nil(Platform.GetActiveBuffs())
  end)

  it("lists name and spell id and drops entries with unusable values", function()
    local buffs = {
      { "Elixir of the Mongoose", nil, nil, nil, nil, nil, nil, nil, nil, 17538 },
      { "Hidden", nil, nil, nil, nil, nil, nil, nil, nil, "secret" },
      { "Well Fed", nil, nil, nil, nil, nil, nil, nil, nil, 18125 },
    }
    _G.UnitBuff = function(_, index)
      local buff = buffs[index]
      if buff then
        return unpack(buff, 1, 10)
      end
    end
    assert.are.same({
      { name = "Elixir of the Mongoose", spellId = 17538 },
      { name = "Well Fed", spellId = 18125 },
    }, Platform.GetActiveBuffs())
  end)
end)
