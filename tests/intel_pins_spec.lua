-- IntelPins: which enemies go on the maps, from the ones seen here and the sightings of the guild.
local function load_addon()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Core/Validate",
    "Domain/PositionModel",
    "Domain/IntelModel",
    "Domain/IntelPins",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_addon()

local function own(name, extra)
  local item = { key = name:lower(), name = name, class = "MAGE", level = 60, map = 1429, x = 5000, y = 2500, age = 10 }
  for key, value in pairs(extra or {}) do
    item[key] = value
  end
  return item
end

local function remote(name, extra)
  local entry =
    { key = name:lower(), name = name, class = "ROGUE", level = 58, map = 1429, x = 1000, y = 9000, at = 90 }
  entry.source = "Bob-Realm"
  for key, value in pairs(extra or {}) do
    entry[key] = value
  end
  return entry
end

local function build(overrides)
  local ctx = {
    own = {},
    remote = {},
    now = function()
      return 100
    end,
    mapMode = "all",
    ownMap = 1429,
    continentOf = function(map)
      return map < 2000 and 1 or 2
    end,
  }
  for key, value in pairs(overrides or {}) do
    ctx[key] = value
  end
  return ns.IntelPins.Build(ctx)
end

describe("IntelPins.Build", function()
  it("draws an enemy seen here with zone coordinates and no reporter", function()
    local pins = build({ own = { own("Ann", { levelEstimated = true, stealth = true, kos = "guild", faded = true }) } })
    assert.are.equal(1, #pins)
    local pin = pins[1]
    assert.are.same(
      { "ann", "Ann", "MAGE", 60, 1429, 0.5, 0.25, 10, "guild" },
      { pin.key, pin.name, pin.class, pin.level, pin.map, pin.x, pin.y, pin.age, pin.kos }
    )
    assert.is_true(pin.levelEstimated)
    assert.is_true(pin.stealth)
    assert.is_nil(pin.reporter)
  end)

  it("draws a sighting of the guild with its reporter and ages it from now", function()
    local pins = build({ remote = { remote("Cid") } })
    assert.are.equal("Bob-Realm", pins[1].reporter)
    assert.are.equal(10, pins[1].age)
    assert.are.equal(0.1, pins[1].x)
    assert.are.equal(0.9, pins[1].y)
    assert.is_false(pins[1].levelEstimated)
    local estimated = build({ remote = { remote("Cid", { estimated = true }) } })
    assert.is_true(estimated[1].levelEstimated)
  end)

  it("keeps the newest sighting of an enemy, wherever it came from", function()
    local newer = build({ own = { own("Ann", { age = 3 }) }, remote = { remote("Ann", { at = 90 }) } })
    assert.are.equal(1, #newer)
    assert.is_nil(newer[1].reporter)
    local older = build({ own = { own("Ann", { age = 30 }) }, remote = { remote("Ann", { at = 95 }) } })
    assert.are.equal("Bob-Realm", older[1].reporter)
    -- Sightings that came to Nearby from the directory are the directory's to draw.
    local viaNearby = build({ own = { own("Ann", { source = "Bob-Realm" }) } })
    assert.are.equal(0, #viaNearby)
  end)

  it("puts the Kill on Sight players first, then the newest", function()
    local pins = build({
      own = { own("Ann", { age = 5 }), own("Bob", { age = 2 }) },
      remote = { remote("Cid", { at = 99 }), remote("Dan", { at = 80 }) },
      kosOf = function(key)
        return key == "dan" and "personal" or nil
      end,
    })
    local order = {}
    for _, pin in ipairs(pins) do
      order[#order + 1] = pin.key
    end
    assert.are.same({ "dan", "cid", "bob", "ann" }, order)
    assert.are.equal("personal", pins[1].kos)
  end)

  it("breaks a tie by the key", function()
    local pins = build({ own = { own("Zed"), own("Abe") } })
    assert.are.equal("abe", pins[1].key)
  end)

  it("follows the map mode", function()
    local list = { own("Ann"), own("Bob", { map = 1430 }), own("Cid", { map = 2500 }) }
    local function keys(mode)
      local found = {}
      for _, pin in ipairs(build({ own = list, mapMode = mode })) do
        found[#found + 1] = pin.key
      end
      table.sort(found)
      return found
    end
    assert.are.same({ "ann", "bob", "cid" }, keys("all"))
    assert.are.same({ "ann" }, keys("zone"))
    assert.are.same({ "ann", "bob" }, keys("continent"))
    assert.are.same({}, keys("none"))
    assert.are.same({}, ns.IntelPins.Build({ own = list, remote = {}, now = os.time, ownMap = 1429 }))
    for _, mode in ipairs({ "zone", "continent" }) do
      local lost = ns.IntelPins.Build({ own = list, remote = {}, now = os.time, mapMode = mode })
      assert.are.same({}, lost)
    end
    -- Without a continent for the own map, only the own map counts.
    local noContinent = build({
      own = list,
      mapMode = "continent",
      continentOf = function()
        return nil
      end,
    })
    assert.are.equal(1, #noContinent)
    local raising = build({
      own = list,
      mapMode = "continent",
      continentOf = function()
        error("boom")
      end,
    })
    assert.are.equal(1, #raising)
  end)

  it("leaves out the ignored, the damaged and what has no position", function()
    local pins = build({
      own = { own("Ann"), own("Bob", { x = "x" }), own("Cid", { map = "1" }), { name = "|", map = 1, x = 1, y = 1 } },
      remote = { remote("Dan") },
      isIgnored = function(key)
        return key == "dan"
      end,
    })
    assert.are.equal(1, #pins)
    assert.are.equal("ann", pins[1].key)
  end)

  it("never draws more than the directory can hold", function()
    local many = {}
    for index = 1, ns.Constants.INTEL_DIRECTORY_MAX + 10 do
      many[index] = own("P" .. index, { age = index })
    end
    assert.are.equal(ns.Constants.INTEL_DIRECTORY_MAX, #build({ own = many }))
  end)
end)
