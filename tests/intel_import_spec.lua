-- Intel import: names from text and from the saved lists of Spy.
local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/IntelModel",
    "Domain/IntelService",
    "Domain/IntelImport",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()

local function build()
  local intel = { players = {}, kos = {}, ignore = {}, zones = {} }
  return ns.IntelService.New({
    intel = intel,
    settings = function()
      return { removeMinutes = 5 }
    end,
    now = function()
      return 1
    end,
    wall = function()
      return 5000000
    end,
  }),
    intel
end

describe("IntelImport.Parse", function()
  it("takes names one per line or separated by commas, with an optional list on the first line", function()
    assert.are.same({ "Bob", "Eve", "Una" }, (ns.IntelImport.Parse("Bob\n Eve ,Una")))
    local names, target = ns.IntelImport.Parse("Ignore:\r\nBob;Eve\r\n\r\nUna")
    assert.are.same({ "Bob", "Eve", "Una" }, names)
    assert.are.equal("ignore", target)
    assert.are.equal("kos", select(2, ns.IntelImport.Parse("\n\nKOS\nBob")))
    assert.is_nil(select(2, ns.IntelImport.Parse("Bob\nkos")))
  end)

  it("reads nothing from something that is not text, and caps what it reads", function()
    assert.are.same({}, (ns.IntelImport.Parse(nil)))
    assert.are.same({}, (ns.IntelImport.Parse(12)))
    assert.are.equal(5000, #ns.IntelImport.Parse(string.rep("a,", 6000)))
  end)
end)

describe("IntelImport.FromText", function()
  it("adds to the Kill On Sight list by default and to the Ignore list when asked", function()
    local service, intel = build()
    local report = ns.IntelImport.FromText(service, "Bob, Eve-Realm")
    assert.are.same({ added = 2, skipped = 0, invalid = 0, limit = 0, target = "kos" }, report)
    assert.is_table(intel.kos.eve)
    local ignored = ns.IntelImport.FromText(service, "Una", "ignore")
    assert.are.equal(1, ignored.added)
    assert.is_table(intel.ignore.una)
    assert.are.equal("kos", ns.IntelImport.FromText(service, "Zed", "bogus").target)
  end)

  it("lets a header line win over the argument", function()
    local service, intel = build()
    ns.IntelImport.FromText(service, "ignore\nBob", "kos")
    assert.is_table(intel.ignore.bob)
  end)

  it("never overwrites an entry that exists, on either list", function()
    local service, intel = build()
    service:AddKos({ name = "Bob", category = "gank", reason = "mine" })
    service:AddIgnore("Eve")
    local report = ns.IntelImport.FromText(service, "Bob,Eve,Una,Una")
    assert.are.equal(1, report.added)
    assert.are.equal(3, report.skipped)
    assert.are.equal("gank", intel.kos.bob.category)
    assert.is_table(intel.ignore.eve)
  end)

  it("skips names that are not valid and names over the limit", function()
    local service = build()
    local report = ns.IntelImport.FromText(service, "a:b, ok|no, Fine")
    assert.are.same({ 1, 2, 2, 0 }, { report.added, report.skipped, report.invalid, report.limit })
    for index = 1, ns.Constants.INTEL_KOS_MAX do
      service.intel.kos["k" .. index] = { name = "K" .. index }
    end
    local full = ns.IntelImport.FromText(service, "Late")
    assert.are.same({ 0, 1, 0, 1 }, { full.added, full.skipped, full.invalid, full.limit })
    for index = 1, ns.Constants.INTEL_IGNORE_MAX do
      service.intel.ignore["i" .. index] = { name = "I" .. index }
    end
    assert.are.equal(1, ns.IntelImport.FromText(service, "Later", "ignore").limit)
  end)
end)

describe("IntelImport.FromSpy", function()
  it("reads the three places Spy is thought to keep its lists", function()
    local service, intel = build()
    local report = ns.IntelImport.FromSpy(service, {
      SpyPerCharDB = { KOSData = { Bob = 123, ["Eve-Realm"] = { time = 1 } }, IgnoreData = { "Una", 7 } },
      SpyDB = { kosData = { Zed = true } },
    })
    assert.are.equal(4, report.added)
    assert.is_table(intel.kos.bob)
    assert.is_table(intel.kos.eve)
    assert.is_table(intel.kos.zed)
    assert.is_table(intel.ignore.una)
  end)

  it("does not overwrite and counts what it skipped", function()
    local service = build()
    service:AddKos({ name = "Bob", category = "camp" })
    local report = ns.IntelImport.FromSpy(service, { SpyPerCharDB = { KOSData = { Bob = 1, ["a:b"] = 2 } } })
    assert.are.same({ added = 0, skipped = 2, invalid = 1, limit = 0 }, report)
    assert.are.equal("camp", service.intel.kos.bob.category)
  end)

  it("imports nothing and says so when Spy is not there or its data has another shape", function()
    local service, intel = build()
    assert.are.same({ nil, "not_found" }, { ns.IntelImport.FromSpy(service, {}) })
    assert.are.same({ nil, "not_found" }, { ns.IntelImport.FromSpy(service, nil) })
    assert.are.same({ nil, "not_found" }, { ns.IntelImport.FromSpy(service, { SpyPerCharDB = "text", SpyDB = 5 }) })
    assert.are.same({ nil, "not_found" }, {
      ns.IntelImport.FromSpy(
        service,
        { SpyPerCharDB = { KOSData = "x", IgnoreData = 3 }, SpyDB = { kosData = false } }
      ),
    })
    assert.are.same({}, intel.kos)
  end)

  it("treats a table of numbers or a table that raises as empty", function()
    local service = build()
    local hostile = setmetatable({}, {
      __pairs = function()
        error("boom")
      end,
      __index = function()
        error("boom")
      end,
    })
    local report =
      ns.IntelImport.FromSpy(service, { SpyPerCharDB = { KOSData = { 1, 2, 3 } }, SpyDB = { kosData = hostile } })
    assert.are.equal(0, report.added)
  end)
end)
