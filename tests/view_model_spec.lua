local function load_view_model()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/UI/ViewModel.lua"))("NrageAssistant", ns)
  return ns.ViewModel, ns.Constants
end

local ViewModel, Constants = load_view_model()

describe("ViewModel.Escape", function()
  it("doubles pipes so text cannot start a colour code or link", function()
    assert.are.equal("||cffff0000red||r", ViewModel.Escape("|cffff0000red|r"))
  end)

  it("accepts non-strings", function()
    assert.are.equal("60", ViewModel.Escape(60))
  end)
end)

describe("ViewModel.Home", function()
  it("shows version, readiness and sync state", function()
    local text = table.concat(ViewModel.Home({
      version = "0.1.0",
      readinessText = "1/3 met, 2 unknown",
      syncLines = { "sync paused: encounter in progress", "queued messages: 1" },
    }), "\n")
    assert.is_truthy(text:find("Nrage Assistant 0.1.0", 1, true))
    assert.is_truthy(text:find("Your readiness: 1/3 met, 2 unknown", 1, true))
    assert.is_truthy(text:find("  sync paused: encounter in progress", 1, true))
  end)

  it("escapes sync lines, which can contain sender names", function()
    local text = table.concat(ViewModel.Home({
      version = "dev", readinessText = "0/0 met", syncLines = { "  |cffff0000Evil-Realm - addon 1" },
    }), "\n")
    assert.is_nil(text:find("[^|]|c"))
    assert.is_truthy(text:find("||cffff0000Evil-Realm", 1, true))
  end)
end)

describe("ViewModel.Roster", function()
  local now = 1000000

  it("explains an empty roster", function()
    local lines = ViewModel.Roster({}, now)
    assert.are.equal(1, #lines)
    assert.is_truthy(lines[1]:find("No profiles received yet", 1, true))
  end)

  it("lists profiles sorted by name and labelled as received", function()
    local lines = ViewModel.Roster({
      ["Zed-Realm"] = { class = "MAGE", level = 60, receivedAt = now - 10 },
      ["Ann-Realm"] = { class = "WARRIOR", level = 58, ilvl = 190, fields = { role = "tank" }, receivedAt = now - 10 },
    }, now)
    assert.are.equal("2 profile(s) received:", lines[1])
    assert.are.equal("  Ann-Realm - WARRIOR 58, ilvl 190, role tank [received]", lines[2])
    assert.are.equal("  Zed-Realm - MAGE 60 [received]", lines[3])
  end)

  it("labels old data as stale, never as received", function()
    local lines = ViewModel.Roster({
      ["Old-Realm"] = { class = "MAGE", level = 60, receivedAt = now - Constants.ROSTER_STALE_SECONDS - 1 },
    }, now)
    assert.is_truthy(lines[2]:find("[stale]", 1, true))
    assert.is_nil(lines[2]:find("[received]", 1, true))
  end)

  it("treats a missing timestamp as stale", function()
    local lines = ViewModel.Roster({ ["X-Realm"] = { class = "MAGE", level = 1 } }, now)
    assert.is_truthy(lines[2]:find("[stale]", 1, true))
  end)

  it("escapes received text", function()
    local lines = ViewModel.Roster({
      ["|cffff0000Bad-Realm"] = {
        class = "MAGE", level = 1, fields = { role = "|Hitem:1|h" }, receivedAt = now,
      },
    }, now)
    assert.is_truthy(lines[2]:find("||cffff0000Bad-Realm", 1, true))
    assert.is_truthy(lines[2]:find("||Hitem:1||h", 1, true))
  end)
end)

describe("ViewModel misc", function()
  it("turns a publish failure reason into a sentence", function()
    assert.is_truthy(ViewModel.PublishError("no_consent"):find("consent", 1, true))
    assert.are.equal("something_new", ViewModel.PublishError("something_new"))
  end)

  it("offers a tab for each view", function()
    local values = {}
    for _, tab in ipairs(ViewModel.TABS) do values[tab.value] = true end
    assert.are.same({ home = true, profile = true, ready = true, roster = true }, values)
  end)

  it("documents every user command in the help", function()
    local text = table.concat(ViewModel.HelpLines(), "\n")
    for _, command in ipairs({ "role", "profile", "ready", "consent", "publish", "sync", "help", "version" }) do
      assert.is_truthy(text:find("/nrage " .. command, 1, true), command)
    end
  end)
end)
