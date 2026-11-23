-- The Layers tab view model (UI/ViewModelLayers.lua). `locale` (optional) is the client locale code to
-- load them for, e.g. "esES".
local function load_view_model(locale)
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/LayerModel",
    "UI/Kit/Theme",
    "UI/Kit/Util",
    "Domain/Professions",
    "UI/ViewModel",
    "UI/ViewModelLayers",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
    if path == "Locales/esES" and locale then
      ns.Locale.Use(locale)
    end
  end
  return ns.ViewModel, ns.Constants, ns
end

local ViewModel = load_view_model()

describe("ViewModel layers", function()
  local OWN = { map = 0, layer = 1234 }
  local function group(layer, members)
    return { map = 0, layer = layer, members = members, count = #members }
  end

  it("says the layer is unknown, or that the player is in an instance", function()
    assert.is_truthy(ViewModel.LayersView({ groups = {} }).yourLayer:find("unknown", 1, true))
    assert.is_truthy(
      ViewModel.LayersView({ inInstance = true, own = OWN, groups = {} }).yourLayer:find("instance", 1, true)
    )
  end)

  it("shows the own layer with the player on it", function()
    local view = ViewModel.LayersView({ own = OWN, share = true, ownName = "Me", groups = {} })
    assert.are.equal("Your layer: #1234", view.yourLayer)
    assert.is_true(view.share)
    assert.are.equal(1, #view.rows)
    assert.are.equal("#1234 (you)", view.rows[1].label)
    assert.are.equal("Me", view.rows[1].names)
  end)

  it("lists the other layers, and the members escaped", function()
    local view = ViewModel.LayersView({
      own = OWN,
      share = true,
      ownName = "Me",
      groups = { group(1234, { "Ann" }), group(5678, { "Bob|r", "Cid" }) },
    })
    assert.are.equal(2, #view.rows)
    assert.are.equal("Ann, Me", view.rows[1].names)
    assert.are.equal(2, view.rows[1].count)
    local other = view.rows[2]
    assert.are.equal("#5678", other.label)
    assert.are.equal("Bob||r, Cid", other.names)
    assert.are.equal(5678, other.layer)
  end)

  it("leaves the player out of the list when sharing is off", function()
    local view = ViewModel.LayersView({ own = OWN, share = false, ownName = "Me", groups = { group(1234, { "Ann" }) } })
    assert.are.equal("Ann", view.rows[1].names)
    view = ViewModel.LayersView({ own = OWN, share = false, ownName = "Me", groups = {} })
    assert.are.equal("", view.rows[1].names)
    assert.are.equal(0, view.rows[1].count)
  end)

  it("lists every continent, naming the map, when the own layer is unknown", function()
    local view = ViewModel.LayersView({ groups = { { map = 1, layer = 9, members = { "Eve" }, count = 1 } } })
    assert.are.equal("#0009 (map 1)", view.rows[1].label)
  end)

  it("names the zone the list is about, escaped, or says this zone when its name is not known", function()
    assert.are.equal(
      "Layers in Elwynn||Forest",
      ViewModel.LayersView({ own = OWN, zoneName = "Elwynn|Forest" }).listTitle
    )
    assert.are.equal("Layers in this zone", ViewModel.LayersView({ own = OWN }).listTitle)
  end)

  it("has a hint when nobody shared a layer, or when layers are not available", function()
    assert.is_truthy(ViewModel.LayersView({ groups = {} }).hint:find("Nobody", 1, true))
    assert.is_truthy(ViewModel.LayersView({ available = false }).hint:find("not available", 1, true))
  end)
end)

describe("ViewModel layers in Spanish", function()
  it("translates the tab and the sentences", function()
    local Spanish = load_view_model("esES")
    assert.are.equal("Capas en Elwynn", Spanish.LayersView({ zoneName = "Elwynn" }).listTitle)
  end)
end)
