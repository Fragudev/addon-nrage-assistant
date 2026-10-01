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
