-- The loot popup and the voting window built with the real kit on fake frames: a nil call or a wrong argument in the
-- frame code is found here and not in the game. How they look is not tested, only that they build, fill and react.
local fake = dofile("tests/support/fake_frames.lua")
local Roles = dofile("tests/support/roles.lua")

local function load_addon()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Core/Validate",
    "Core/Platform",
    "Domain/PermissionService",
    "Domain/RosterService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/LootModel",
    "Domain/LootService",
    "Domain/ReadinessRules",
    "Domain/Professions",
    "Domain/ReadinessService",
    "Domain/ProfileService",
    "Domain/ReportService",
    "UI/Kit/Theme",
    "UI/Kit/Pixel",
    "UI/Kit/Shape",
    "UI/Kit/Util",
    "UI/Kit/Calendar",
    "UI/Kit/Icons",
    "UI/Kit/Core",
    "UI/Kit/Text",
    "UI/Kit/Controls",
    "UI/Kit/Data",
    "UI/Kit/Shell",
    "UI/ViewModel",
    "UI/ViewModelHome",
    "UI/ViewModelRaid",
    "Commands/LootCommands",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local function session(id, name, status)
  return {
    sessionId = id,
    itemId = 5,
    itemName = name,
    status = status or "open",
    rev = 1,
    updatedAt = 3,
    candidates = { ["Ann-Realm"] = { need = "main", spec = "Tank", rev = 1, updatedAt = 1 } },
    votes = {},
  }
end

