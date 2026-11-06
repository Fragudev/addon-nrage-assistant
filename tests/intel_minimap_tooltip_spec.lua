-- IntelMinimapTooltip: the names on the tooltip of the minimap and what Intel adds to them.
local function load_addon()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/IntelModel",
    "Domain/IntelService",
    "Domain/IntelMinimapTooltip",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_addon()
local Tooltip = ns.IntelMinimapTooltip

local function service()
  return ns.IntelService.New({
    intel = { players = {}, kos = {}, ignore = {}, zones = {} },
    guildKos = {},
    settings = function()
      return { removeMinutes = 5 }
    end,
    now = function()
      return 100
    end,
    wall = function()
      return 1000
    end,
  })
end

describe("IntelMinimapTooltip.Parse", function()
  it("finds the clean names and says which ones are drawn as enemies", function()
    local names = Tooltip.Parse({
      { text = "Ann", r = 1, g = 0.1, b = 0.1 },
      { text = "|cffff0000Bob|r" },
      { text = "Cid", r = 0.1, g = 1, b = 0.1 },
      { text = "Level 60 Human" },
      { text = "Dan-Realm" },
      { text = "  |cff00ff00Eve|r  " },
      { text = "" },
      { text = "with | pipe" },
      { text = 5 },
      "not a line",
    })
    local found = {}
    for _, entry in ipairs(names) do
      found[#found + 1] = { entry.index, entry.name, entry.hostile }
    end
    assert.are.same({
      { 1, "Ann", true },
      { 2, "Bob", true },
      { 3, "Cid", false },
      { 5, "Dan", false },
      { 6, "Eve", false },
    }, found)
  end)

  it("reads nothing from what is not a list of lines", function()
    assert.are.same({}, Tooltip.Parse(nil))
    assert.are.same({}, Tooltip.Parse("text"))
    assert.are.same({}, Tooltip.Parse({ { text = string.rep("a", 130) } }))
  end)
end)

describe("IntelMinimapTooltip.Plan", function()
  local settings = { minimapTooltip = true, minimapFeed = false }

  it("adds the level and class of the enemies it knows", function()
    local svc = service()
    svc:OnSeen({ name = "Ann", class = "MAGE", level = 60, guild = "Wolves" }, {})
    svc:OnSeen({ name = "Bob", class = "ROGUE", level = 70, levelEstimated = true }, {})
    svc:OnSeen({ name = "Cid" }, {})
    local plan = Tooltip.Plan({
      { index = 1, name = "Ann" },
      { index = 2, name = "Bob" },
      { index = 3, name = "Cid" },
      { index = 4, name = "Nobody" },
    }, svc, settings)
    assert.are.same({
      { index = 1, name = "Ann", text = "Level 60 Mage" },
      { index = 2, name = "Bob", text = "Level 70? Rogue" },
    }, plan.extras)
    assert.are.same({}, plan.feed)
  end)

  it("describes a record that has only a class, or only a level", function()
    local svc = service()
    svc:OnSeen({ name = "Ann", class = "MAGE" }, {})
    svc:OnSeen({ name = "Bob", level = 12 }, {})
    local plan = Tooltip.Plan({ { index = 1, name = "Ann" }, { index = 2, name = "Bob" } }, svc, settings)
    assert.are.equal("Mage", plan.extras[1].text)
    assert.are.equal("Level 12", plan.extras[2].text)
  end)

  it("adds nothing when the tooltip is switched off", function()
    local svc = service()
    svc:OnSeen({ name = "Ann", class = "MAGE", level = 60 }, {})
    local plan = Tooltip.Plan({ { index = 1, name = "Ann" } }, svc, { minimapTooltip = false })
    assert.are.same({}, plan.extras)
  end)

  it("feeds Nearby with the known enemies and the ones drawn as enemies", function()
    local svc = service()
    svc:OnSeen({ name = "Ann", class = "MAGE", race = "HUMAN", level = 60, guild = "Wolves", faction = "Horde" }, {})
    svc:AddIgnore("Ivy")
    local plan = Tooltip.Plan({
      { index = 1, name = "Ann", hostile = false },
      { index = 2, name = "Bob", hostile = true },
      { index = 3, name = "Cid", hostile = false },
      { index = 4, name = "Ivy", hostile = true },
    }, svc, { minimapTooltip = false, minimapFeed = true })
    assert.are.equal(2, #plan.feed)
    assert.are.equal("Ann", plan.feed[1].name)
    assert.are.equal("MAGE", plan.feed[1].class)
    assert.are.equal("Wolves", plan.feed[1].guild)
    assert.are.equal("Bob", plan.feed[2].name)
    assert.is_nil(plan.feed[2].class)
  end)

  it("does nothing with settings that are not a table", function()
    assert.are.same({ extras = {}, feed = {} }, Tooltip.Plan({}, service(), nil))
    assert.are.same({ extras = {}, feed = {} }, Tooltip.Plan(nil, service(), {}))
  end)

  it("speaks Spanish when the client does", function()
    ns.Locale.Use("esES")
    local svc = service()
    svc:OnSeen({ name = "Ann", class = "MAGE", level = 60 }, {})
    local plan = Tooltip.Plan({ { index = 1, name = "Ann" } }, svc, settings)
    ns.Locale.Use("enUS")
    assert.are.equal("Nivel 60 Mago", plan.extras[1].text)
  end)
end)
