-- Domain/ModuleRegistry: the static list of the toggleable modules, which tabs and activation steps each one owns, and
-- the requirement rules. Pure data: the cross-checks at the end load the whole addon to read ViewModel.TABS and the
-- activation steps of Core/Init.lua.
local function load_registry()
  local ns = {}
  assert(loadfile("NrageAssistant/Domain/ModuleRegistry.lua"))("NrageAssistant", ns)
  return ns.ModuleRegistry
end

local function ids(list)
  local result = {}
  for index, module in ipairs(list) do
    result[index] = module.id
  end
  return result
end

describe("ModuleRegistry", function()
  local Registry

  before_each(function()
    Registry = load_registry()
  end)

  it("lists the toggleable modules in the order of the Modules tab", function()
    assert.are.same({
      "professions",
      "raid",
      "loot",
      "pvp",
      "intel",
      "groups",
      "layers",
      "map",
      "blacklist",
      "announcements",
    }, ids(Registry.List()))
  end)

  it("finds the module that owns a tab", function()
    assert.are.equal("professions", Registry.ForTab("professions"))
    assert.are.equal("raid", Registry.ForTab("events"))
    assert.are.equal("raid", Registry.ForTab("roster"))
    assert.are.equal("pvp", Registry.ForTab("pvpadmin"))
    assert.is_nil(Registry.ForTab("home"))
    assert.is_nil(Registry.ForTab("unknown"))
  end)

  it("finds the module that owns an activation step", function()
    assert.are.equal("loot", Registry.ForStep("bossLoot"))
    assert.are.equal("pvp", Registry.ForStep("pvpSeason"))
    assert.are.equal("map", Registry.ForStep("position"))
    assert.is_nil(Registry.ForStep("character"))
    assert.is_nil(Registry.ForStep("unknown"))
  end)

  it("knows the core tabs and steps that no module owns", function()
    assert.is_true(Registry.IsCoreTab("home"))
    assert.is_true(Registry.IsCoreTab("modules"))
    assert.is_true(Registry.IsCoreTab("installs"))
    assert.is_false(Registry.IsCoreTab("pvp"))
    assert.is_true(Registry.IsCoreStep("comm"))
    assert.is_true(Registry.IsCoreStep("selfTest"))
    assert.is_false(Registry.IsCoreStep("pvp"))
  end)

  it("reads a module as enabled unless it is in the off set", function()
    assert.is_true(Registry.IsEnabled({ off = {} }, "pvp"))
    assert.is_false(Registry.IsEnabled({ off = { pvp = true } }, "pvp"))
    assert.is_true(Registry.IsEnabled({ off = { pvp = true } }, "raid"))
  end)

  it("treats a missing settings table as everything on", function()
    assert.is_true(Registry.IsEnabled(nil, "pvp"))
    assert.is_true(Registry.IsEnabled({}, "pvp"))
  end)

  it("ignores ids it does not know", function()
    assert.is_true(Registry.IsEnabled({ off = { future = true } }, "pvp"))
    assert.is_nil(Registry.Get("future"))
    assert.is_nil(Registry.ForTab("future"))
  end)

  it("makes a module disabled when a module it requires is off", function()
    assert.is_false(Registry.IsEnabled({ off = { raid = true } }, "loot"))
    assert.is_false(Registry.IsEnabled({ off = { pvp = true } }, "intel"))
    assert.is_true(Registry.IsEnabled({ off = { intel = true } }, "pvp"))
  end)

  it("lists every module a module needs, transitively, for turning it on", function()
    assert.are.same({ "raid" }, Registry.Requirements("loot"))
    assert.are.same({ "pvp" }, Registry.Requirements("intel"))
    assert.are.same({}, Registry.Requirements("pvp"))
  end)

  it("lists every module that needs a module, transitively, for turning it off", function()
    assert.are.same({ "loot" }, Registry.Dependents("raid"))
    assert.are.same({ "intel" }, Registry.Dependents("pvp"))
    assert.are.same({}, Registry.Dependents("map"))
  end)

  describe("against the addon", function()
    local ns

    setup(function()
      _G.CreateFrame = _G.CreateFrame
        or function()
          return { RegisterEvent = function() end, UnregisterEvent = function() end, SetScript = function() end }
        end
      ns = {}
      dofile("tests/support/addon.lua")(ns)
    end)

    it("gives every tab of the window to the core or to exactly one module", function()
      local problems = {}
      for _, tab in ipairs(ns.ViewModel.TABS) do
        local owners = Registry.IsCoreTab(tab.value) and 1 or 0
        for _, module in ipairs(Registry.List()) do
          for _, value in ipairs(module.tabs) do
            if value == tab.value then
              owners = owners + 1
            end
          end
        end
        if owners ~= 1 then
          problems[#problems + 1] = tab.value .. " owners=" .. owners
        end
      end
      assert.are.same({}, problems)
    end)

    it("gives every activation step to the core or to exactly one module", function()
      local problems = {}
      for _, name in ipairs(ns.ActivationStepNames()) do
        local owners = Registry.IsCoreStep(name) and 1 or 0
        for _, module in ipairs(Registry.List()) do
          for _, step in ipairs(module.steps) do
            if step == name then
              owners = owners + 1
            end
          end
        end
        if owners ~= 1 then
          problems[#problems + 1] = name .. " owners=" .. owners
        end
      end
      assert.are.same({}, problems)
    end)

    it("names no tab or step that the addon does not have", function()
      local tabs, steps = {}, {}
      for _, tab in ipairs(ns.ViewModel.TABS) do
        tabs[tab.value] = true
      end
      for _, name in ipairs(ns.ActivationStepNames()) do
        steps[name] = true
      end
      local unknown = {}
      for _, module in ipairs(Registry.List()) do
        for _, value in ipairs(module.tabs) do
          if not tabs[value] then
            unknown[#unknown + 1] = module.id .. " tab " .. value
          end
        end
        for _, name in ipairs(module.steps) do
          if not steps[name] then
            unknown[#unknown + 1] = module.id .. " step " .. name
          end
        end
      end
      assert.are.same({}, unknown)
    end)
  end)
end)