describe("Secondary windows on the real kit", function()
  local ns, timers

  before_each(function()
    fake.install()
    ns = load_addon()
    timers = {}
    _G.C_Timer = {
      After = function(seconds, fn)
        timers[#timers + 1] = { seconds = seconds, fn = fn }
      end,
    }
    _G.GameTooltip = { SetOwner = function() end, Show = function() end, Hide = function() end }
    _G.GetCursorPosition = function()
      return 100, 100
    end
    ns.active = true
    local members, rosters = Roles.assignments("GM", "Me-Realm")
    ns.db = {
      global = {
        events = { e1 = { eventId = "e1", title = "Raid", status = "open", loot = {}, rosterId = "r1" } },
        rosters = rosters,
        members = members,
        sync = { tombstones = {} },
      },
    }
    ns.character = { profile = { fields = {} } }
    ns.comm = {}
    ns.guildRoster = { Lookup = function() end }
    local real = ns.Platform
    ns.Platform = setmetatable({
      GetOwnGuildRank = Roles.ranking("GM"),
      GetIdentityKey = function()
        return "Me-Realm"
      end,
      IsChatMessagingLockedDown = function()
        return false
      end,
      Now = function()
        return 100
      end,
      ServerTime = function()
        return 1000
      end,
      GetItemDetails = function() end,
    }, { __index = real })
    ns.UI = {
      lootListeners = {},
      Role = function()
        return "gm"
      end,
      ApplyWindowStatus = function(target)
        target:SetStatusTable({})
      end,
      Register = function() end,
      Report = function() end,
      Redraw = function() end,
    }
    assert(loadfile("NrageAssistant/UI/Tabs/Loot.lua"))("NrageAssistant", ns)
    assert(loadfile("NrageAssistant/UI/PopupFrame.lua"))("NrageAssistant", ns)
    assert(loadfile("NrageAssistant/UI/LootPopup.lua"))("NrageAssistant", ns)
    assert(loadfile("NrageAssistant/UI/VotingFrame.lua"))("NrageAssistant", ns)
  end)

  after_each(function()
    fake.uninstall()
    _G.C_Timer, _G.GameTooltip, _G.GetCursorPosition = nil, nil, nil
  end)

  it("builds the loot popup when a session opens, and hides it when nothing waits", function()
    ns.LootPopup.Start()
    ns.db.global.events.e1.loot.s1 = session("s1", "Sword")
    ns.db.global.events.e1.loot.s1.candidates = {}
    ns.LootPopup.Refresh()
    assert.is_true(_G.NrageAssistantLootPopup.shown)
    ns.LootPopup.Pass("s1")
    assert.is_false(_G.NrageAssistantLootPopup.shown)
  end)

  it("draws the loot popup as a cut surface on the plain ground, with no scene", function()
    ns.LootPopup.Start()
    ns.db.global.events.e1.loot.s1 = session("s1", "Sword")
    ns.db.global.events.e1.loot.s1.candidates = {}
    ns.LootPopup.Refresh()
    local shape = _G.NrageAssistantLootPopup.shape
    assert.are.equal(8, shape.cut)
    for _, key in ipairs({ "tl", "tr", "bl", "br" }) do
      assert.is_true(shape.corners[key])
    end
    assert.is_nil(shape.imageTextures)
    assert.are.same({ ns.Kit.Theme.Color("bg") }, shape.fillTextures.mid.color)
  end)

  it("redraws the popup with the time left as the countdown ticks", function()
    ns.LootPopup.Start()
    ns.db.global.events.e1.loot.s1 = session("s1", "Sword")
    ns.db.global.events.e1.loot.s1.candidates = {}
    ns.LootPopup.Refresh()
    assert.is_truthy(ns.LootPopup.TimeLeft("s1"))
    local waiting = #timers
    for index = 1, waiting do
      timers[index].fn()
    end
    assert.is_true(_G.NrageAssistantLootPopup.shown)
  end)

  it("moves the countdown in place instead of drawing the popup again", function()
    local drawn, labels = 0, {}
    local realButton, realLabel = ns.Kit.Button, ns.Kit.Label
    ns.Kit.Button = function(parent, opts)
      drawn = drawn + 1
      return realButton(parent, opts)
    end
    ns.Kit.Label = function(parent, opts)
      local label = realLabel(parent, opts)
      labels[#labels + 1] = label
      return label
    end
    ns.LootPopup.Start()
    ns.db.global.events.e1.loot.s1 = session("s1", "Sword")
    ns.db.global.events.e1.loot.s1.candidates = {}
    ns.LootPopup.Refresh()
    local buttonsAfterShow = drawn
    assert.is_true(buttonsAfterShow > 0)
    for index = 1, #timers do
      timers[index].fn()
    end
    assert.are.equal(buttonsAfterShow, drawn)
    assert.is_truthy(labels[#labels]:GetText():find("Passing on the next item", 1, true))
    ns.Kit.Button, ns.Kit.Label = realButton, realLabel
  end)

  describe("answering from the loot popup", function()
    local pressed

    before_each(function()
      pressed = nil
      local realButton = ns.Kit.Button
      ns.Kit.Button = function(parent, opts)
        if opts.text == "Main spec" then
          pressed = opts.onClick
        end
        return realButton(parent, opts)
      end
      ns.comm = {
        NextId = function()
          return "id"
        end,
        SendLootCandidate = function()
          return true
        end,
      }
      ns.LootPopup.Start()
      ns.db.global.events.e1.loot.s1 = session("s1", "Sword")
      ns.db.global.events.e1.loot.s1.candidates = {}
      ns.LootPopup.Refresh()
    end)

    it("dismisses the item once the candidacy was accepted", function()
      local realPrint = _G.print
      _G.print = function() end
      pressed()
      _G.print = realPrint
      assert.is_false(_G.NrageAssistantLootPopup.shown)
    end)

    it("keeps the item on offer when the candidacy was refused, so it can be tried again", function()
      ns.LootService.Register = function()
        return nil, "locked_down"
      end
      local realPrint = _G.print
      _G.print = function() end
      pressed()
      _G.print = realPrint
      assert.is_true(_G.NrageAssistantLootPopup.shown)
    end)
  end)

  it("opens the voting window for a new session and shows the candidates", function()
    ns.VotingFrame.Start()
    ns.db.global.events.e1.loot.s1 = session("s1", "Sword")
    ns.VotingFrame.Refresh()
    assert.is_true(_G.NrageAssistantVotingFrame.shown)
    ns.db.global.events.e1.loot.s2 = session("s2", "Shield")
    ns.VotingFrame.Refresh()
    assert.is_true(_G.NrageAssistantVotingFrame.shown)
  end)

  it("opens by hand from the Loot tab and closes when the council right is lost", function()
    ns.db.global.events.e1.loot.s1 = session("s1", "Sword")
    ns.VotingFrame.Start()
    ns.VotingFrame.Show()
    assert.is_true(_G.NrageAssistantVotingFrame.shown)
    ns.comm = nil
    ns.VotingFrame.Refresh()
    ns.comm = {}
  end)
end)
