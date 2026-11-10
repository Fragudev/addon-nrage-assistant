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
  spy(ns.LfgPopup, "Start", "lfgPopup")
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
      assert.are.same({ "comm", "minimap", "roster", "lootPopup", "votingFrame", "layerPopup", "lfgPopup" }, env.calls)
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

  describe("Groups", function()
    local tickers, sent

    local function start()
      tickers = {}
      _G.C_Timer.NewTicker = function(seconds, fn)
        tickers[#tickers + 1] = { seconds = seconds, fn = fn }
      end
      sent = { posts = {}, applies = {} }
      env.ns.Platform.Now = function()
        return 100
      end
      -- Taken by reference when the feature starts, as the real one is.
      env.ns.Platform.GetIdentityKey = function()
        return "Mary Ann-Realm"
      end
      env.fire("ADDON_LOADED", "NrageAssistant")
      env.ns.Comm.Start = function()
        env.ns.comm = {
          NextId = function()
            return "pid-1"
          end,
          SendLfgPost = function(_, payload)
            sent.posts[#sent.posts + 1] = payload
            return true
          end,
          SendLfgApply = function(_, payload)
            sent.applies[#sent.applies + 1] = payload
            return true
          end,
        }
        env.ns.lockdown = {
          CanSend = function()
            return true
          end,
        }
        return env.ns.comm
      end
      env.fire("PLAYER_LOGIN")
      env.ns.guildRoster.IsReady = function()
        return false
      end
    end

    -- The last frame that listens to exactly these two events: the blacklist frame listens to the same ones.
    local function lfgFrame()
      local found
      for _, frame in ipairs(env.frames) do
        local count = 0
        for _ in pairs(frame.events) do
          count = count + 1
        end
        if count == 2 and frame.events.GROUP_ROSTER_UPDATE and frame.events.PLAYER_ENTERING_WORLD then
          found = frame
        end
      end
      return found
    end

    it("starts once, with its own frame and its own tickers, and hands the service to Comm", function()
      start()
      assert.are.same({}, env.ns.startupErrors)
      assert.is_table(env.ns.lfgService)
      assert.is_table(env.ns.lfgBoard)
      assert.are.equal(env.ns.lfgService, env.ns.comm.lfgService)
      assert.is_truthy(lfgFrame())
      local seconds = {}
      for _, ticker in ipairs(tickers) do
        seconds[ticker.seconds] = true
      end
      assert.is_true(seconds[env.ns.Constants.LFG_REPUBLISH_SECONDS])
      assert.is_true(seconds[env.ns.Constants.LFG_SWEEP_SECONDS])
      local service = env.ns.lfgService
      env.fire("PLAYER_GUILD_UPDATE")
      assert.are.equal(service, env.ns.lfgService)
    end)

    it("follows the group only while the addon is active", function()
      start()
      local calls = 0
      env.ns.lfgService.OnGroupChanged = function()
        calls = calls + 1
      end
      lfgFrame().OnEvent(lfgFrame(), "GROUP_ROSTER_UPDATE")
      assert.are.equal(1, calls)
      env.ns.active = false
      lfgFrame().OnEvent(lfgFrame(), "GROUP_ROSTER_UPDATE")
      assert.are.equal(1, calls)
    end)

    it("republishes and sweeps only while the addon is active", function()
      start()
      local republish, sweep = 0, 0
      env.ns.lfgService.Republish = function()
        republish = republish + 1
      end
      env.ns.lfgService.Sweep = function()
        sweep = sweep + 1
      end
      local function run(seconds)
        for _, ticker in ipairs(tickers) do
          if ticker.seconds == seconds then
            ticker.fn()
          end
        end
      end
      run(env.ns.Constants.LFG_REPUBLISH_SECONDS)
      run(env.ns.Constants.LFG_SWEEP_SECONDS)
      assert.are.equal(1, republish)
      assert.are.equal(1, sweep)
      env.ns.active = false
      run(env.ns.Constants.LFG_REPUBLISH_SECONDS)
      run(env.ns.Constants.LFG_SWEEP_SECONDS)
      assert.are.equal(1, republish)
      assert.are.equal(1, sweep)
    end)

    it("posts through Comm with the identity key and the guarded level", function()
      start()
      assert.is_true(env.ns.lfgService:Post({ kind = "quest", title = "Q", needs = { dps = 2 } }))
      assert.are.equal(1, #sent.posts)
      assert.are.equal("pid-1", sent.posts[1].pid)
      assert.are.equal("Mary Ann-Realm", env.ns.lfgBoard:Get("Mary Ann-Realm").owner)
    end)

    it("reads the own level only when it is a plain number", function()
      start()
      local board = env.ns.lfgBoard
      board:Apply("Lead", {
        pid = "p-1",
        rev = 1,
        s = "open",
        kind = "quest",
        title = "Q",
        needs = { tank = 0, heal = 0, dps = 1 },
        members = 1,
        minLevel = 60,
      })
      local platform = env.ns.Platform
      platform.GetLevel = function()
        return 10
      end
      assert.are.same({ false, "level" }, { env.ns.lfgService:Apply("p-1", "dps") })
      platform.GetLevel = function()
        error("secret")
      end
      assert.is_true(env.ns.lfgService:Apply("p-1", "dps"))
    end)

    it("keeps a layer swap out while it is busy, and the other way round", function()
      start()
      local rules = env.ns.layerSwap.deps.eligibility
      assert.is_true(rules.requester())
      env.ns.lfgService.application = { state = "applied" }
      assert.are.same({ false, "lfg" }, { rules.requester() })
      assert.are.same({ false, "unknown_layer" }, { rules.helper(1, 1) })
      env.ns.lfgService.application = { state = "joined" }
      assert.is_true(rules.requester())
      env.ns.lfgService.application = nil
      local swapActive = false
      env.ns.layerSwap.IsActive = function()
        return swapActive
      end
      assert.is_true(env.ns.lfgService.deps.eligibility.apply())
      swapActive = true
      assert.are.same({ false, "swap" }, { env.ns.lfgService.deps.eligibility.apply() })
    end)

    it("asks the game to invite through the platform and leaves a trace in the probe log", function()
      start()
      local invited = {}
      env.ns.Platform.InviteByName = function(name)
        invited[#invited + 1] = name
        return true
      end
      local noted
      env.ns.LayerProbe.Note = function(kind, text)
        noted = { kind, text }
      end
      env.ns.lfgService:Post({ kind = "quest", title = "Q", needs = { dps = 2 } })
      env.ns.lfgService:OnApply("Ann-Realm", { pid = "pid-1", s = "apply", role = "dps" })
      assert.is_true(env.ns.lfgService:Invite("Ann-Realm"))
      assert.are.same({ "Ann-Realm" }, invited)
      assert.are.equal("invite", noted[1])
      assert.is_truthy(noted[2]:find("Ann-Realm", 1, true))
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
          return { rankName = "Soldado", rankIndex = 5 }
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

    it("redraws the interface after every read, while the addon is on", function()
      local _, tickers = start()
      local changed, periodic = 0, nil
      env.ns.UI.IntelChanged = function(flag)
        changed = changed + 1
        periodic = flag
      end
      for _, ticker in ipairs(tickers) do
        if ticker.seconds == env.ns.Constants.INTEL_RESCAN_SECONDS then
          ticker.fn()
        end
      end
      assert.are.equal(1, changed)
      assert.is_true(periodic)
      env.ns.active = false
      for _, ticker in ipairs(tickers) do
        if ticker.seconds == env.ns.Constants.INTEL_RESCAN_SECONDS then
          ticker.fn()
        end
      end
      assert.are.equal(1, changed)
      env.ns.UI.IntelChanged = nil
    end)

    it("starts the compact window", function()
      local started = 0
      env.ns.IntelWindow.Start = function()
        started = started + 1
      end
      start()
      assert.are.equal(1, started)
    end)

    it("builds the pins of the enemies from the ones seen here and the sightings of the guild", function()
      start()
      env.ns.intel:OnSeen({ name = "Fay", class = "MAGE" }, { map = 1411, x = 5000, y = 2500 })
      env.ns.intelDirectory:Apply("Ann", { name = "Eve", map = 1411, x = 100, y = 200 })
      local controller = env.ns.intelMapPins
      local names = {}
      for _, pin in ipairs(controller.deps.pins()) do
        names[#names + 1] = pin.name
      end
      table.sort(names)
      assert.are.same({ "Eve", "Fay" }, names)
      env.ns.db.global.settings.intel.mapMode = "none"
      assert.are.same({}, controller.deps.pins())
      local settings = controller.deps.settings()
      assert.is_true(settings.minimap and settings.worldmap)
      assert.is_false(settings.follow)
      -- The button on the world map turns only the world map pins off; the minimap ones stay on.
      env.ns.db.global.settings.intel.worldmapPins = false
      settings = controller.deps.settings()
      assert.is_true(settings.minimap)
      assert.is_false(settings.worldmap)
      assert.are.equal("none", env.ns.db.global.settings.intel.mapMode)
      assert.are.equal(env.ns.Platform.ShowWorldMap, controller.deps.follow)
    end)

    it("starts the button by the target frame and the tooltip of the minimap, which feeds Nearby", function()
      local starts, hook = {}, nil
      env.ns.IntelTargetButton.Start = function()
        starts[#starts + 1] = "button"
      end
      env.ns.MinimapButton.HookTooltip = function(deps)
        hook = deps
        starts[#starts + 1] = "tooltip"
      end
      start()
      assert.are.same({ "button", "tooltip" }, starts)
      hook.feed({ name = "Fay", class = "MAGE" })
      assert.are.equal("Fay", env.ns.IntelNearby()[1].name)
      assert.are.equal(1411, env.ns.IntelNearby()[1].map)
      assert.is_true(hook.settings().minimapTooltip)
      -- Where detection is off, the tooltip records nothing either.
      env.ns.db.global.settings.intel.enabled = false
      hook.feed({ name = "Gus", class = "MAGE" })
      assert.is_nil(env.ns.intel:Player("Gus"))
    end)

    it("tells the player once that sharing the sightings is on, and only when Intel is running", function()
      start()
      local notices = 0
      for _, line in ipairs(env.printed) do
        if line:find("enemy players you meet are now shared", 1, true) then
          notices = notices + 1
        end
      end
      assert.are.equal(1, notices)
      assert.is_nil(env.ns.db.global.settings.intelShareNotice)
      env.printed = {}
    end)

    it("reminds the player once that the enemy nameplates are off", function()
      local timers = {}
      _G.C_Timer.After = function(seconds, fn)
        timers[#timers + 1] = { seconds = seconds, fn = fn }
      end
      -- The login delays are random and can equal the delay looked for below, so they are pinned to their minimum.
      local realRandom = math.random
      rawset(math, "random", function(low)
        return low
      end)
      start()
      rawset(math, "random", realRandom)
      local reminder
      for _, timer in ipairs(timers) do
        if timer.seconds == env.ns.Constants.INTEL_REMINDER_DELAY_SECONDS then
          reminder = timer.fn
        end
      end
      assert.is_function(reminder)
      local function reminders()
        local count = 0
        for _, line in ipairs(env.printed) do
          if line:find("Enemy nameplates are off", 1, true) then
            count = count + 1
          end
        end
        return count
      end
      env.ns.Platform.EnemyNameplatesEnabled = function()
        return true
      end
      env.ns.Platform.IsInCombat = function()
        return false
      end
      reminder()
      assert.are.equal(0, reminders())
      env.ns.Platform.EnemyNameplatesEnabled = function()
        return false
      end
      env.ns.active = false
      reminder()
      assert.are.equal(0, reminders())
      env.ns.active = true
      reminder()
      assert.are.equal(1, reminders())
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

    it("registers the cast and death events and builds the alerts and the commands", function()
      local intelFrame = start()
      assert.are.same({}, env.ns.startupErrors)
      assert.is_true(intelFrame.events.UNIT_SPELLCAST_SUCCEEDED)
      assert.is_true(intelFrame.events.PLAYER_DEAD)
      assert.is_true(env.ns.intelEvents.PLAYER_DEAD)
      assert.is_table(env.ns.intelAlerts)
      assert.are.equal("function", type(env.ns.intelCommands.Run))
      assert.is_truthy(env.ns.intelCommands:Run("debug")[1])
    end)

    it("alerts for a Kill On Sight enemy in the error area while the window does not exist", function()
      local intelFrame = start()
      local shown, sounds = {}, {}
      env.ns.Platform.ShowErrorText = function(text)
        shown[#shown + 1] = text
      end
      env.ns.Platform.PlayIntelSound = function(kind)
        sounds[#sounds + 1] = kind
      end
      env.ns.intel:AddKos({ name = "Eve" })
      env.units.nameplate1 = { name = "Eve", faction = "Horde", level = 60 }
      intelFrame.OnEvent(intelFrame, "NAME_PLATE_UNIT_ADDED", "nameplate1")
      assert.are.same({ "Kill on Sight: Eve (level 60)" }, shown)
      assert.are.same({ "kos" }, sounds)

      -- With the window there, the warning goes to it.
      local warned = {}
      env.ns.IntelWindow = {
        Warn = function(text, kind, class)
          warned[#warned + 1] = kind .. ":" .. text .. ":" .. tostring(class)
        end,
      }
      env.ns.intel:AddKos({ name = "Tom" })
      env.units.nameplate2 = { name = "Tom", faction = "Horde", class = "WARLOCK" }
      intelFrame.OnEvent(intelFrame, "NAME_PLATE_UNIT_ADDED", "nameplate2")
      env.ns.IntelWindow = nil
      assert.are.same({ "kos:Kill on Sight: Tom (Warlock):WARLOCK" }, warned)
      assert.are.equal(1, #shown)
    end)

    it("alerts when a guildmate reports a Kill On Sight enemy on the same map", function()
      start()
      local shown = {}
      env.ns.Platform.ShowErrorText = function(text)
        shown[#shown + 1] = text
      end
      env.ns.intel:AddKos({ name = "Eve" })
      env.ns.intelDirectory:Apply("Ann", { name = "Eve", map = 1411, x = 1, y = 1, level = 60 })
      assert.are.same({ "Ann reports Kill on Sight: Eve (level 60)" }, shown)
    end)

    it("marks an enemy that casts a stealth ability, and ignores other spells", function()
      local intelFrame = start()
      env.units.nameplate4 = { name = "Rogue", faction = "Horde", level = 60 }
      intelFrame.OnEvent(intelFrame, "NAME_PLATE_UNIT_ADDED", "nameplate4")
      assert.is_false(env.ns.IntelNearby()[1].stealth)
      intelFrame.OnEvent(intelFrame, "UNIT_SPELLCAST_SUCCEEDED", "nameplate4", "guid", 133)
      assert.is_false(env.ns.IntelNearby()[1].stealth)
      intelFrame.OnEvent(intelFrame, "UNIT_SPELLCAST_SUCCEEDED", "nameplate4", "guid", 1784)
      assert.is_true(env.ns.IntelNearby()[1].stealth)
      intelFrame.OnEvent(intelFrame, "UNIT_SPELLCAST_SUCCEEDED", "party1", "guid", 1784)
      intelFrame.OnEvent(intelFrame, "UNIT_SPELLCAST_SUCCEEDED")
    end)

    it("stores a loss against the killer of the death recap on PLAYER_DEAD", function()
      local intelFrame = start()
      env.units.target = { name = "Bob", faction = "Horde" }
      intelFrame.OnEvent(intelFrame, "PLAYER_TARGET_CHANGED")
      env.ns.Platform.GetDeathKiller = function()
        return "Bob"
      end
      intelFrame.OnEvent(intelFrame, "PLAYER_DEAD")
      assert.are.equal(1, env.ns.db.global.intel.players.bob.losses)
      assert.are.equal(1, env.ns.intelDetector.lossSources.recap)
    end)

    it("counts a win when the honour message names a victim", function()
      start()
      local pvpFrame
      for _, frame in ipairs(env.frames) do
        if frame.events.CHAT_MSG_COMBAT_HONOR_GAIN then
          pvpFrame = frame
        end
      end
      env.ns.Platform.ParseHonorVictim = function()
        return "Bob"
      end
      pvpFrame.OnEvent(pvpFrame, "CHAT_MSG_COMBAT_HONOR_GAIN", "Bob dies, honorable kill")
      assert.are.equal(1, env.ns.db.global.intel.players.bob.wins)
      assert.are.equal(1, env.ns.intel.session.wins)
    end)
  end)

  describe("PvP missions handlers", function()
    it("builds the progress publisher and hooks the HELLO of a gm or cogm to the pending claims", function()
      env.fire("ADDON_LOADED", "NrageAssistant")
      env.fire("PLAYER_LOGIN")
      assert.is_truthy(env.ns.pvpProgress)
      assert.is_function(env.ns.comm.onApproverHello)
      local seen = 0
      env.ns.pvpMissions.OnApproverSeen = function()
        seen = seen + 1
      end
      env.ns.comm.onApproverHello("Boss-Realm")
      assert.are.equal(1, seen)
      env.ns.pvpMissions.OnApproverSeen = function()
        error("hello boom")
      end
      assert.has_no.errors(function()
        env.ns.comm.onApproverHello("Boss-Realm")
      end)
      assert.is_truthy(env.ns.startupErrors[#env.ns.startupErrors].error:find("hello boom", 1, true))
      -- a season record from the guild asks the publisher to look again, a summary from a member does not
      local changes = 0
      env.ns.pvpProgress.Changed = function()
        changes = changes + 1
      end
      env.ns.PvPSeasonChanged("PVP_MISSION")
      env.ns.PvPSeasonChanged("PVP_PROGRESS")
      assert.are.equal(1, changes)
    end)

    it("listen to the score update and the end of combat, which feed the battleground result", function()
      env.fire("ADDON_LOADED", "NrageAssistant")
      env.fire("PLAYER_LOGIN")
      local frame
      for _, candidate in ipairs(env.frames) do
        if candidate.events.UPDATE_BATTLEFIELD_STATUS then
          frame = candidate
        end
      end
      assert.is_true(frame.events.UPDATE_BATTLEFIELD_SCORE)
      assert.is_true(frame.events.PLAYER_REGEN_ENABLED)
      local seen = {}
      env.ns.pvpMissions.OnBattlegroundScore = function()
        seen[#seen + 1] = "score"
      end
      env.ns.pvpMissions.OnCombatEnded = function()
        seen[#seen + 1] = "combat"
      end
      frame.OnEvent(frame, "UPDATE_BATTLEFIELD_SCORE")
      frame.OnEvent(frame, "PLAYER_REGEN_ENABLED")
      assert.are.same({ "score", "combat" }, seen)
    end)

    local function missionsFrame()
      for _, frame in ipairs(env.frames) do
        if frame.events.UPDATE_BATTLEFIELD_STATUS then
          return frame
        end
      end
    end

    it("report a failing world entry or battleground status instead of raising into the client", function()
      env.fire("ADDON_LOADED", "NrageAssistant")
      env.fire("PLAYER_LOGIN")
      local frame = missionsFrame()
      assert.is_truthy(frame)
      env.ns.pvpMissions.OnWorldEntered = function()
        error("world boom")
      end
      env.ns.pvpMissions.OnBattlegroundStatus = function()
        error("status boom")
      end
      assert.has_no.errors(function()
        frame.OnEvent(frame, "PLAYER_ENTERING_WORLD", false, false)
        frame.OnEvent(frame, "UPDATE_BATTLEFIELD_STATUS")
      end)
      local steps = {}
      for _, failure in ipairs(env.ns.startupErrors) do
        steps[failure.step] = failure.error
      end
      assert.is_truthy(steps["pvpMissions.worldEntered"]:find("world boom", 1, true))
      assert.is_truthy(steps["pvpMissions.battlegroundStatus"]:find("status boom", 1, true))
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

describe("Init announcements", function()
  local env, timers, popups, sent

  local function announcement(id, overrides)
    local a = {
      id = id,
      title = "Title " .. id,
      body = "",
      author = "Gm-Realm",
      createdAt = os.time() - 100,
      updatedAt = os.time() - 100,
      rev = 1,
      popup = true,
      popupRev = 1,
      pinned = false,
    }
    for key, value in pairs(overrides or {}) do
      a[key] = value
    end
    return a
  end

  -- Logs in as the guild master, with `items` already saved.
  local function start(items)
    env.fire("ADDON_LOADED", "NrageAssistant")
    for id, record in pairs(items or {}) do
      env.ns.db.global.announcements.items[id] = record
    end
    env.ns.Platform.GetOwnGuildRank = function()
      return "Emperador", 0
    end
    env.ns.Platform.GetIdentityKey = function()
      return "Me-Realm"
    end
    env.ns.Comm.Start = function()
      env.ns.comm = {
        NextId = function()
          return "id-1"
        end,
        SendAnnouncement = function(_, a)
          sent[#sent + 1] = "ANN:" .. a.id
          return true
        end,
        SendAnnouncementDelete = function(_, id)
          sent[#sent + 1] = "ANN_DEL:" .. id
          return true
        end,
      }
      return env.ns.comm
    end
    env.ns.AnnouncementPopup.Add = function(a)
      popups[#popups + 1] = a.id
    end
    env.fire("PLAYER_LOGIN")
  end

  before_each(function()
    env = build()
    timers, popups, sent = {}, {}, {}
    _G.C_Timer.After = function(seconds, fn)
      timers[#timers + 1] = { seconds = seconds, fn = fn }
    end
  end)

  after_each(function()
    env.restore()
  end)

  it("starts once, as its own step, and the guild master can publish through Comm", function()
    start()
    assert.are.same({}, env.ns.startupErrors)
    assert.is_table(env.ns.announcements)
    assert.is_function(env.ns.AnnouncementReceived)
    local a = assert(env.ns.announcements:Publish({ title = "Hello" }))
    assert.are.same({ "ANN:" .. a.id }, sent)
    assert.are.equal(a, env.ns.db.global.announcements.items[a.id])
    assert.is_nil(env.ns.announcements:Edit(a.id, { title = "" }))
    local service = env.ns.announcements
    env.fire("PLAYER_GUILD_UPDATE")
    assert.are.equal(service, env.ns.announcements)
  end)

  it("purges what expired before the service starts", function()
    start({
      alive = announcement("alive"),
      dead = announcement("dead", { expiresAt = os.time() - 5 }),
    })
    assert.is_truthy(env.ns.db.global.announcements.items.alive)
    assert.is_nil(env.ns.db.global.announcements.items.dead)
  end)

  it("hands a received announcement to the popup when it is due", function()
    start()
    env.ns.AnnouncementReceived(announcement("new"))
    assert.are.same({ "new" }, popups)
    env.ns.AnnouncementReceived(announcement("silent", { popup = false }))
    assert.are.same({ "new" }, popups)
  end)

  it("asks again for the popups still due for what is stored, a moment after the start", function()
    start({ waiting = announcement("waiting"), seen = announcement("seen") })
    env.ns.db.global.announcementsSeen.seen = 1
    local pending
    for _, timer in ipairs(timers) do
      if timer.seconds == env.ns.Constants.ANNOUNCE_LOGIN_POPUP_DELAY then
        pending = timer
      end
    end
    assert.is_truthy(pending)
    assert.are.same({}, popups)
    pending.fn()
    assert.are.same({ "waiting" }, popups)
  end)

  it("tells the UI when the board changes", function()
    start()
    local changes = 0
    env.ns.UI.AnnouncementsChanged = function()
      changes = changes + 1
    end
    assert(env.ns.announcements:Publish({ title = "Hello" }))
    assert.are.equal(1, changes)
  end)
end)

describe("Init modules", function()
  local env

  before_each(function()
    env = build()
  end)

  after_each(function()
    env.restore()
  end)

  it("skips the activation steps of a module that is off, and lists them in ns.skippedSteps", function()
    env.fire("ADDON_LOADED", "NrageAssistant")
    env.ns.Settings.SetModuleOff(env.ns.db, "loot", true)
    env.fire("PLAYER_LOGIN")
    assert.is_true(env.ns.active)
    local ran = table.concat(env.calls, ",")
    assert.is_nil(ran:find("lootPopup", 1, true))
    assert.is_nil(ran:find("votingFrame", 1, true))
    assert.is_truthy(ran:find("comm", 1, true))
    assert.are.same({ "lootPopup", "votingFrame", "bossLoot" }, env.ns.skippedSteps)
  end)

  it("lists no skipped step when every module is on", function()
    env.fire("ADDON_LOADED", "NrageAssistant")
    env.fire("PLAYER_LOGIN")
    assert.are.same({}, env.ns.skippedSteps)
  end)

  it("asks for a reload when a module that was skipped at login is switched on", function()
    env.fire("ADDON_LOADED", "NrageAssistant")
    env.ns.Settings.SetModuleOff(env.ns.db, "loot", true)
    env.fire("PLAYER_LOGIN")
    assert.is_false(env.ns.modules:NeedsReload("loot"))
    env.ns.modules:SetEnabled("loot", true)
    assert.is_true(env.ns.modules:NeedsReload("loot"))
  end)
end)
