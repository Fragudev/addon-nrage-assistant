local function load_modules()
  local ns = {}
  for _, path in ipairs({ "Core/Constants", "Core/Validate", "Domain/IntelModel" }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Model, Constants = ns.IntelModel, ns.Constants

local A_ACUTE_UPPER, A_ACUTE = "\195\129", "\195\161"

describe("IntelModel names", function()
  it("drops the realm suffix and the case in a key", function()
    assert.are.equal("yonemongg", Model.Key("Yonemon Gg-Realm"))
    assert.are.equal("yonemongg", Model.Key("  YONEMON   gg "))
    assert.are.equal(A_ACUTE .. "ngel", Model.Key(A_ACUTE_UPPER .. "ngel-Realm"))
  end)

  it("gives no key for something that is not a name", function()
    assert.is_nil(Model.Key(nil))
    assert.is_nil(Model.Key(5))
    assert.is_nil(Model.Key(""))
    assert.is_nil(Model.Key("-Realm"))
  end)

  it("cleans a name the way it is kept", function()
    assert.are.equal("Yonemon Gg", Model.CleanName("  Yonemon    Gg-Realm "))
    assert.are.equal(A_ACUTE_UPPER .. "ngel", Model.CleanName(A_ACUTE_UPPER .. "ngel"))
  end)

  it("refuses a name that is empty, long, or holds an escape", function()
    assert.is_nil(Model.CleanName(""))
    assert.is_nil(Model.CleanName("   "))
    assert.is_nil(Model.CleanName(nil))
    assert.is_nil(Model.CleanName(("x"):rep(Constants.INTEL_NAME_MAX + 1)))
    assert.is_nil(Model.CleanName("a|cffff0000b"))
    assert.is_nil(Model.CleanName("a:b"))
    assert.is_nil(Model.CleanName("a\1b"))
    assert.are.equal(("x"):rep(Constants.INTEL_NAME_MAX), Model.CleanName(("x"):rep(Constants.INTEL_NAME_MAX)))
  end)
end)

describe("IntelModel.ValidateKos", function()
  it("cleans the fields and gives the key", function()
    local clean = Model.ValidateKos({ name = "Bob-Realm", category = "gank", reason = "  camps the road " })
    assert.are.same({ name = "Bob", key = "bob", category = "gank", reason = "camps the road" }, clean)
  end)

  it("defaults the category and leaves a blank reason out", function()
    local clean = Model.ValidateKos({ name = "Bob", reason = "   " })
    assert.are.equal("other", clean.category)
    assert.is_nil(clean.reason)
  end)

  it("says why a field is refused", function()
    assert.are.same({ nil, "bad_name" }, { Model.ValidateKos({ name = "" }) })
    assert.are.same({ nil, "bad_name" }, { Model.ValidateKos(nil) })
    assert.are.same({ nil, "bad_category" }, { Model.ValidateKos({ name = "Bob", category = "nope" }) })
    assert.are.same({ nil, "long_reason" }, { Model.ValidateKos({ name = "Bob", reason = ("r"):rep(101) }) })
    assert.are.same({ nil, "bad_reason" }, { Model.ValidateKos({ name = "Bob", reason = "a|b" }) })
    assert.are.same({ nil, "bad_reason" }, { Model.ValidateKos({ name = "Bob", reason = 5 }) })
  end)

  it("knows the six categories", function()
    for _, category in ipairs({ "gank", "camp", "corpse", "objective", "insult", "other" }) do
      assert.is_true(Model.CategoryValid(category))
    end
    assert.is_false(Model.CategoryValid("revenge"))
    assert.is_false(Model.CategoryValid(nil))
  end)
end)

describe("IntelModel.DetectionAllowed", function()
  local function settings(overrides)
    local value = {
      enabled = true,
      inSanctuary = false,
      inBattleground = true,
      inArena = true,
      excludedZones = {},
    }
    for key, v in pairs(overrides or {}) do
      value[key] = v
    end
    return value
  end

  it("allows the open world", function()
    assert.is_true(Model.DetectionAllowed({ instance = "none", pvpType = "contested", mapId = 1411 }, settings()))
    assert.is_true(Model.DetectionAllowed({}, settings()))
  end)

  it("is off when the master switch is off or the input is not usable", function()
    assert.are.same({ false, "disabled" }, { Model.DetectionAllowed({}, settings({ enabled = false })) })
    assert.are.same({ false, "disabled" }, { Model.DetectionAllowed(nil, settings()) })
    assert.are.same({ false, "disabled" }, { Model.DetectionAllowed({}, nil) })
  end)

  it("never runs in dungeons and raids", function()
    for _, kind in ipairs({ "party", "raid" }) do
      assert.are.same({ false, "dungeon" }, { Model.DetectionAllowed({ instance = kind }, settings()) })
    end
  end)

  it("follows the settings in battlegrounds and arenas", function()
    assert.is_true(Model.DetectionAllowed({ instance = "pvp" }, settings()))
    assert.is_true(Model.DetectionAllowed({ instance = "arena" }, settings()))
    assert.are.same(
      { false, "battleground" },
      { Model.DetectionAllowed({ instance = "pvp" }, settings({ inBattleground = false })) }
    )
    assert.are.same(
      { false, "arena" },
      { Model.DetectionAllowed({ instance = "arena" }, settings({ inArena = false })) }
    )
  end)

  it("skips a sanctuary unless the setting allows it", function()
    assert.are.same({ false, "sanctuary" }, { Model.DetectionAllowed({ pvpType = "sanctuary" }, settings()) })
    assert.is_true(Model.DetectionAllowed({ pvpType = "sanctuary" }, settings({ inSanctuary = true })))
  end)

  it("skips an excluded zone", function()
    local config = settings({ excludedZones = { [1411] = true } })
    assert.are.same({ false, "excluded" }, { Model.DetectionAllowed({ mapId = 1411 }, config) })
    assert.is_true(Model.DetectionAllowed({ mapId = 1412 }, config))
  end)
end)

describe("IntelModel sighting", function()
  local function sighting(overrides)
    local fields = {
      map = 1411,
      x = 1235,
      y = 5000,
      class = "ROGUE",
      race = "ORC",
      level = 60,
      stealth = false,
      estimated = false,
      name = "Bob",
    }
    for key, value in pairs(overrides or {}) do
      fields[key] = value
    end
    return fields
  end

  it("round trips every field", function()
    local text = Model.EncodeSighting(sighting())
    assert.are.equal("I1:1411:1235:5000:4:6:60:0:Bob", text)
    assert.are.same(sighting(), Model.DecodeSighting(text))
    local flagged = Model.DecodeSighting(Model.EncodeSighting(sighting({ stealth = true, estimated = true })))
    assert.is_true(flagged.stealth)
    assert.is_true(flagged.estimated)
  end)

  it("keeps a multi-word name and an unknown class, race and level", function()
    local text = Model.EncodeSighting({ map = 1411, x = 1, y = 2, race = "ALIEN", name = "Yonemon Gg" })
    local decoded = Model.DecodeSighting(text)
    assert.are.equal("Yonemon Gg", decoded.name)
    assert.is_nil(decoded.class)
    assert.is_nil(decoded.race)
    assert.is_nil(decoded.level)
  end)

  it("fits the size limit in the worst case", function()
    local text = Model.EncodeSighting(sighting({
      map = 9999,
      x = 10000,
      y = 10000,
      level = 100,
      name = ("n"):rep(Constants.INTEL_NAME_MAX),
      class = "DRUID",
      race = "BLOODELF",
    }))
    assert.is_true(#text <= Constants.INTEL_MAX_BYTES)
    assert.is_table(Model.DecodeSighting(text))
  end)

  it("refuses to encode a field out of range", function()
    for _, overrides in ipairs({
      { map = 0 },
      { map = 10000 },
      { x = -1 },
      { y = 10001 },
      { level = 101 },
      { level = 1.5 },
      { name = "" },
      { name = "a:b" },
      { name = "Bob-Realm" },
      { name = " Bob" },
    }) do
      assert.is_nil(Model.EncodeSighting(sighting(overrides)))
    end
    assert.is_nil(Model.EncodeSighting(nil))
  end)

  it("refuses every malformed text", function()
    local function reason(text)
      local decoded, why = Model.DecodeSighting(text)
      assert.is_nil(decoded, text)
      return why
    end
    assert.are.equal("bad_format", reason(nil))
    assert.are.equal("bad_format", reason(5))
    assert.are.equal("bad_format", reason(""))
    assert.are.equal("bad_format", reason("I2:1411:1:1:0:0:0:0:Bob"))
    assert.are.equal("bad_format", reason("I1:1411:1:1:0:0:0:Bob"))
    assert.are.equal("bad_format", reason("I1:1411:1:1:0:0:0:0:"))
    assert.are.equal("bad_format", reason("I1:1411:1:1:0:0:0:0:Bob:extra"))
    assert.are.equal("bad_format", reason("I1:1411:1:1:0:0:0:0:Bo|b"))
    assert.are.equal("bad_format", reason("I1:1411:1:1:0:0:0:0:Bo\1b"))
    assert.are.equal("bad_format", reason("I1:1411:1:1:0:0:0:0: Bob"))
    assert.are.equal("bad_format", reason("I1:1411:1:1:0:0:0:0:Bob-Realm"))
    assert.are.equal("bad_format", reason("I1:-1:1:1:0:0:0:0:Bob"))
    assert.are.equal("bad_format", reason("I1:14.5:1:1:0:0:0:0:Bob"))
    assert.are.equal("out_of_range", reason("I1:0:1:1:0:0:0:0:Bob"))
    assert.are.equal("out_of_range", reason("I1:10000:1:1:0:0:0:0:Bob"))
    assert.are.equal("out_of_range", reason("I1:1411:10001:1:0:0:0:0:Bob"))
    assert.are.equal("out_of_range", reason("I1:1411:1:10001:0:0:0:0:Bob"))
    assert.are.equal("out_of_range", reason("I1:1411:1:1:10:0:0:0:Bob"))
    assert.are.equal("out_of_range", reason("I1:1411:1:1:0:11:0:0:Bob"))
    assert.are.equal("out_of_range", reason("I1:1411:1:1:0:0:101:0:Bob"))
    assert.are.equal("out_of_range", reason("I1:1411:1:1:0:0:0:4:Bob"))
    assert.are.equal("out_of_range", reason("I1:99999999999999999999:1:1:0:0:0:0:Bob"))
  end)

  it("refuses a text that is too long, or a name that is", function()
    assert.are.equal("too_long", select(2, Model.DecodeSighting("I1:1411:1:1:0:0:0:0:" .. ("n"):rep(100))))
    local name = ("n"):rep(Constants.INTEL_NAME_MAX + 1)
    assert.are.equal("bad_format", select(2, Model.DecodeSighting("I1:1411:1:1:0:0:0:0:" .. name)))
  end)
end)

describe("IntelModel.Plain", function()
  it("removes pipes and control characters and cuts the text", function()
    assert.are.equal("EvilGuild", ns.IntelModel.Plain("Evil|Guild\n"))
    assert.are.equal("abc", ns.IntelModel.Plain("a|b\tc"))
    assert.are.equal("abc", ns.IntelModel.Plain("abcdef", 3))
    assert.is_nil(ns.IntelModel.Plain("||"))
    assert.is_nil(ns.IntelModel.Plain(nil))
  end)
end)

describe("IntelModel share notice", function()
  it("is given once", function()
    local db = { global = { settings = { intelShareNotice = true } } }
    assert.is_true(Model.TakeShareNotice(db))
    assert.is_false(Model.TakeShareNotice(db))
    assert.is_nil(db.global.settings.intelShareNotice)
    assert.is_false(Model.TakeShareNotice({ global = {} }))
    assert.is_false(Model.TakeShareNotice({ global = { settings = { intelShareNotice = 1 } } }))
  end)
end)

describe("IntelModel class and race names", function()
  it("names the tokens the client gives, in English and in Spanish", function()
    local named = {}
    for _, path in ipairs({ "Core/Constants", "Core/Locale", "Locales/esES", "Core/Validate", "Domain/IntelModel" }) do
      assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", named)
    end
    for _, token in ipairs(named.Constants.INTEL_CLASSES) do
      assert.is_truthy(named.IntelModel.ClassName(token), token)
    end
    for _, token in ipairs(named.Constants.INTEL_RACES) do
      assert.is_truthy(named.IntelModel.RaceName(token), token)
    end
    assert.are.equal("Night Elf", named.IntelModel.RaceName("NIGHTELF"))
    assert.are.equal("Undead", named.IntelModel.RaceName("SCOURGE"))
    assert.is_nil(named.IntelModel.ClassName("DEATHKNIGHT"))
    assert.is_nil(named.IntelModel.ClassName(5))
    assert.is_nil(named.IntelModel.RaceName(nil))
    named.Locale.Use("esES")
    assert.are.equal("Guerrero", named.IntelModel.ClassName("WARRIOR"))
    assert.are.equal("Elfo de la noche", named.IntelModel.RaceName("NIGHTELF"))
  end)
end)
