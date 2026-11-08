-- The compact window of Intel. The decisions about the secure buttons (FreezeOrder, Attributes, Binder) are pure and
-- tested first; then the window is built with the real kit on fake frames, where the overlays refuse to change in
-- combat the way protected frames do in the game, so a protected call in combat fails here and not in the game.
local FakeFrames = dofile("tests/support/fake_frames.lua")

local function load_addon()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/Settings",
    "Domain/PermissionService",
    "Domain/RosterService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/IntelModel",
    "Domain/IntelService",
    "Domain/GuildKosService",
    "Domain/IntelReport",
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
    "UI/ViewModelIntel",
    "UI/IntelWindow",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_addon()
local IntelWindow = ns.IntelWindow

local function rows_of(...)
  local list = {}
  for _, name in ipairs({ ... }) do
    list[#list + 1] = { name = name }
  end
  return list
end

local function states(slots, size)
  local out = {}
  for slot = 1, size do
    local info = slots[slot]
    out[slot] = info and (info.name .. ":" .. info.state) or "-"
  end
  return out
end

describe("IntelWindow.FreezeOrder", function()
  it("keeps a bound name in its slot, whatever the order of the rows", function()
    local slots, overflow = IntelWindow.FreezeOrder({ "Ann", "Bob", "Cid" }, rows_of("Cid", "Ann", "Bob"), 3)
    assert.are.same({ "Ann:bound", "Bob:bound", "Cid:bound" }, states(slots, 3))
    assert.are.equal(0, overflow)
    assert.are.equal("Ann", slots[1].row.name)
  end)

  it("leaves a name that left in its slot, greyed and with no row", function()
    local slots = IntelWindow.FreezeOrder({ "Ann", "Bob" }, rows_of("Bob"), 2)
    assert.are.same({ "Ann:left", "Bob:bound" }, states(slots, 2))
    assert.is_nil(slots[1].row)
  end)

  it("gives a newcomer a free slot and marks it as not clickable", function()
    local slots, overflow = IntelWindow.FreezeOrder({ "Ann", nil, "Cid" }, rows_of("Ann", "Dan", "Cid"), 3)
    assert.are.same({ "Ann:bound", "Dan:new", "Cid:bound" }, states(slots, 3))
    assert.are.equal(0, overflow)
    -- A free slot may also be marked `false`.
    slots = IntelWindow.FreezeOrder({ false, "Bob" }, rows_of("Eve", "Bob"), 2)
    assert.are.same({ "Eve:new", "Bob:bound" }, states(slots, 2))
  end)

  it("gives the newcomers the free slots in order, and counts those who find none", function()
    local slots, overflow = IntelWindow.FreezeOrder({ "Ann" }, rows_of("Ann", "Dan", "Eve", "Fay"), 3)
    assert.are.same({ "Ann:bound", "Dan:new", "Eve:new" }, states(slots, 3))
    assert.are.equal(1, overflow)
  end)

  it("never moves a name to a slot that is not its own", function()
    -- Ann left and Dan came: Dan does not take Ann's slot, which still belongs to her button.
    local slots = IntelWindow.FreezeOrder({ "Ann", "Bob", nil }, rows_of("Bob", "Dan"), 3)
    assert.are.same({ "Ann:left", "Bob:bound", "Dan:new" }, states(slots, 3))
  end)

  it("takes the size from the bound names, and an empty window stays empty", function()
    assert.are.same({ "Ann:bound" }, states(IntelWindow.FreezeOrder({ "Ann" }, rows_of("Ann")), 1))
    assert.are.same({ "-", "-" }, states(IntelWindow.FreezeOrder({}, {}, 2), 2))
    local slots, overflow = IntelWindow.FreezeOrder({}, rows_of("Ann"), 0)
    assert.are.same({}, slots)
    assert.are.equal(1, overflow)
  end)

  it("does not let one row fill two slots", function()
    local slots = IntelWindow.FreezeOrder({ "Ann", "Ann" }, rows_of("Ann"), 2)
    assert.are.same({ "Ann:bound", "Ann:left" }, states(slots, 2))
  end)
end)

describe("IntelWindow.Attributes", function()
  local function as_map(list)
    local map = {}
    for _, pair in ipairs(list) do
      map[pair[1]] = pair[2]
    end
    return map
  end

  it("targets the exact name with the left button and nothing else", function()
    local list = IntelWindow.Attributes("Ann")
    local map = as_map(list)
    assert.are.equal("macro", map.type1)
    assert.are.equal("/targetexact Ann", map.macrotext1)
    local prefixes = { "shift-", "ctrl-", "alt-", "shift-ctrl-", "shift-alt-", "ctrl-alt-", "shift-ctrl-alt-" }
    for _, prefix in ipairs(prefixes) do
      assert.are.equal("", map[prefix .. "type1"], prefix)
    end
    assert.is_nil(map.type2)
    assert.are.equal(9, #list)
  end)

  it("clears every attribute for no name or a name that is not clean", function()
    for _, name in ipairs({ false, 5, "", "Ann|n/macro", "Ann\n/run x", "a:b", string.rep("x", 60), "Ann-Realm" }) do
      local list = IntelWindow.Attributes(name or nil)
      assert.are.equal(9, #list, tostring(name))
      for _, pair in ipairs(list) do
        assert.is_nil(pair[2], tostring(name) .. " " .. pair[1])
      end
    end
    for _, pair in ipairs(IntelWindow.Attributes(nil)) do
      assert.is_nil(pair[2])
    end
  end)
end)

describe("IntelWindow.Binder", function()
  local combat, applied, binder

  before_each(function()
    combat = false
    applied = {}
    binder = IntelWindow.Binder.New({
      size = 3,
      canBind = function()
        return not combat
      end,
      apply = function(slot, name)
        applied[#applied + 1] = slot .. "=" .. tostring(name)
      end,
    })
  end)

  it("binds the rows in order outside combat, and only the slots that changed", function()
    local slots, overflow = binder:Update(rows_of("Ann", "Bob"))
    assert.are.same({ "1=Ann", "2=Bob" }, applied)
    assert.are.same({ "Ann:bound", "Bob:bound", "-" }, states(slots, 3))
    assert.are.equal(0, overflow)
    applied = {}
    binder:Update(rows_of("Ann", "Bob"))
    assert.are.same({}, applied)
    binder:Update(rows_of("Bob"))
    assert.are.same({ "1=Bob", "2=nil" }, applied)
    local _, extra = binder:Update(rows_of("A", "B", "C", "D", "E"))
    assert.are.equal(2, extra)
  end)

  it("touches nothing in combat and freezes the order", function()
    binder:Update(rows_of("Ann", "Bob"))
    applied = {}
    combat = true
    local slots = binder:Update(rows_of("Bob", "Cid"))
    assert.are.same({}, applied)
    assert.are.same({ "Ann:left", "Bob:bound", "Cid:new" }, states(slots, 3))
    combat = false
    slots = binder:Update(rows_of("Bob", "Cid"))
    assert.are.same({ "1=Bob", "2=Cid" }, applied)
    assert.are.same({ "Bob:bound", "Cid:bound", "-" }, states(slots, 3))
  end)

  it("changes the number of slots only outside combat, and clears the ones that go", function()
    binder:Update(rows_of("Ann", "Bob", "Cid"))
    applied = {}
    combat = true
    assert.are.same({ false, "combat" }, { binder:Resize(2) })
    assert.are.equal(3, binder.size)
    assert.are.same({}, applied)
    combat = false
    assert.is_true(binder:Resize(3))
    assert.is_true(binder:Resize(1))
    assert.are.same({ "2=nil", "3=nil" }, applied)
    assert.are.equal(1, binder.size)
    assert.is_true(binder:Resize(4))
    assert.are.equal(4, binder.size)
  end)
end)

-- ---------------------------------------------------------------------------------------------------------------
-- The frames

local SECURE_METHODS =
  { "SetAttribute", "SetPoint", "ClearAllPoints", "SetSize", "SetWidth", "SetHeight", "Show", "Hide", "SetShown" }

describe("IntelWindow.RowsForHeight", function()
  -- The chrome around the rows is 88 (header 30, tabs 30, footer 20, padding 8); a row is 22.
  it("gives the rows of an exact height", function()
    assert.are.equal(1, IntelWindow.RowsForHeight(88 + 22))
    assert.are.equal(8, IntelWindow.RowsForHeight(88 + 8 * 22))
    assert.are.equal(20, IntelWindow.RowsForHeight(88 + 20 * 22))
  end)

  it("rounds to the nearest row", function()
    assert.are.equal(3, IntelWindow.RowsForHeight(88 + 3 * 22 + 10))
    assert.are.equal(4, IntelWindow.RowsForHeight(88 + 3 * 22 + 11))
    assert.are.equal(3, IntelWindow.RowsForHeight(88 + 3 * 22 - 10))
  end)

  it("keeps the rows between 1 and ROWS_MAX", function()
    assert.are.equal(1, IntelWindow.RowsForHeight(0))
    assert.are.equal(1, IntelWindow.RowsForHeight(-50))
    assert.are.equal(IntelWindow.ROWS_MAX, IntelWindow.RowsForHeight(100000))
  end)

  it("gives the smallest window for what is not a number", function()
    assert.are.equal(1, IntelWindow.RowsForHeight(nil))
    assert.are.equal(1, IntelWindow.RowsForHeight("200"))
    assert.are.equal(1, IntelWindow.RowsForHeight(0 / 0))
  end)
end)

describe("IntelWindow on fake frames", function()
  local env
  local NAMES =
    { "GameTooltip", "CreateFrame", "print", "C_Timer", "Minimap", "UIParent", "SecureActionButtonTemplate" }
  local saved = {}

  local function seen(name, extra)
    local details = { name = name, class = "MAGE", race = "HUMAN", level = 60, guild = "Wolves" }
    for key, value in pairs(extra or {}) do
      details[key] = value
    end
    return ns.intel:OnSeen(details, { map = 1, x = 10, y = 20 })
  end

  local function overlay_attr(index, name)
    return env.overlays[index] and env.overlays[index].attributes[name]
  end

  before_each(function()
    FakeFrames.install()
    for _, name in ipairs(NAMES) do
      saved[name] = _G[name]
    end
    IntelWindow.Reset()
    env = { combat = false, overlays = {}, said = {}, timers = {}, protectedCalls = {}, menus = {}, clock = 1000 }

    -- A client that refuses to change a secure frame in combat.
    local fakeCreate = _G.CreateFrame
    _G.CreateFrame = function(kind, name, parent, template)
      local frame = fakeCreate(kind, name, parent)
      if template == "SecureActionButtonTemplate" then
        assert.is_false(env.combat, "a secure overlay was created in combat")
        frame.template = template
        frame.attributes = {}
        frame.anchors = {}
        for _, method in ipairs(SECURE_METHODS) do
          local original = frame[method]
          frame[method] = function(self, ...)
            if env.combat then
              env.protectedCalls[#env.protectedCalls + 1] = method
              error("protected: " .. method .. " in combat")
            end
            if method == "SetAttribute" then
              local key, value = ...
              self.attributes[key] = value
              return
            end
            if method == "SetPoint" then
              self.anchors[#self.anchors + 1] = select(2, ...)
            end
            return original(self, ...)
          end
        end
        env.overlays[#env.overlays + 1] = frame
      end
      return frame
    end
    _G.print = function(text)
      env.said[#env.said + 1] = text
    end
    _G.C_Timer = {
      After = function(seconds, fn)
        env.timers[#env.timers + 1] = { seconds = seconds, fn = fn }
      end,
    }
    local tooltip = { lines = {} }
    function tooltip:SetOwner(owner)
      self.owner = owner
      self.lines = {}
    end
    function tooltip:AddLine(text)
      self.lines[#self.lines + 1] = text
    end
    function tooltip:Show()
      self.shown = true
    end
    function tooltip:Hide()
      self.shown = false
    end
    _G.GameTooltip = tooltip

    -- The buttons of the header, caught as they are made.
    env.buttons = {}
    env.realIconButton = ns.Kit.IconButton
    ns.Kit.IconButton = function(parent, opts)
      local widget = env.realIconButton(parent, opts)
      env.buttons[opts.icon] = widget
      return widget
    end
    env.realMenu = ns.Kit.Menu
    ns.Kit.Menu = {
      Open = function(anchor, items, onSelect)
        env.menu = { anchor = anchor, items = items, onSelect = onSelect }
      end,
      Close = function() end,
    }

    ns.active = true
    ns.db = { global = {} }
    ns.IntelNearby = function()
      return ns.intel:Nearby(env.clock)
    end
    ns.intel = ns.IntelService.New({
      intel = { players = {}, kos = {}, ignore = {}, zones = {} },
      guildKos = {},
      settings = function()
        return { removeMinutes = 5 }
      end,
      now = function()
        return env.clock
      end,
      wall = function()
        return 100000
      end,
    })
    ns.intelCommands = {
      Changed = function()
        env.changed = (env.changed or 0) + 1
      end,
      Clear = function()
        env.cleared = true
        ns.intel:ClearNearby()
      end,
      KosAdd = function(_, name)
        ns.intel:AddKos({ name = name })
        return { "added " .. name }
      end,
      KosRemove = function(_, name)
        ns.intel:RemoveKos(ns.IntelModel.Key(name))
        return { "removed " .. name }
      end,
      IgnoreAdd = function(_, name)
        ns.intel:AddIgnore(name)
        return { "ignoring " .. name }
      end,
      IgnoreRemove = function(_, name)
        ns.intel:RemoveIgnore(ns.IntelModel.Key(name))
        return { "not ignoring " .. name }
      end,
      GuildAdd = function()
        return { "guild" }
      end,
      GuildRemove = function()
        return { "unguild" }
      end,
    }
    ns.intelDirectory = { Remove = function() end }
    ns.intelAlerts = {
      AnnounceNow = function(_, name, channel)
        env.announced = name .. ":" .. channel
        return true
      end,
    }
    ns.UI = {
      Role = function()
        return "member"
      end,
      ApplyWindowStatus = function(target, name)
        env.statusName = env.statusName or {}
        env.statusName[#env.statusName + 1] = name
        env.status = env.status or {}
        env.status[name] = env.status[name] or { width = 400, left = 50, top = 600 }
        target:SetStatusTable(env.status[name])
      end,
      OpenIntelTab = function(view)
        env.opened = view
      end,
    }
    ns.Platform = {
      IsInCombat = function()
        return env.combat
      end,
      ServerTime = function()
        return 100000
      end,
      FormatDate = function(at)
        return "d" .. at
      end,
      GetIdentityKey = function()
        return "Me-Realm"
      end,
      GroupDistribution = function()
        return nil
      end,
      IsInGuild = function()
        return true
      end,
      TryRegisterEvent = function(frame, event)
        env.registered = env.registered or {}
        env.registered[event] = frame
        return true
      end,
      ModifierKeys = function()
        return env.shift == true, env.ctrl == true, false
      end,
    }
  end)

  after_each(function()
    ns.Kit.IconButton = env.realIconButton
    ns.Kit.Menu = env.realMenu
    FakeFrames.uninstall()
    for _, name in ipairs(NAMES) do
      _G[name] = saved[name]
    end
    IntelWindow.Reset()
  end)

  local function click(index, button)
    IntelWindow.Overlays()[index].scripts.PostClick(IntelWindow.Overlays()[index], button or "LeftButton")
  end

  describe("outside combat", function()
    it("makes the window and one secure overlay per row, once", function()
      assert.is_true(IntelWindow.Show())
      local frame = IntelWindow.Frame()
      assert.is_true(frame:IsShown())
      assert.are.equal(IntelWindow.ROWS_MAX, #env.overlays)
      assert.are.equal(IntelWindow.ROWS_MAX, #IntelWindow.Rows())
      IntelWindow.Show()
      assert.are.equal(IntelWindow.ROWS_MAX, #env.overlays)
      assert.is_true(ns.db.global.settings.intel.window.shown)
      -- The overlays hold no action while nobody is listed.
      assert.is_nil(overlay_attr(1, "type1"))
      assert.are.same({ "intelWindow" }, env.statusName)
    end)

    it("targets the exact name of each row, and only its own", function()
      seen("Ann")
      seen("Bob")
      IntelWindow.Show()
      assert.are.equal("macro", overlay_attr(1, "type1"))
      assert.are.equal("/targetexact Ann", overlay_attr(1, "macrotext1"))
      assert.are.equal("/targetexact Bob", overlay_attr(2, "macrotext1"))
      assert.are.equal("", overlay_attr(1, "shift-type1"))
      assert.is_nil(overlay_attr(3, "macrotext1"))
      local drawn = IntelWindow.Drawn()
      assert.are.equal("Ann", drawn[1].name)
      assert.are.equal("Bob", drawn[2].name)
      assert.are.equal("Ann", IntelWindow.Rows()[1].name.text)
    end)

    it("follows who is nearby: a row that goes frees its overlay", function()
      seen("Ann")
      seen("Bob")
      IntelWindow.Show()
      ns.intel:RemoveNearby("ann")
      IntelWindow.Refresh()
      assert.are.equal("/targetexact Bob", overlay_attr(1, "macrotext1"))
      assert.is_nil(overlay_attr(2, "macrotext1"))
      assert.is_false(IntelWindow.Rows()[2]:IsShown())
      assert.are.equal("", IntelWindow.Frame().empty.text)
    end)

    it("shows the empty text and how many more there are", function()
      IntelWindow.Show()
      assert.are.equal("Nobody nearby.", IntelWindow.Frame().empty.text)
      ns.db.global.settings.intel.window.rows = 1
      seen("Ann")
      seen("Bob")
      IntelWindow.Refresh()
      assert.are.equal("", IntelWindow.Frame().empty.text)
      assert.are.equal("and 1 more", IntelWindow.Frame().more.text)
    end)

    it("fades a row near the end of its time and marks Kill on Sight players", function()
      ns.intel:AddKos({ name = "Ann" })
      seen("Ann")
      seen("Bob")
      env.clock = env.clock + 200
      seen("Bob")
      IntelWindow.Show()
      local ann, bob = IntelWindow.Rows()[1], IntelWindow.Rows()[2]
      assert.are.equal("!", ann.mark.text)
      assert.are.equal("", bob.mark.text)
      assert.are.equal(0.5, ann.alpha)
      assert.are.equal(1, bob.alpha)
    end)

    it("applies a new number of rows and moves the overlays with it", function()
      IntelWindow.Show()
      local before = IntelWindow.Frame().height
      ns.db.global.settings.intel.window.rows = 4
      IntelWindow.Refresh()
      assert.is_true(IntelWindow.Frame().height < before)
      assert.is_false(env.overlays[5].shown)
      assert.is_true(env.overlays[4].shown)
      seen("A")
      seen("B")
      seen("C")
      seen("D")
      seen("E")
      IntelWindow.Refresh()
      assert.is_nil(overlay_attr(5, "macrotext1"))
      ns.db.global.settings.intel.window.rows = 2
      IntelWindow.Refresh()
      assert.is_nil(overlay_attr(3, "macrotext1"))
      assert.is_truthy(overlay_attr(2, "macrotext1"))
    end)
  end)

  describe("the clicks", function()
    it("does nothing on a plain left click, which the secure button handles", function()
      seen("Ann")
      IntelWindow.Show()
      click(1, "LeftButton")
      assert.is_nil(ns.intel:IsKos("Ann"))
      assert.are.same({}, env.said)
    end)

    it("toggles Kill on Sight with Shift and Ignore with Ctrl", function()
      seen("Ann")
      IntelWindow.Show()
      env.shift = true
      click(1)
      assert.are.equal("personal", ns.intel:IsKos("Ann"))
      assert.are.same({ "Nrage Assistant: added Ann" }, env.said)
      click(1)
      assert.is_nil(ns.intel:IsKos("Ann"))
      env.shift, env.ctrl = false, true
      click(1)
      assert.is_true(ns.intel:IsIgnored("Ann"))
      -- The row goes: ignored players are not listed.
      assert.is_nil(overlay_attr(1, "macrotext1"))
    end)

    it("opens the menu of the row from the right button and runs a choice", function()
      seen("Ann")
      IntelWindow.Show()
      click(1, "RightButton")
      assert.are.equal(IntelWindow.Rows()[1], env.menu.anchor)
      local values = {}
      for _, item in ipairs(env.menu.items) do
        values[item.value] = item
      end
      assert.is_truthy(values.remove and values.kos and values.ignore)
      env.menu.onSelect("say:guild")
      assert.are.equal("Ann:guild", env.announced)
      env.menu.onSelect("remove")
      assert.are.equal(0, #ns.intel:Nearby(env.clock))
    end)

    it("tells the player why an action failed", function()
      seen("Ann")
      IntelWindow.Show()
      ns.intelAlerts.AnnounceNow = function()
        return false, "no_group"
      end
      click(1, "RightButton")
      env.menu.onSelect("say:party")
      assert.are.same({ "Nrage Assistant: Not done: you are not in a group for that." }, env.said)
    end)

    it("ignores a click on an empty row or while Intel is not running", function()
      IntelWindow.Show()
      click(5, "RightButton")
      assert.is_nil(env.menu)
      seen("Ann")
      IntelWindow.Refresh()
      ns.intelCommands = nil
      click(1, "RightButton")
      assert.is_nil(env.menu)
    end)

    it("shows a tooltip over a row and hides it again", function()
      seen("Ann")
      IntelWindow.Show()
      local overlay = IntelWindow.Overlays()[1]
      overlay.scripts.OnEnter(overlay)
      assert.are.equal(IntelWindow.Rows()[1], _G.GameTooltip.owner)
      assert.are.equal("Ann", _G.GameTooltip.lines[1])
      assert.is_true(_G.GameTooltip.shown)
      assert.is_true(IntelWindow.Rows()[1].hover:IsShown())
      overlay.scripts.OnLeave(overlay)
      assert.is_false(_G.GameTooltip.shown)
      assert.is_false(IntelWindow.Rows()[1].hover:IsShown())
      _G.GameTooltip = nil
      assert.has_no.errors(function()
        overlay.scripts.OnEnter(overlay)
        overlay.scripts.OnLeave(overlay)
      end)
      click(1)
    end)
  end)

  describe("in combat", function()
    it("freezes the order and changes no secure frame", function()
      seen("Ann")
      seen("Bob")
      IntelWindow.Show()
      env.combat = true
      -- Ann leaves, Cid arrives: Ann stays greyed in her slot, Cid cannot be targeted and takes the free one.
      ns.intel:RemoveNearby("ann")
      seen("Cid")
      env.clock = env.clock + 1
      IntelWindow.Refresh()
      assert.are.same({}, env.protectedCalls)
      local rows = IntelWindow.Rows()
      assert.are.equal("Ann", rows[1].name.text)
      assert.are.equal(0.35, rows[1].alpha)
      assert.are.equal("Bob", rows[2].name.text)
      assert.are.equal("Cid", rows[3].name.text)
      assert.are.equal(0.75, rows[3].alpha)
      assert.are.equal("/targetexact Ann", overlay_attr(1, "macrotext1"))
      assert.are.equal("/targetexact Bob", overlay_attr(2, "macrotext1"))
      assert.is_nil(overlay_attr(3, "macrotext1"))
      -- Shift still works on what is drawn: it is no protected action.
      env.shift = true
      click(3)
      assert.are.equal("personal", ns.intel:IsKos("Cid"))
      -- When combat ends, the rows are bound again (Cid is a Kill on Sight player now, so he comes first).
      env.combat = false
      IntelWindow.OnRegen()
      assert.are.equal("/targetexact Cid", overlay_attr(1, "macrotext1"))
      assert.are.equal("/targetexact Bob", overlay_attr(2, "macrotext1"))
      assert.are.equal("Cid", rows[1].name.text)
      assert.are.equal(1, rows[1].alpha)
    end)

    it("refuses a new row count and applies it when combat ends", function()
      IntelWindow.Show()
      local height = IntelWindow.Frame().height
      env.combat = true
      ns.db.global.settings.intel.window.rows = 3
      IntelWindow.Refresh()
      assert.are.equal(height, IntelWindow.Frame().height)
      assert.are.same({}, env.protectedCalls)
      env.combat = false
      IntelWindow.OnRegen()
      assert.is_true(IntelWindow.Frame().height < height)
      assert.is_false(env.overlays[4].shown)
    end)

    it("makes the overlays only when combat ends if the window was first opened in combat", function()
      seen("Ann")
      env.combat = true
      assert.is_true(IntelWindow.Show())
      assert.are.equal(0, #env.overlays)
      assert.is_true(IntelWindow.Frame():IsShown())
      -- The row is drawn but nothing can target it yet.
      assert.are.equal("Ann", IntelWindow.Rows()[1].name.text)
      assert.are.equal(0.75, IntelWindow.Rows()[1].alpha)
      IntelWindow.Refresh()
      assert.are.equal(0, #env.overlays)
      env.combat = false
      IntelWindow.OnRegen()
      assert.are.equal(IntelWindow.ROWS_MAX, #env.overlays)
      assert.are.equal("/targetexact Ann", overlay_attr(1, "macrotext1"))
      assert.are.equal(1, IntelWindow.Rows()[1].alpha)
    end)

    it("opens and closes only when combat ends, once the overlays exist", function()
      IntelWindow.Show()
      local window = IntelWindow.Frame()
      local showCalls, hideCalls = 0, 0
      local show, hide = window.Show, window.Hide
      window.Show = function(self)
        showCalls = showCalls + 1
        return show(self)
      end
      window.Hide = function(self)
        hideCalls = hideCalls + 1
        return hide(self)
      end

      env.combat = true
      IntelWindow.Hide()
      assert.are.equal(0, hideCalls)
      assert.is_true(IntelWindow.IsShown())
      assert.is_false(ns.Settings.Intel(ns.db).window.shown)
      IntelWindow.Sync()
      assert.are.equal(0, hideCalls)

      env.combat = false
      IntelWindow.OnRegen()
      assert.are.equal(1, hideCalls)
      assert.is_false(IntelWindow.IsShown())

      env.combat = true
      assert.is_false(IntelWindow.Show())
      assert.are.equal(0, showCalls)
      assert.is_true(ns.Settings.Intel(ns.db).window.shown)

      env.combat = false
      IntelWindow.OnRegen()
      assert.are.equal(1, showCalls)
      assert.is_true(IntelWindow.IsShown())
    end)

    it("anchors each overlay to the window and never to a row", function()
      IntelWindow.Show()
      for _, overlay in ipairs(env.overlays) do
        assert.is_true(#overlay.anchors > 0)
        for _, anchor in ipairs(overlay.anchors) do
          assert.are.equal(IntelWindow.Frame(), anchor)
        end
      end
    end)

    it("does not move or size the window by hand", function()
      IntelWindow.Show()
      local frame = IntelWindow.Frame()
      local moved, sized = 0, 0
      frame.StartMoving = function()
        moved = moved + 1
      end
      frame.StartSizing = function()
        sized = sized + 1
      end
      env.combat = true
      frame.scripts.OnDragStart(frame)
      frame.grip.scripts.OnMouseDown()
      assert.are.same({ 0, 0 }, { moved, sized })
      env.combat = false
      frame.scripts.OnDragStart(frame)
      frame.grip.scripts.OnMouseDown()
      assert.are.same({ 1, 1 }, { moved, sized })
      ns.db.global.settings.intel.window.locked = true
      frame.scripts.OnDragStart(frame)
      frame.grip.scripts.OnMouseDown()
      assert.are.same({ 1, 1 }, { moved, sized })
    end)
  end)

  describe("place and size", function()
    it("takes the saved width and place, and saves them after a drag or a resize", function()
      IntelWindow.Show()
      local frame = IntelWindow.Frame()
      assert.are.equal(400, frame.width)
      frame.GetLeft = function()
        return 77
      end
      frame.GetTop = function()
        return 555
      end
      frame.scripts.OnDragStop(frame)
      assert.are.equal(77, env.status.intelWindow.left)
      assert.are.equal(555, env.status.intelWindow.top)
      frame.grip.scripts.OnMouseUp()
      assert.are.equal(400, env.status.intelWindow.width)
      frame.scripts.OnSizeChanged()
    end)

    it("sizes from the bottom right and turns the dragged height into rows on release", function()
      IntelWindow.Show()
      local frame = IntelWindow.Frame()
      local anchor
      frame.StartSizing = function(_, point)
        anchor = point
      end
      frame.grip.scripts.OnMouseDown()
      assert.are.equal("BOTTOMRIGHT", anchor)
      frame:SetHeight(88 + 5 * 22 + 4)
      frame.grip.scripts.OnMouseUp()
      assert.are.equal(5, ns.db.global.settings.intel.window.rows)
      assert.are.equal(88 + 5 * 22, frame.height)
      assert.is_true(env.overlays[5].shown)
      assert.is_false(env.overlays[6].shown)
    end)

    it("leaves the rows alone when the grip did not start sizing", function()
      IntelWindow.Show()
      local frame = IntelWindow.Frame()
      local rows = ns.db.global.settings.intel.window.rows
      ns.db.global.settings.intel.window.locked = true
      frame.grip.scripts.OnMouseDown()
      frame:SetHeight(88 + 2 * 22)
      frame.grip.scripts.OnMouseUp()
      assert.are.equal(rows, ns.db.global.settings.intel.window.rows)
    end)

    it("keeps the width between the limits", function()
      env.status = { intelWindow = { width = 90000 } }
      IntelWindow.Show()
      local _, max = IntelWindow.WIDTH_LIMITS()
      assert.are.equal(max, IntelWindow.Frame().width)
    end)

    it("works with a status that holds nothing", function()
      env.status = { intelWindow = {} }
      IntelWindow.Show()
      assert.are.equal(340, IntelWindow.Frame().width)
    end)
  end)

  describe("the header", function()
    it("clears who is nearby", function()
      seen("Ann")
      IntelWindow.Show()
      env.buttons.trash.frame.scripts.OnClick()
      assert.is_true(env.cleared)
      assert.are.equal(0, #ns.intel:Nearby(env.clock))
    end)

    it("mutes the sounds and turns them on again", function()
      IntelWindow.Show()
      local settings = ns.db.global.settings.intel
      env.buttons.alert.frame.scripts.OnClick()
      assert.is_false(settings.sound)
      assert.are.equal("Turn the alert sounds on", env.buttons.alert.opts.tooltip)
      assert.are.equal("danger", env.buttons.alert.opts.color)
      env.buttons.alert.frame.scripts.OnClick()
      assert.is_true(settings.sound)
      assert.are.equal("Mute the alert sounds", env.buttons.alert.opts.tooltip)
    end)

    it("opens the Intel tab and closes the window", function()
      IntelWindow.Show()
      env.buttons.list.frame.scripts.OnClick()
      assert.are.equal("nearby", env.opened)
      env.buttons.close.frame.scripts.OnClick()
      assert.is_false(IntelWindow.IsShown())
      assert.is_false(ns.db.global.settings.intel.window.shown)
      ns.UI.OpenIntelTab = nil
      IntelWindow.Show()
      assert.has_no.errors(function()
        env.buttons.list.frame.scripts.OnClick()
      end)
    end)

    it("switches between the lists", function()
      ns.intel:AddKos({ name = "Dan", category = "camp" })
      IntelWindow.Show()
      local segmented = IntelWindow.Frame().bar.items[1].obj
      segmented.opts.onChange("kos")
      assert.are.equal("Dan", IntelWindow.Rows()[1].name.text)
      assert.are.equal("/targetexact Dan", overlay_attr(1, "macrotext1"))
      segmented.opts.onChange("ignored")
      assert.are.equal("", IntelWindow.Frame().more.text)
      assert.are.equal("Nobody is ignored.", IntelWindow.Frame().empty.text)
    end)
  end)

  describe("showing and hiding", function()
    it("does not open without the addon, a database or Intel", function()
      ns.active = false
      assert.is_false(IntelWindow.Show())
      ns.active = true
      ns.intel = nil
      assert.is_false(IntelWindow.Show())
      assert.is_nil(IntelWindow.Frame())
      IntelWindow.Refresh()
      IntelWindow.Sync()
      IntelWindow.OnRegen()
      ns.db = nil
      IntelWindow.Hide()
      assert.is_false(IntelWindow.IsShown())
    end)

    it("follows the setting", function()
      IntelWindow.Sync()
      assert.is_true(IntelWindow.IsShown())
      ns.db.global.settings.intel.window.shown = false
      IntelWindow.Sync()
      assert.is_false(IntelWindow.IsShown())
      ns.db.global.settings.intel.window.shown = true
      IntelWindow.Sync()
      assert.is_true(IntelWindow.IsShown())
    end)

    it("starts once: it listens for the end of combat and opens the window if it was left open", function()
      IntelWindow.Start()
      assert.is_truthy(env.registered.PLAYER_REGEN_ENABLED)
      assert.is_true(IntelWindow.IsShown())
      local frame = env.registered.PLAYER_REGEN_ENABLED
      IntelWindow.Start()
      assert.are.equal(frame, env.registered.PLAYER_REGEN_ENABLED)
      assert.has_no.errors(function()
        frame.scripts.OnEvent()
      end)
      ns.active = false
      frame.scripts.OnEvent()
    end)

    it("stays closed at the start when the player closed it", function()
      ns.db.global.settings = { intel = { window = { shown = false } } }
      IntelWindow.Start()
      assert.is_false(IntelWindow.IsShown())
    end)
  end)

  describe("the warning", function()
    it("shows the text tinted by the kind, for a few seconds", function()
      assert.is_true(IntelWindow.Warn("Kill on Sight: Ann", "kos"))
      local warning = IntelWindow.WarningFrame()
      assert.is_true(warning:IsShown())
      assert.are.equal("Kill on Sight: Ann", warning.text.text)
      assert.are.equal(6, env.timers[1].seconds)
      env.timers[1].fn()
      assert.is_false(warning:IsShown())
    end)

    it("tints the class name with the class colour and escapes the rest", function()
      IntelWindow.Warn("Kill on Sight: Mage|x (Mage, level 60) <G>", "kos", "MAGE")
      assert.are.equal("Kill on Sight: Mage||x (|cff3fc7ebMage|r, level 60) <G>", IntelWindow.WarningFrame().text.text)
      IntelWindow.Warn("Kill on Sight: Ann (level 60)", "kos", "NOTACLASS")
      assert.are.equal("Kill on Sight: Ann (level 60)", IntelWindow.WarningFrame().text.text)
    end)

    it("lets the last warning keep the frame", function()
      IntelWindow.Warn("one", "new")
      IntelWindow.Warn("two", "stealth")
      env.timers[1].fn()
      assert.is_true(IntelWindow.WarningFrame():IsShown())
      env.timers[2].fn()
      assert.is_false(IntelWindow.WarningFrame():IsShown())
      assert.are.equal("two", IntelWindow.WarningFrame().text.text)
    end)

    it("escapes the text and remembers where the player moved it", function()
      IntelWindow.Warn("a|cffff0000b", "kos")
      local warning = IntelWindow.WarningFrame()
      assert.are.equal("a||cffff0000b", warning.text.text)
      warning.GetLeft = function()
        return 12
      end
      warning.GetTop = function()
        return 34
      end
      warning.scripts.OnDragStart(warning)
      warning.scripts.OnDragStop(warning)
      assert.are.equal(12, env.status.intelWarning.left)
      assert.are.equal(34, env.status.intelWarning.top)
    end)

    it("says it could not when there is nothing to show or the frame cannot be made", function()
      assert.is_false(IntelWindow.Warn(nil, "kos"))
      assert.is_false(IntelWindow.Warn(5, "kos"))
      local real = ns.UI.ApplyWindowStatus
      ns.UI.ApplyWindowStatus = function()
        error("no status")
      end
      assert.is_false(IntelWindow.Warn("text", "kos"))
      ns.UI.ApplyWindowStatus = real
      ns.db = nil
      assert.is_false(IntelWindow.Warn("text", "kos"))
    end)
  end)
end)
