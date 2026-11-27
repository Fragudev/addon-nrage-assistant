describe("independent PARTY_KILL probe", function()
  local saved, ns, frames, messages, guids, clock, timers, tickers, hk, honor
  local globals = {
    "CreateFrame",
    "print",
    "UnitGUID",
    "GetPlayerInfoByGUID",
    "C_Timer",
    "GetPVPSessionStats",
    "GetPVPLifetimeStats",
    "UnitFactionGroup",
    "UnitIsEnemy",
    "UnitIsFriend",
    "issecretvalue",
  }

  before_each(function()
    saved, frames, messages = {}, {}, {}
    guids, clock = { player = "Player-self", pet = "Pet-self", party2 = "Player-friend" }, 10
    for _, name in ipairs(globals) do
      saved[name] = _G[name]
    end
    timers, tickers, hk, honor = {}, {}, 0, 0
    _G.GetPVPSessionStats = function()
      return hk, honor
    end
    _G.GetPVPLifetimeStats = function()
      return hk, 0
    end
    _G.UnitFactionGroup = function()
      return "Alliance"
    end
    _G.UnitIsEnemy, _G.UnitIsFriend, _G.issecretvalue = nil, nil, nil
    _G.C_Timer = {
      NewTicker = function(_, fn)
        local ticker = {
          tick = fn,
          Cancel = function(self)
            self.cancelled = true
          end,
        }
        tickers[#tickers + 1] = ticker
        return ticker
      end,
      After = function(_, fn)
        timers[#timers + 1] = fn
      end,
    }
    _G.print = function(text)
      messages[#messages + 1] = text
    end
    _G.UnitGUID = function(unit)
      return guids[unit]
    end
    _G.GetPlayerInfoByGUID = function(guid)
      assert.are.equal("Player-enemy", guid)
      return "Mage", "MAGE", "Undead", "SCOURGE", 3, "Enemy Name", "Realm"
    end
    _G.CreateFrame = function()
      local frame = { events = {} }
      function frame:RegisterEvent(event)
        assert.are_not.equal("COMBAT_LOG_EVENT_UNFILTERED", event)
        self.events[event] = true
      end
      function frame:SetScript(_, fn)
        self.handler = fn
      end
      function frame:UnregisterAllEvents()
        self.events = {}
      end
      frames[#frames + 1] = frame
      return frame
    end
    ns = {
      active = true,
      IsDevBuild = function()
        return true
      end,
      Platform = {
        Now = function()
          return clock
        end,
        WallClock = function()
          return "12:00:00"
        end,
      },
    }
    assert(loadfile("NrageAssistant/Core/PvPCounterGuard.lua"))("NrageAssistant", ns)
    assert(loadfile("NrageAssistant/Core/PvPProbeLog.lua"))("NrageAssistant", ns)
    assert(loadfile("NrageAssistant/Core/PvPProbe.lua"))("NrageAssistant", ns)
  end)

  after_each(function()
    for _, name in ipairs(globals) do
      _G[name] = saved[name]
    end
  end)

  local function output()
    return table.concat(messages, "\n")
  end

  it("resolves solo and group victims by GUID without a visible unit or mission service", function()
    ns.PvPProbe.Handle("kills")
    local frame = frames[1]
    assert.is_true(frame.events.PARTY_KILL)
    frame.handler(frame, "PARTY_KILL", "Player-self", "Player-enemy")
    assert.is_truthy(output():find("source=player", 1, true))
    assert.is_truthy(output():find("name=Enemy Name", 1, true))
    assert.is_truthy(output():find("raceToken=SCOURGE", 1, true))
    clock = 15
    frame.handler(frame, "PARTY_KILL", "Player-friend", "Player-enemy")
    assert.is_truthy(output():find("source=group:party2", 1, true))
    ns.PvPProbe.Handle("killlog")
    ns.PvPProbe.Handle("stop")
    assert.is_nil(frame.handler)
    assert.is_nil(next(frame.events))
  end)

  it("handles unavailable GUID resolution and avoids duplicate registrations", function()
    _G.GetPlayerInfoByGUID = nil
    ns.PvPProbe.Handle("kills")
    ns.PvPProbe.Handle("kills")
    assert.are.equal(1, #frames)
    local frame = frames[1]
    frame.handler(frame, "PARTY_KILL", "Pet-self", "Player-enemy")
    assert.is_truthy(output():find("source=pet", 1, true))
    assert.is_truthy(output():find("GetPlayerInfoByGUID missing", 1, true))
    frame.handler(frame, "PARTY_KILL", "Pet-self", "Player-enemy")
    assert.is_truthy(output():find("duplicate=true", 1, true))
  end)

  it("skips non-player PARTY_KILL victims after the direct query without scheduling counters", function()
    ns.PvPProbe.Handle("kills")
    local frame = frames[1]
    local count = #messages
    for _, victim in ipairs({ "Creature-npc", "Pet-enemy", "Vehicle-enemy" }) do
      frame.handler(frame, "PARTY_KILL", "Player-self", victim)
    end
    assert.are.equal(count, #messages)
    assert.are.equal(0, #timers)
    frame.handler(frame, "PARTY_KILL", "Pet-self", "Player-enemy")
    assert.is_truthy(output():find("source=pet", 1, true))
    assert.is_truthy(output():find("name=Enemy Name", 1, true))
  end)

  it("retains unreadable victim warnings for both independent events", function()
    ns.PvPProbe.Handle("kills")
    local frame = frames[1]
    for _, event in ipairs({ "PARTY_KILL", "UNIT_DIED" }) do
      for _, victim in ipairs({ "", false, {} }) do
        if event == "PARTY_KILL" then
          frame.handler(frame, event, "Player-self", victim)
        else
          frame.handler(frame, event, victim)
        end
      end
      assert.is_truthy(output():find("unreadable] " .. event .. " victimGUID=", 1, true))
    end
    assert.are.equal(0, #timers)
  end)

  it("resolves UNIT_DIED without any PARTY_KILL and ignores NPC deaths", function()
    ns.PvPProbe.Handle("kills")
    local frame = frames[1]
    assert.is_true(frame.events.UNIT_DIED)
    frame.handler(frame, "UNIT_DIED", "Creature-npc")
    assert.are.equal(0, #timers)
    frame.handler(frame, "UNIT_DIED", "Player-enemy")
    assert.is_truthy(output():find("unit_died_direct", 1, true))
    assert.is_truthy(output():find("name=Enemy Name", 1, true))
    assert.is_nil(output():find("party_kill_direct", 1, true))
    assert.is_nil(output():find("source=player", 1, true))
    timers[1]()
    assert.is_truthy(output():find("trigger=UNIT_DIED", 1, true))
    ns.PvPProbe.Handle("stop")
    local count = #messages
    timers[1]()
    assert.are.equal(count, #messages)
  end)

  it("keeps UNIT_DIED available if PARTY_KILL registration fails", function()
    local create = _G.CreateFrame
    _G.CreateFrame = function()
      local frame = create()
      local register = frame.RegisterEvent
      frame.RegisterEvent = function(self, event)
        if event == "PARTY_KILL" then
          error("unsupported")
        end
        register(self, event)
      end
      return frame
    end
    ns.PvPProbe.Handle("kills")
    assert.is_true(frames[1].events.UNIT_DIED)
    frames[1].handler(frames[1], "UNIT_DIED", "Player-enemy")
    assert.is_truthy(output():find("name=Enemy Name", 1, true))
  end)

  local function finish()
    clock = clock + 6
    tickers[1].tick()
  end

  it("correlates a group death, HK, parser, real feed, mission log and filtered progress", function()
    for _, path in ipairs({
      "Core/Constants",
      "Core/Locale",
      "Core/Validate",
      "Domain/PvPSeasonModel",
      "Domain/PvPUnitCache",
      "Domain/PvPMissionTracker",
      "Domain/PvPMissionService",
      "Domain/PvPFeed",
    }) do
      assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
    end
    local events, claims = { events = {} }, {}
    local season = { id = "s1", state = "active", startsAt = 0, endsAt = 100000 }
    local mission = {
      id = "m1",
      seasonId = "s1",
      active = true,
      repeatKind = "once",
      goal = { kind = "kills", count = 1, victimClasses = { "MAGE" }, victimRaces = { "SCOURGE" } },
    }
    local cache = ns.PvPUnitCache.New({
      now = function()
        return clock
      end,
    })
    cache:Remember("Enemy Name", "MAGE", "SCOURGE")
    ns.pvpMissions = ns.PvPMissionService.New({
      season = {
        ActiveSeason = function()
          return season
        end,
        Missions = function()
          return { mission }
        end,
        Mission = function()
          return mission
        end,
      },
      log = function()
        return events
      end,
      claims = function()
        return claims
      end,
      now = function()
        return clock
      end,
      cache = cache,
      platform = {
        GetPlayerMapId = function()
          return 1411
        end,
        GetPlayerFaction = function()
          return "Alliance"
        end,
      },
    })
    ns.pvpFeed = ns.PvPFeed.New({
      now = function()
        return clock
      end,
      serverTime = function()
        return clock
      end,
      ownName = function()
        return "Self"
      end,
      schedule = function() end,
      onHonorKill = function(entry)
        ns.pvpMissions:OnHonorKill(entry)
      end,
    })
    ns.Platform.ParseHonorVictim = function()
      return "Enemy Name"
    end
    ns.PvPProbe.Handle("kills")
    local frame = frames[1]
    frame.handler(frame, "PARTY_KILL", "Player-friend", "Player-enemy")
    hk, honor = 1, 5
    -- The actual production route is parser -> feed -> service; the probe only observes its effects.
    ns.pvpFeed:OnHonorKill(ns.Platform.ParseHonorVictim("honor"), "world")
    frame.handler(frame, "CHAT_MSG_COMBAT_HONOR_GAIN", "honor")
    frame.handler(frame, "UNIT_DIED", "Player-enemy")
    finish()
    assert.are.equal(1, #events.events)
    assert.are.equal(1, ns.pvpMissions:Progress("m1").bars[1].done)
    for _, text in ipairs({
      "chain_parser",
      "chain_cache",
      "chain_feed",
      "chain_mission_event",
      "chain_progress",
      "hk=increase_observed",
      "candidates=1",
      "missionEvents=1",
      "progressChanges=1",
    }) do
      assert.is_truthy(output():find(text, 1, true), output())
    end
    ns.PvPProbe.Handle("stop")
    assert.is_true(tickers[1].cancelled)
  end)

  it("handles honor before outsider death and reports absent mission service", function()
    ns.PvPProbe.Handle("kills")
    hk = 1
    frames[1].handler(frames[1], "CHAT_MSG_COMBAT_HONOR_GAIN", "honor")
    frames[1].handler(frames[1], "UNIT_DIED", "Player-enemy")
    finish()
    assert.is_truthy(output():find("hk=increase_observed", 1, true))
    assert.is_truthy(output():find("relation=single_temporal_candidate", 1, true))
    assert.is_truthy(output():find("missionStatus=service_unavailable", 1, true))
    assert.is_truthy(output():find("missionEvents=0", 1, true))
  end)

  it("does not treat honor points alone as an HK or multiple victims as certain attribution", function()
    ns.PvPProbe.Handle("kills")
    frames[1].handler(frames[1], "UNIT_DIED", "Player-enemy")
    frames[1].handler(frames[1], "UNIT_DIED", "Player-other")
    honor = 50
    finish()
    assert.is_truthy(output():find("relation=ambiguous", 1, true))
    assert.is_truthy(output():find("hk=no_increase_observed", 1, true))
    assert.is_truthy(output():find("missionEvents=0", 1, true))
  end)

  it("polls late HK updates and reports credit without an observed victim", function()
    ns.PvPProbe.Handle("kills")
    hk = 1
    clock = 12
    tickers[1].tick()
    finish()
    assert.is_truthy(output():find("relation=no_victim", 1, true))
    assert.is_truthy(output():find("hk=increase_observed", 1, true))
  end)

  it("keeps unavailable counters explicit and stops pending summaries", function()
    _G.GetPVPSessionStats = nil
    ns.PvPProbe.Handle("kills")
    frames[1].handler(frames[1], "UNIT_DIED", "Player-enemy")
    finish()
    assert.is_truthy(output():find("hk=unavailable", 1, true))
    frames[1].handler(frames[1], "UNIT_DIED", "Player-enemy")
    ns.PvPProbe.Handle("stop")
    local count = #messages
    finish()
    assert.are.equal(count, #messages)
  end)

  it("reports counter resets without counting them as new HKs", function()
    hk = 20
    ns.PvPProbe.Handle("kills")
    frames[1].handler(frames[1], "UNIT_DIED", "Player-enemy")
    hk = 0
    finish()
    assert.is_truthy(output():find("hk=counters_rebased", 1, true))
  end)

  it("observes retained mission rows at the log cap and reports no active season", function()
    local old = { kind = "kill", victim = "Old" }
    local rows = { old }
    ns.pvpMissions = {
      Events = function()
        return rows
      end,
      deps = { season = {
        ActiveSeason = function()
          return nil
        end,
      } },
    }
    ns.PvPProbe.Handle("kills")
    frames[1].handler(frames[1], "UNIT_DIED", "Player-enemy")
    hk = 1
    rows = { { kind = "kill", victim = "Enemy Name", class = "MAGE", race = "SCOURGE", honor = true } }
    finish()
    assert.is_truthy(output():find("chain_mission_event", 1, true))
    assert.is_truthy(output():find("missionEvents=1", 1, true))
    assert.is_truthy(output():find("activeMissions=0 missionStatus=no_active_season", 1, true))
  end)

  it("captures silently, persists identified HK candidates and reviews them after reload", function()
    ns.character = {}
    ns.PvPProbe.Handle("quiet")
    ns.PvPProbe.Handle("quiet")
    assert.are.equal(1, #frames)
    assert.are.equal(1, #ns.character.pvpProbe.sessions)
    local count = #messages
    frames[1].handler(frames[1], "UNIT_DIED", "Player-enemy")
    hk = 1
    finish()
    assert.are.equal(count, #messages)
    local session = ns.character.pvpProbe.sessions[1]
    local row = session.windows[1]
    assert.are.equal("increase_observed", row.hk)
    assert.are.equal("single_temporal_candidate", row.relation)
    assert.is_truthy(row.victims[1].info:find("name=Enemy Name", 1, true))
    assert.are.equal(1, #row.victims)
    -- SavedVariables preserve plain data, not closures, metatables, or references to game/mission objects.
    local function serializedCopy(value)
      if type(value) ~= "table" then
        assert.is_truthy(type(value) == "string" or type(value) == "number" or type(value) == "boolean")
        return value
      end
      assert.is_nil(getmetatable(value))
      local copy = {}
      for key, field in pairs(value) do
        copy[key] = serializedCopy(field)
      end
      return copy
    end
    frames[1].handler(frames[1], "PLAYER_LOGOUT")
    assert.is_truthy(session.ended)
    ns.character = serializedCopy(ns.character)
    assert(loadfile("NrageAssistant/Core/PvPProbe.lua"))("NrageAssistant", ns)
    messages = {}
    ns.PvPProbe.Handle("report")
    assert.is_truthy(output():find("hkWindows=1", 1, true))
    assert.is_truthy(output():find("name=Enemy Name", 1, true))
    ns.PvPProbe.Handle("detail", tostring(row.id))
    assert.is_truthy(output():find("unit_died_direct", 1, true))
  end)

  it("filters ambiguous windows, excludes uncredited deaths from HK review and marks early stops partial", function()
    ns.character = {}
    ns.PvPProbe.Handle("quiet")
    local handler = frames[1].handler
    handler(frames[1], "UNIT_DIED", "Player-enemy")
    finish()
    handler(frames[1], "UNIT_DIED", "Player-enemy")
    handler(frames[1], "UNIT_DIED", "Player-other")
    hk = 1
    finish()
    handler(frames[1], "UNIT_DIED", "Player-enemy")
    ns.PvPProbe.Handle("stop")
    local rows = ns.character.pvpProbe.sessions[1].windows
    assert.are.equal("no_increase_observed", rows[1].hk)
    assert.are.equal("ambiguous", rows[2].relation)
    assert.are.equal("partial", rows[3].status)
    messages = {}
    ns.PvPProbe.Handle("report", "ambiguous")
    assert.is_truthy(output():find("window=" .. rows[2].id, 1, true))
    assert.is_nil(output():find("window=" .. rows[1].id, 1, true))
    messages = {}
    ns.PvPProbe.Handle("report", "hk")
    assert.is_nil(output():find("window=" .. rows[3].id, 1, true))
  end)

  it("retains restricted GUID warnings silently even without a death window", function()
    ns.character = {}
    ns.PvPProbe.Handle("quiet")
    local count = #messages
    frames[1].handler(frames[1], "UNIT_DIED", false)
    assert.are.equal(count, #messages)
    ns.PvPProbe.Handle("capturelog")
    assert.is_truthy(output():find("unreadable", 1, true))
    assert.is_truthy(output():find("victimGUID=false", 1, true))
  end)

  it("marks multiple HKs ambiguous even with only one observed victim GUID", function()
    ns.character = {}
    ns.PvPProbe.Handle("quiet")
    frames[1].handler(frames[1], "UNIT_DIED", "Player-enemy")
    hk = 2
    finish()
    local row = ns.character.pvpProbe.sessions[1].windows[1]
    assert.are.equal(1, row.candidates)
    assert.are.equal(2, row.hkDelta)
    assert.are.equal("ambiguous", row.relation)
    assert.is_nil(ns.character.pvpLog)
  end)

  it("paginates reports and allows selecting previous capture sessions", function()
    ns.character = {}
    ns.PvPProbe.Handle("quiet")
    for _ = 1, 6 do
      frames[1].handler(frames[1], "UNIT_DIED", "Player-enemy")
      hk = hk + 1
      finish()
    end
    ns.PvPProbe.Handle("stop")
    ns.PvPProbe.Handle("quiet")
    messages = {}
    ns.PvPProbe.Handle("report", "hk 2 1")
    assert.is_truthy(output():find("page=2/2", 1, true))
    assert.is_truthy(output():find("window=6", 1, true))
    assert.is_nil(output():find("window=1", 1, true))
    ns.PvPProbe.Handle("sessions")
    assert.is_truthy(output():find("session=2", 1, true))
  end)

  it("queries a restricted GUID before any inspection and retains readable API results", function()
    ns.character = {}
    local queried, inspections = false, 0
    local restricted = setmetatable({}, {
      __tostring = function()
        error("restricted GUID converted to text")
      end,
      __index = function()
        error("restricted GUID indexed")
      end,
    })
    _G.issecretvalue = function(value)
      if rawequal(value, restricted) then
        assert.is_true(queried)
        inspections = inspections + 1
        return true
      end
      return false
    end
    _G.GetPlayerInfoByGUID = function(value)
      assert.is_true(rawequal(value, restricted))
      queried = true
      return "Mage", "MAGE", "Undead", "Scourge", 3, "Hidden Enemy", ""
    end
    ns.PvPProbe.Handle("quiet")
    frames[1].handler(frames[1], "UNIT_DIED", restricted)
    hk = 1
    finish()
    assert.is_true(queried)
    assert.is_true(inspections > 0)
    local row = ns.character.pvpProbe.sessions[1].windows[1]
    assert.are.equal(1, row.candidates)
    assert.are.equal(0, row.unknownDeaths)
    assert.are.equal("<restricted>", row.victims[1].guid)
    assert.is_truthy(row.victims[1].info:find("GetPlayerInfoByGUID resolved", 1, true))
    assert.is_truthy(row.victims[1].info:find("name=Hidden Enemy", 1, true))
  end)

  it("keeps API rejection of a restricted GUID and prevents a false unique candidate", function()
    ns.character = {}
    local restricted, queried = {}, false
    _G.issecretvalue = function(value)
      return rawequal(value, restricted)
    end
    local resolver = _G.GetPlayerInfoByGUID
    _G.GetPlayerInfoByGUID = function(value)
      if rawequal(value, restricted) then
        queried = true
        error("secret arguments not allowed")
      end
      return resolver(value)
    end
    ns.PvPProbe.Handle("quiet")
    frames[1].handler(frames[1], "UNIT_DIED", "Player-enemy")
    frames[1].handler(frames[1], "PARTY_KILL", "Player-self", restricted)
    hk = 1
    finish()
    assert.is_true(queried)
    local session = ns.character.pvpProbe.sessions[1]
    local row = session.windows[1]
    assert.are.equal(1, row.candidates)
    assert.are.equal(1, row.unknownDeaths)
    assert.are.equal("ambiguous", row.relation)
    ns.PvPProbe.Handle("capturelog")
    assert.is_truthy(output():find("secret arguments not allowed", 1, true))
  end)

  it("does not turn restricted result fields into readable identities", function()
    ns.character = {}
    local restricted = {}
    _G.issecretvalue = function(value)
      return rawequal(value, restricted)
    end
    _G.GetPlayerInfoByGUID = function()
      return "Mage", "MAGE", "Undead", "Scourge", 3, restricted, ""
    end
    ns.PvPProbe.Handle("quiet")
    frames[1].handler(frames[1], "UNIT_DIED", restricted)
    hk = 1
    finish()
    local row = ns.character.pvpProbe.sessions[1].windows[1]
    assert.are.equal(0, row.candidates)
    assert.are.equal(1, row.unknownDeaths)
    assert.are.equal("ambiguous", row.relation)
  end)

  it("excludes self, group allies and friendly races while retaining the HK observation", function()
    ns.character = {}
    local resolver = _G.GetPlayerInfoByGUID
    _G.GetPlayerInfoByGUID = function(guid)
      if guid == "Player-ally" then
        return "Hunter", "HUNTER", "Night Elf", "NightElf", 3, "Ts Il", ""
      end
      return resolver(guid)
    end
    ns.PvPProbe.Handle("quiet")
    local frame = frames[1]
    frame.handler(frame, "UNIT_DIED", "Player-self")
    frame.handler(frame, "UNIT_DIED", "Player-friend")
    frame.handler(frame, "UNIT_DIED", "Player-ally")
    assert.are.equal(0, #ns.character.pvpProbe.sessions[1].windows)
    hk = 1
    finish()
    finish()
    local row = ns.character.pvpProbe.sessions[1].windows[1]
    assert.are.equal("increase_observed", row.hk)
    assert.are.equal(0, row.candidates)
    assert.are.equal("no_victim", row.relation)
    assert.are.equal(0, #row.victims)
    ns.PvPProbe.Handle("capturelog")
    assert.is_truthy(output():find("reason=self", 1, true))
    assert.is_truthy(output():find("reason=ally ", 1, true))
    assert.is_truthy(output():find("reason=ally_race", 1, true))
  end)

  it("uses readable unit hostility instead of assuming an unknown race is an enemy", function()
    ns.character = {}
    guids.mouseover = "Player-enemy"
    _G.UnitIsEnemy = function(_, unit)
      return unit == "mouseover"
    end
    _G.GetPlayerInfoByGUID = function()
      return "Druid", "DRUID", "Skyborne", "Skyborne", 3, "Someone", ""
    end
    ns.PvPProbe.Handle("quiet")
    frames[1].handler(frames[1], "UNIT_DIED", "Player-enemy")
    hk = 1
    finish()
    local row = ns.character.pvpProbe.sessions[1].windows[1]
    assert.are.equal(1, row.candidates)
    assert.are.equal("enemy_unit", row.victims[1].classification)
  end)

  it("rejects the BG log's zero-and-recovery jumps, then detects a genuine subsequent HK", function()
    ns.character = {}
    local lifetime = 70
    _G.GetPVPLifetimeStats = function()
      return lifetime, 0
    end
    ns.PvPProbe.Handle("quiet")
    local function tick()
      clock = clock + 1
      tickers[1].tick()
    end
    local function recover(event, sessionTotal, lifetimeTotal)
      frames[1].handler(frames[1], event)
      hk, lifetime = 0, 0
      tick()
      hk, lifetime = sessionTotal, lifetimeTotal
      for _ = 1, 4 do
        tick()
      end
    end
    -- Reproduce lifetimeHK 0->70 on entering, without counting 70 new kills.
    recover("PLAYER_ENTERING_WORLD", 0, 70)
    assert.are.equal(0, #ns.character.pvpProbe.sessions[1].windows)
    hk, lifetime = 1, 71
    tick()
    finish()
    local rows = ns.character.pvpProbe.sessions[1].windows
    assert.are.equal(1, #rows)
    assert.are.equal(1, rows[1].hkDelta)
    -- Reproduce sessionHK 0->54 and lifetimeHK 0->124 on leaving.
    hk, lifetime = 54, 124
    frames[1].handler(frames[1], "ZONE_CHANGED_NEW_AREA")
    recover("PLAYER_ENTERING_WORLD", 54, 124)
    finish()
    for _, row in ipairs(rows) do
      if row.hk == "increase_observed" then
        assert.are.equal(1, row.hkDelta)
      end
    end
    hk, lifetime = 55, 125
    tick()
    finish()
    assert.are.equal(1, rows[#rows].hkDelta)
    assert.are.equal("increase_observed", rows[#rows].hk)
  end)

  it("invalidates a window across a counter decrease even if no world event arrives", function()
    ns.character = {}
    hk = 20
    ns.PvPProbe.Handle("quiet")
    frames[1].handler(frames[1], "UNIT_DIED", "Player-enemy")
    hk = 0
    clock = clock + 1
    tickers[1].tick()
    hk = 20
    finish()
    local row = ns.character.pvpProbe.sessions[1].windows[1]
    assert.are.equal("counters_rebased", row.hk)
    assert.are.equal(0, row.hkDelta)
  end)

  it("excludes a friendly visible unit even when its race normally belongs to the opposing faction", function()
    ns.character = {}
    guids.mouseover = "Player-enemy"
    _G.UnitIsFriend = function(_, unit)
      return unit == "mouseover"
    end
    ns.PvPProbe.Handle("quiet")
    frames[1].handler(frames[1], "UNIT_DIED", "Player-enemy")
    assert.are.equal(0, #ns.character.pvpProbe.sessions[1].windows)
    ns.PvPProbe.Handle("capturelog")
    assert.is_truthy(output():find("reason=ally ", 1, true))
  end)

  it("keeps an unknown faction or custom race out of enemy candidates", function()
    ns.character = {}
    _G.GetPlayerInfoByGUID = function()
      return "Druid", "DRUID", "Skyborne", "Skyborne", 3, "Someone", ""
    end
    ns.PvPProbe.Handle("quiet")
    frames[1].handler(frames[1], "UNIT_DIED", "Player-enemy")
    hk = 1
    finish()
    local row = ns.character.pvpProbe.sessions[1].windows[1]
    assert.are.equal(0, row.candidates)
    assert.are.equal(1, row.unknownDeaths)
    assert.are.equal("ambiguous", row.relation)
  end)

  it(
    "persists production rejection details and event traces silently without truncating structured evidence",
    function()
      ns.character = {}
      ns.PvPProbe.Handle("quiet")
      local count = #messages
      ns.PvPProbe.RecordWorldTrace("world_kill_death", {
        batchId = 7,
        event = "PARTY_KILL",
        name = "Hubertus Hafer",
        cache = "missing",
        historyState = "unavailable",
        outcome = "unresolved",
        rejection = "cache_missing",
      })
      ns.PvPProbe.RecordWorldDecision({
        reason = "unresolved_deaths",
        victim = "Hubertus Hafer",
        guid = "Player-enemy",
        details = { batchId = 7, credits = 1, unknown = 1, unresolvedReasons = "cache_missing:1" },
      })
      assert.are.equal(count, #messages)
      local session = ns.character.pvpProbe.sessions[1]
      assert.are.equal(3, session.diagnosticVersion)
      local trace, decision = session.records[#session.records - 1], session.records[#session.records]
      assert.are.equal("world_kill_death", trace.kind)
      assert.are.equal("7", trace.fields.batchId)
      assert.are.equal("cache_missing", trace.fields.rejection)
      assert.are.equal("cache_missing:1", decision.fields.unresolvedReasons)
      ns.PvPProbe.Handle("stop")
      local records = #session.records
      ns.PvPProbe.RecordWorldTrace("world_kill_death", { rejection = "outside_capture" })
      assert.are.equal(records, #session.records)
    end
  )
end)
