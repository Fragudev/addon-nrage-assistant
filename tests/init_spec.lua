-- Core/Init.lua wires the whole addon at load time, so these specs load every file in TOC order, replace the
-- client-facing pieces with spies and drive the real event handlers.
local function build()
  local frames, printed = {}, {}
  local saved = {
    CreateFrame = _G.CreateFrame,
    print = _G.print,
    C_Timer = _G.C_Timer,
    NrageAssistantDB = _G.NrageAssistantDB,
  }

  _G.CreateFrame = function()
    local frame = { events = {} }
    function frame:RegisterEvent(event)
      self.events[event] = true
    end
    function frame:UnregisterEvent(event)
      self.events[event] = nil
    end
    function frame:SetScript(name, fn)
      self[name] = fn
    end
    frames[#frames + 1] = frame
    return frame
  end
  _G.print = function(text)
    printed[#printed + 1] = text
  end
  _G.C_Timer = {
    After = function() end,
    NewTicker = function() end,
  }
  _G.NrageAssistantDB = nil

  local ns = {}
  dofile("tests/support/addon.lua")(ns)

  local platform = ns.Platform
  platform.IsInGuild = function()
    return true
  end
  platform.GetGuildClubId = function()
    return ns.Constants.GUILD_CLUB_ID
  end
  platform.GetFaction = function()
    return ns.Constants.FACTION
  end
  platform.GetRealmName = function()
    return "Test" .. ns.Constants.RULESET_REALM_MARKER
  end
  platform.GetLegacyIdentityKey = function()
    return "Me-Realm"
  end
  platform.LootWindowAvailable = function()
    return true
  end

  local calls = {}
  local function spy(owner, name, label)
    owner[name] = function()
      calls[#calls + 1] = label
    end
  end
  ns.Comm.Start = function()
    calls[#calls + 1] = "comm"
    ns.comm = ns.comm or {}
    return ns.comm
  end
  platform.ServerTime = os.time
  spy(ns.MinimapButton, "Create", "minimap")
  spy(ns.MinimapButton, "Refresh", "minimapRefresh")
  spy(ns.LootPopup, "Start", "lootPopup")
  spy(ns.VotingFrame, "Start", "votingFrame")
  spy(ns.LayerPopup, "Start", "layerPopup")
  ns.GuildRoster.New = function()
    calls[#calls + 1] = "roster"
    return {
      Request = function() end,
      Rebuild = function() end,
      Reset = function()
        calls[#calls + 1] = "rosterReset"
      end,
    }
  end
  ns.ProfileService.Refresh = function() end
  ns.EventService.Purge = function() end

  local env = { ns = ns, frames = frames, printed = printed, calls = calls }

  -- The addon frame is the first one created by Init.lua after the files before it created theirs.
  function env.mainFrame()
    for _, frame in ipairs(frames) do
      if frame.events.PLAYER_LOGIN then
        return frame
      end
    end
  end

  function env.fire(event, ...)
    env.mainFrame().OnEvent(env.mainFrame(), event, ...)
  end

  function env.lootFrames()
    local count = 0
    for _, frame in ipairs(frames) do
      if frame.events.LOOT_OPENED then
        count = count + 1
      end
    end
    return count
  end

  function env.loadedMessages()
    local count = 0
    for _, line in ipairs(printed) do
      if line:find("loaded", 1, true) then
        count = count + 1
      end
    end
    return count
  end

  function env.restore()
    _G.CreateFrame = saved.CreateFrame
    _G.print = saved.print
    _G.C_Timer = saved.C_Timer
    _G.NrageAssistantDB = saved.NrageAssistantDB
  end
  return env
end

describe("Init", function()
  local env

  before_each(function()
    env = build()
  end)

  after_each(function()
    env.restore()
  end)

  describe("Activate", function()
    it("runs the steps in order and leaves the addon active", function()
      env.fire("ADDON_LOADED", "NrageAssistant")
      env.fire("PLAYER_LOGIN")
      assert.is_true(env.ns.active)
      assert.are.same({}, env.ns.startupErrors)
      assert.are.same({ "comm", "minimap", "roster", "lootPopup", "votingFrame", "layerPopup" }, env.calls)
      assert.are.equal(1, env.loadedMessages())
    end)

    it("keeps starting the later steps when one raises, and tells the user once", function()
      env.ns.LootPopup.Start = function()
        error("boom")
      end
      env.fire("ADDON_LOADED", "NrageAssistant")
      env.fire("PLAYER_LOGIN")
      assert.is_true(env.ns.active)
      assert.is_true(env.lootFrames() == 1)
      assert.are.equal("lootPopup", env.ns.startupErrors[1].step)
      assert.is_truthy(env.ns.startupErrors[1].error:find("boom", 1, true))
      assert.is_truthy(table.concat(env.calls, ","):find("votingFrame", 1, true))
      local failures = 0
      for _, line in ipairs(env.printed) do
        if line:find("could not start", 1, true) then
          failures = failures + 1
        end
      end
      assert.are.equal(1, failures)
    end)

    it("stays inactive and tries again when a core step raises", function()
      local fails = true
      env.ns.Comm.Start = function()
        if fails then
          error("no transport")
        end
      end
      env.fire("ADDON_LOADED", "NrageAssistant")
      env.fire("PLAYER_LOGIN")
      assert.is_false(env.ns.active)
      assert.is_nil(table.concat(env.calls, ","):find("roster", 1, true))
      assert.are.equal(0, env.loadedMessages())
      fails = false
      env.fire("PLAYER_GUILD_UPDATE")
      assert.is_true(env.ns.active)
      assert.are.equal(1, env.loadedMessages())
    end)

    it("does not repeat one-time work when access is lost and regained", function()
      env.fire("ADDON_LOADED", "NrageAssistant")
      env.fire("PLAYER_LOGIN")
      local roster = env.ns.guildRoster
      env.ns.Platform.GetFaction = function()
        return "Horde"
      end
      env.fire("PLAYER_GUILD_UPDATE")
      assert.is_false(env.ns.active)
      env.ns.Platform.GetFaction = function()
        return env.ns.Constants.FACTION
      end
      env.fire("PLAYER_GUILD_UPDATE")
      assert.is_true(env.ns.active)
      assert.are.equal(1, env.lootFrames())
      assert.are.equal(1, env.loadedMessages())
      assert.are.equal(roster, env.ns.guildRoster)
      local starts = {}
      for _, label in ipairs(env.calls) do
        starts[label] = (starts[label] or 0) + 1
      end
      assert.are.equal(1, starts.lootPopup)
      assert.are.equal(1, starts.votingFrame)
      assert.are.equal(1, starts.roster)
      assert.are.equal(1, starts.rosterReset)
    end)
  end)

  describe("Intel", function()
    local function start()
      local tickers = {}
      _G.C_Timer.NewTicker = function(seconds, fn)
        tickers[#tickers + 1] = { seconds = seconds, fn = fn }
      end
      local platform = env.ns.Platform
      platform.Now = function()
        return 100
      end
      platform.GetInstanceKind = function()
        return "none"
      end
      platform.GetZonePvPType = function()
        return "contested"
      end
      platform.GetPlayerMapId = function()
        return 1411
      end
      platform.PlayerMapPosition = function()
        return { map = 1411, x = 0.5, y = 0.25 }
      end
      platform.GetPlayerFaction = function()
        return "Alliance"
      end
      env.units = {}
      platform.GetEnemyDetails = function(unit)
        return env.units[unit]
      end
      env.fire("ADDON_LOADED", "NrageAssistant")
      env.fire("PLAYER_LOGIN")
      local intelFrame
      for _, frame in ipairs(env.frames) do
        if frame.events.PLAYER_FOCUS_CHANGED then
          intelFrame = frame
        end
      end
      return intelFrame, tickers
    end

    it("starts once, registers each event and rescans every second", function()
      local intelFrame, tickers = start()
      assert.are.same({}, env.ns.startupErrors)
      assert.is_table(env.ns.intel)
      assert.is_table(env.ns.intelDetector)
      for _, event in ipairs({
        "NAME_PLATE_UNIT_ADDED",
        "PLAYER_TARGET_CHANGED",
        "PLAYER_FOCUS_CHANGED",
        "UPDATE_MOUSEOVER_UNIT",
      }) do
        assert.is_true(intelFrame.events[event], event)
        assert.is_true(env.ns.intelEvents[event], event)
      end
      local found = {}
      for _, ticker in ipairs(tickers) do
        if ticker.seconds == env.ns.Constants.INTEL_RESCAN_SECONDS then
          found[#found + 1] = ticker.fn
        end
      end
      assert.is_true(#found >= 1)

      env.units.nameplate2 = { name = "Bob", class = "ROGUE", faction = "Horde", level = 60 }
      for _, fn in ipairs(found) do
        pcall(fn)
      end
      assert.are.equal(1, env.ns.intel:Counts().players)
      assert.are.equal(1411, env.ns.db.global.intel.players.bob.lastMap)
      assert.are.equal(5000, env.ns.db.global.intel.players.bob.lastX)
      assert.are.equal(2500, env.ns.db.global.intel.players.bob.lastY)
    end)

    it("shares what it reads and shows the sightings of the guild as nearby", function()
      local sent = {}
      _G.ChatThrottleLib = {
        SendAddonMessage = function(_, priority, prefix, text, channel)
          sent[#sent + 1] = { priority = priority, prefix = prefix, text = text, channel = channel }
        end,
      }
      local _, tickers = start()
      env.ns.lockdown = {
        CanSend = function()
          return true
        end,
      }
      env.units.nameplate1 = { name = "Bob", class = "ROGUE", race = "ORC", faction = "Horde", level = 60 }
      env.ns.intelDetector:Rescan()
      for _, ticker in ipairs(tickers) do
        if ticker.seconds == env.ns.Constants.INTEL_SHARE_TICK_SECONDS then
          pcall(ticker.fn)
        end
      end
      _G.ChatThrottleLib = nil
      assert.are.equal(1, #sent)
      assert.are.equal("BULK", sent[1].priority)
      assert.are.equal(env.ns.Constants.INTEL_PREFIX, sent[1].prefix)
      assert.are.equal("GUILD", sent[1].channel)
      assert.are.equal("I1:1411:5000:2500:4:6:60:0:Bob", sent[1].text)

      env.ns.guildRoster = {
        Lookup = function()
          return { rankName = "Miembro", rankIndex = 5 }
        end,
      }
      assert.is_true(env.ns.intelSync:Handle("I1:1411:1:2:0:0:0:0:Eve", "GUILD", "Ann"))
      local names = {}
      for _, item in ipairs(env.ns.IntelNearby()) do
        names[#names + 1] = item.name .. "/" .. tostring(item.source)
      end
      table.sort(names)
      assert.are.same({ "Bob/nil", "Eve/Ann" }, names)
    end)

    it("redraws the Intel views when a guild Kill On Sight entry arrives", function()
      start()
      local redraws = 0
      env.ns.UI.IntelChanged = function()
        redraws = redraws + 1
      end
      env.ns.GuildKosChanged()
      env.ns.intelDirectory:Apply("Ann", { name = "Eve", map = 1411, x = 1, y = 1 })
      assert.are.equal(2, redraws)
      env.ns.UI.IntelChanged = nil
      env.ns.GuildKosChanged()
    end)

    it("shows no remote sightings when the own map is unknown", function()
      start()
      env.ns.intelDirectory:Apply("Ann", { name = "Eve", map = 1411, x = 1, y = 1 })
      env.ns.Platform.GetPlayerMapId = function()
        return nil
      end
      assert.are.same({}, env.ns.IntelNearby())
    end)

    it("reads the unit an event names, and ignores events while the addon is off", function()
      local intelFrame = start()
      env.units.nameplate7 = { name = "Eve", faction = "Horde" }
      env.units.target = { name = "Tom", faction = "Horde" }
      intelFrame.OnEvent(intelFrame, "NAME_PLATE_UNIT_ADDED", "nameplate7")
      intelFrame.OnEvent(intelFrame, "PLAYER_TARGET_CHANGED")
      assert.is_table(env.ns.db.global.intel.players.eve)
      assert.is_table(env.ns.db.global.intel.players.tom)
      env.ns.active = false
      env.units.focus = { name = "Zed", faction = "Horde" }
      intelFrame.OnEvent(intelFrame, "PLAYER_FOCUS_CHANGED")
      assert.is_nil(env.ns.db.global.intel.players.zed)
    end)

    it("reads nothing in a dungeon", function()
      local intelFrame = start()
      env.ns.Platform.GetInstanceKind = function()
        return "party"
      end
      env.units.target = { name = "Tom", faction = "Horde" }
      intelFrame.OnEvent(intelFrame, "PLAYER_TARGET_CHANGED")
      assert.is_nil(env.ns.db.global.intel.players.tom)
    end)

    it("keeps working when the client refuses an event", function()
      local original = env.ns.Platform.TryRegisterEvent
      env.ns.Platform.TryRegisterEvent = function(frame, event)
        if event == "UPDATE_MOUSEOVER_UNIT" then
          return false
        end
        return original(frame, event)
      end
      start()
      assert.is_false(env.ns.intelEvents.UPDATE_MOUSEOVER_UNIT)
      assert.is_true(env.ns.intelEvents.PLAYER_TARGET_CHANGED)
    end)
  end)

  describe("database", function()
    it("turns the addon off with a notice when a migration raises, and leaves the saved data alone", function()
      local raw = { global = { schemaVersion = 1 } }
      _G.NrageAssistantDB = raw
      env.ns.Store.Load = function()
        error("bad migration")
      end
      env.fire("ADDON_LOADED", "NrageAssistant")
      assert.are.equal("migration_failed", env.ns.dbError)
      assert.is_nil(env.ns.db)
      assert.are.equal(raw, _G.NrageAssistantDB)
      env.fire("PLAYER_LOGIN")
      assert.is_falsy(env.ns.active)
      assert.are.same({ "minimapRefresh" }, env.calls)
      local text = table.concat(env.printed, "\n")
      assert.is_truthy(text:find("could not be updated", 1, true))
    end)

    it("keeps the newer schema notice", function()
      _G.NrageAssistantDB = { global = { schemaVersion = 999 } }
      env.fire("ADDON_LOADED", "NrageAssistant")
      env.fire("PLAYER_LOGIN")
      assert.are.equal("newer_schema", env.ns.dbError)
      assert.is_truthy(table.concat(env.printed, "\n"):find("newer version", 1, true))
    end)
  end)

  describe("IsDevBuild", function()
    it("is true while the version token is not replaced and false in a packaged build", function()
      local original = _G.C_AddOns.GetAddOnMetadata
      assert.is_true(env.ns.IsDevBuild())
      _G.C_AddOns.GetAddOnMetadata = function()
        return "1.2.3"
      end
      assert.is_false(env.ns.IsDevBuild())
      _G.C_AddOns.GetAddOnMetadata = original
    end)

    it("makes every probe unavailable and register nothing in a release build", function()
      local original = _G.C_AddOns.GetAddOnMetadata
      _G.C_AddOns.GetAddOnMetadata = function()
        return "1.2.3"
      end
      local before = #env.frames
      for _, probe in ipairs({ env.ns.Probe, env.ns.PvPProbe, env.ns.LayerProbe }) do
        probe.Handle("start")
        probe.Handle("send")
      end
      _G.C_AddOns.GetAddOnMetadata = original
      assert.are.equal(before, #env.frames)
      local unavailable = 0
      for _, line in ipairs(env.printed) do
        if line:find("only available in a development build", 1, true) then
          unavailable = unavailable + 1
        end
      end
      assert.are.equal(6, unavailable)
    end)
  end)
end)
