-- The Layers tab and swap popup view models (UI/ViewModelLayers.lua). `locale` (optional) is the client locale code to
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

  it("shows the own layer with the player on it and no button", function()
    local view = ViewModel.LayersView({ own = OWN, share = true, ownName = "Me", groups = {}, canRequest = true })
    assert.are.equal("Your layer: #1234", view.yourLayer)
    assert.is_true(view.share)
    assert.are.equal(1, #view.rows)
    assert.are.equal("#1234 (you)", view.rows[1].label)
    assert.are.equal("Me", view.rows[1].names)
    assert.is_false(view.rows[1].button)
  end)

  it("lists the other layers with a button, and the members escaped", function()
    local view = ViewModel.LayersView({
      own = OWN,
      share = true,
      ownName = "Me",
      groups = { group(1234, { "Ann" }), group(5678, { "Bob|r", "Cid" }) },
      canRequest = true,
    })
    assert.are.equal(2, #view.rows)
    assert.are.equal("Ann, Me", view.rows[1].names)
    assert.are.equal(2, view.rows[1].count)
    local other = view.rows[2]
    assert.are.equal("#5678", other.label)
    assert.are.equal("Bob||r, Cid", other.names)
    assert.is_true(other.button)
    assert.is_true(other.enabled)
    assert.is_nil(other.reason)
    assert.are.equal(5678, other.layer)
  end)

  it("leaves the player out of the list when sharing is off", function()
    local view = ViewModel.LayersView({ own = OWN, share = false, ownName = "Me", groups = { group(1234, { "Ann" }) } })
    assert.are.equal("Ann", view.rows[1].names)
    view = ViewModel.LayersView({ own = OWN, share = false, ownName = "Me", groups = {} })
    assert.are.equal("", view.rows[1].names)
    assert.are.equal(0, view.rows[1].count)
  end)

  it("has a text for every reason the swap rules and the Groups exclusion can give", function()
    for _, reason in ipairs({ "busy", "locked", "unsupported", "lfg", "in_group", "in_instance", "in_combat" }) do
      assert.is_truthy(ViewModel.LAYER_REASONS[reason], reason)
    end
  end)

  it("disables the buttons with the reason", function()
    for reason, text in pairs(ViewModel.LAYER_REASONS) do
      local view = ViewModel.LayersView({
        own = OWN,
        groups = { group(5678, { "Bob" }) },
        canRequest = false,
        reason = reason,
      })
      local row = view.rows[2]
      assert.is_false(row.enabled)
      assert.are.equal(text, row.reason)
    end
    assert.are.equal("something_new", ViewModel.LayerReason("something_new"))
  end)

  it("lists every continent, naming the map, when the own layer is unknown", function()
    local view = ViewModel.LayersView({ groups = { { map = 1, layer = 9, members = { "Eve" }, count = 1 } } })
    assert.are.equal("#0009 (map 1)", view.rows[1].label)
    assert.is_true(view.rows[1].button)
  end)

  it("has a hint when nobody shared a layer, or when layers are not available", function()
    assert.is_truthy(ViewModel.LayersView({ groups = {} }).hint:find("Nobody", 1, true))
    assert.is_truthy(ViewModel.LayersView({ available = false }).hint:find("not available", 1, true))
  end)

  it("shows the running swap and what cancelling is called", function()
    local running = { role = "requester", stage = "request", map = 0, layer = 5678, left = 30 }
    local view = ViewModel.LayersView({ own = OWN, groups = {}, swap = running })
    assert.is_truthy(view.swapLine:find("Looking for someone on #5678", 1, true))
    assert.are.equal("Cancel", view.cancelText)
    running.stage = "done"
    assert.are.equal("Close", ViewModel.LayersView({ own = OWN, groups = {}, swap = running }).cancelText)
    local helping = { role = "helper", stage = "assigned", requester = "Ann", map = 0, layer = 1234 }
    view = ViewModel.LayersView({ own = OWN, groups = {}, swap = helping })
    assert.is_nil(view.cancelText)
    assert.is_truthy(view.swapLine)
  end)
end)

describe("ViewModel.LayerSwapView", function()
  local function requester(overrides)
    local status = { role = "requester", stage = "request", map = 0, layer = 5678 }
    for key, value in pairs(overrides or {}) do
      status[key] = value
    end
    return status
  end

  local function ids(view)
    local list = {}
    for _, button in ipairs(view.buttons) do
      list[#list + 1] = button.id
    end
    return table.concat(list, ",")
  end

  it("has nothing for no swap", function()
    assert.is_nil(ViewModel.LayerSwapView(nil))
  end)

  it("tells the requester what each outcome means", function()
    local expectations = {
      { requester({ stage = "closed", outcome = "expired" }), "Nobody on that layer answered.", "close" },
      { requester({ stage = "closed", outcome = "expired", helper = "Bob" }), "did not invite you in time", "close" },
      { requester({ stage = "closed", outcome = "declined", helper = "Bob" }), "Bob cannot help right now", "close" },
      { requester({ stage = "closed", outcome = "cancelled" }), "Swap cancelled.", "close" },
      { requester({ stage = "closed", outcome = "unconfirmed", joined = true }), "Could not confirm", "leave,close" },
    }
    for _, case in ipairs(expectations) do
      local view = ViewModel.LayerSwapView(case[1])
      assert.is_truthy(view.text:find(case[2], 1, true), case[2])
      assert.are.equal(case[3], ids(view))
      assert.is_false(view.alert)
    end
  end)

  it("tells the helper what to do, and alerts only for a fresh request", function()
    local function helper(stage, offered)
      return ViewModel.LayerSwapView({ role = "helper", stage = stage, requester = "Ann|r", offered = offered })
    end
    assert.is_true(helper("request", false).alert)
    assert.are.equal("help,ignore", ids(helper("request", false)))
    assert.is_false(helper("request", true).alert)
    assert.is_truthy(helper("request", true).text:find("Offer sent", 1, true))
    assert.are.equal("invite,decline", ids(helper("assigned")))
    assert.is_truthy(helper("assigned").text:find("Ann||r", 1, true))
    assert.are.equal("decline", ids(helper("invited")))
  end)

  it("shows the countdown only when there is one", function()
    assert.are.equal("31 s left", ViewModel.LayerSwapView(requester({ left = 30.4 })).countdown)
    assert.is_nil(ViewModel.LayerSwapView(requester()).countdown)
  end)
end)

describe("ViewModel layers in Spanish", function()
  it("translates the tab and the sentences", function()
    local Spanish = load_view_model("esES")
    local view = Spanish.LayerSwapView({ role = "helper", stage = "request", requester = "Ann" })
    assert.is_truthy(view.text:find("quiere unirse a tu capa", 1, true))
    assert.are.equal("Ayudar", view.buttons[1].text)
  end)
end)
