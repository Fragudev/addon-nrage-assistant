-- ViewModelModules: the rows of the Modules tab, what each switch moves, and the sentences under it.
local function load_view_model(locale)
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/ModuleRegistry",
    "Domain/Settings",
    "Domain/ModuleService",
    "Domain/Professions",
    "UI/ViewModel",
    "UI/ViewModelModules",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
    if path == "Locales/esES" and locale then
      ns.Locale.Use(locale)
    end
  end
  return ns.ViewModel, ns
end

local ViewModel, ns = load_view_model()

-- The switches as the service sees them, with the cascade of the real service.
local function opts(overrides)
  local off = overrides.off or {}
  local service = ns.ModuleService.New({
    db = function()
      return { global = { settings = { modules = { off = off } } } }
    end,
    skipped = function()
      return overrides.skipped or {}
    end,
  })
  return {
    enabled = function(id)
      return service:IsEnabled(id)
    end,
    needsReload = function(id)
      return service:NeedsReload(id)
    end,
    cascade = function(id, enabled)
      return service:Cascade(id, enabled)
    end,
    admin = overrides.admin == true,
  }
end

local function rowOf(rows, id)
  for _, row in ipairs(rows) do
    if row.id == id then
      return row
    end
  end
end

describe("ViewModel.ModuleRows", function()
  it("has one row per module, in the order of the registry, with its name and tabs", function()
    local rows = ViewModel.ModuleRows(opts({}))
    local ids = {}
    for index, row in ipairs(rows) do
      ids[index] = row.id
    end
    assert.are.same(
      { "professions", "raid", "loot", "pvp", "intel", "groups", "layers", "map", "blacklist", "announcements" },
      ids
    )
    local pvp = rowOf(rows, "pvp")
    assert.are.equal("PvP", pvp.label)
    assert.are.same({ "PvP", "PvP" }, pvp.tabs)
    assert.is_nil(rowOf(rows, "intel").tabs[1])
  end)

  it("has a name and a description for every module", function()
    for _, module in ipairs(ns.ModuleRegistry.List()) do
      local text = ViewModel.MODULE_TEXT[module.id]
      assert.is_truthy(text, module.id)
      assert.is_truthy(text.label and text.label ~= "", module.id)
      assert.is_truthy(text.description and text.description ~= "", module.id)
    end
  end)

  it("reads each switch from the service", function()
    local rows = ViewModel.ModuleRows(opts({ off = { pvp = true, intel = true }, skipped = { "recipes" } }))
    assert.is_false(rowOf(rows, "pvp").enabled)
    assert.is_true(rowOf(rows, "raid").enabled)
    assert.is_true(rowOf(rows, "professions").needsReload)
    assert.is_false(rowOf(rows, "pvp").needsReload)
  end)

  it("names the other switches that turning a module off moves", function()
    local rows = ViewModel.ModuleRows(opts({}))
    assert.are.same({ "Intel" }, rowOf(rows, "pvp").also)
    assert.are.same({ "Loot" }, rowOf(rows, "raid").also)
    assert.are.same({}, rowOf(rows, "map").also)
    assert.is_false(rowOf(rows, "pvp").alsoOn)
  end)

  it("names the other switches that turning a module on moves", function()
    local rows = ViewModel.ModuleRows(opts({ off = { pvp = true, intel = true } }))
    assert.are.same({ "PvP" }, rowOf(rows, "intel").also)
    assert.is_true(rowOf(rows, "pvp").alsoOn)
    assert.is_true(rowOf(rows, "intel").alsoOn)
  end)

  it("warns an officer of gm or cogm rank that turning a module off hides its admin section", function()
    assert.is_true(rowOf(ViewModel.ModuleRows(opts({ admin = true })), "pvp").adminNote)
    assert.is_true(rowOf(ViewModel.ModuleRows(opts({ admin = true })), "raid").adminNote)
    assert.is_false(rowOf(ViewModel.ModuleRows(opts({ admin = true })), "intel").adminNote)
    assert.is_false(rowOf(ViewModel.ModuleRows(opts({ admin = false })), "pvp").adminNote)
    assert.is_false(rowOf(ViewModel.ModuleRows(opts({ admin = true, off = { pvp = true } })), "pvp").adminNote)
  end)
end)

describe("ViewModel module sentences", function()
  it("says what a switch moves, in both directions", function()
    local rows = ViewModel.ModuleRows(opts({}))
    assert.are.equal("Turning it off also turns off: Intel.", ViewModel.ModuleAlsoLine(rowOf(rows, "pvp")))
    assert.is_nil(ViewModel.ModuleAlsoLine(rowOf(rows, "map")))
    local off = ViewModel.ModuleRows(opts({ off = { pvp = true, intel = true } }))
    assert.are.equal("Turning it on also turns on: PvP.", ViewModel.ModuleAlsoLine(rowOf(off, "intel")))
  end)

  it("lists the tabs of a module", function()
    local rows = ViewModel.ModuleRows(opts({}))
    assert.are.equal("Tabs: PvP, PvP.", ViewModel.ModuleTabsLine(rowOf(rows, "pvp")))
    assert.is_nil(ViewModel.ModuleTabsLine(rowOf(rows, "intel")))
  end)

  it("reads in Spanish", function()
    ns.Locale.Use("esES")
    local rows = ViewModel.ModuleRows(opts({}))
    assert.are.equal("Módulos", ns.L("Modules"))
    assert.are.equal("Al desactivarlo también se desactiva: Intel.", ViewModel.ModuleAlsoLine(rowOf(rows, "pvp")))
    ns.Locale.Use("enUS")
  end)
end)
