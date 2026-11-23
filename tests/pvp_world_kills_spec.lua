local ns = {}
for _, file in ipairs({
  "Core/Constants",
  "Core/Locale",
  "Core/Validate",
  "Core/PvPCounterGuard",
  "Domain/PvPSeasonModel",
  "Domain/PvPUnitCache",
  "Domain/PvPMissionTracker",
  "Domain/PvPMissionService",
  "Domain/PvPFeed",
  "Domain/PvPWorldKills",
}) do
  assert(loadfile("NrageAssistant/" .. file .. ".lua"))("NrageAssistant", ns)
end

local function build()
  local env = { now = 100, hk = 172, session = 1, context = "world:2548", commits = {}, map = 2548, group = 0 }
  env.tracker = ns.PvPWorldKills.New({
    now = function()
      return env.now
    end,
    serverTime = function()
      return 10000 + env.now
    end,
    contextKey = function()
      return env.context
    end,
    isAlive = function()
      return env.alive
    end,
    counters = function()
      if env.unavailable then
        return { error = "unavailable" }
      end
      return { sessionHK = env.session, lifetimeHK = env.hk }
    end,
    deathInfo = function(guid)
      if guid == "restricted" then
        return nil
      end
      if guid == "self" or guid == "ally" or guid == "npc" then
        return false
      end
      return {
        guid = guid,
        name = guid == "hunter" and "Xtrap Xtratos" or "Kala Basa",
        class = guid == "hunter" and "HUNTER" or "WARLOCK",
        race = "ORC",
      }
    end,
    killContext = function()
      return { mapId = env.map, guildInGroup = env.group }
    end,
    commit = function(info)
      env.commits[#env.commits + 1] = info
      return true
    end,
  })
  env.tracker.enabled = true
  function env.see(guid)
    env.tracker:Remember({ guid = guid, name = guid == "hunter" and "Xtrap Xtratos" or "Kala Basa" })
  end
  function env.advance(seconds)
    env.now = env.now + seconds
    env.tracker:Poll()
  end
  function env.credit(n)
    env.hk, env.session = env.hk + (n or 1), env.session + (n or 1)
    env.tracker:Poll()
  end
  return env
end

describe("PvPWorldKills", function()
  it(
    "writes one real mission row with class/race, advances filtered progress and rejects replay after reload",
    function()
      local env = build()
      local saved, claims = { events = {} }, {}
      local mission = {
        id = "m1",
        active = true,
        seasonId = "s1",
        repeatKind = "once",
        goal = { kind = "kills", count = 1, place = "world", victimClasses = { "HUNTER" }, victimRaces = { "ORC" } },
      }
      local season = { id = "s1", state = "active", startsAt = 0, endsAt = 20000 }
      local deps = {
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
          return saved
        end,
        claims = function()
          return claims
        end,
        now = function()
          return 10000 + env.now
        end,
        cache = ns.PvPUnitCache.New({
          now = function()
            return env.now
          end,
        }),
        platform = {
          GetPlayerMapId = function()
            return 2548
          end,
          GetPlayerFaction = function()
            return "Alliance"
          end,
        },
      }
      local missions = ns.PvPMissionService.New(deps)
      local feed = ns.PvPFeed.New({
        now = function()
          return env.now
        end,
        serverTime = function()
          return 10000 + env.now
        end,
        schedule = function() end,
        ownName = function()
          return "Self"
        end,
        onHonorKill = function(entry)
          return missions:OnHonorKill(entry)
        end,
      })
      env.tracker.deps.commit = function(info)
        env.commits[#env.commits + 1] = info
        return feed:OnHonorKill(info.name, "world", info)
      end
      env.see("hunter")
      env.tracker:OnDeath("hunter")
      env.tracker:OnDeath("hunter")
      env.credit()
      env.tracker:OnHonorName("Xtrap Xtratos")
      env.advance(7)
      assert.are.equal(1, #saved.events)
      assert.are.equal("HUNTER", saved.events[1].class)
      assert.are.equal("ORC", saved.events[1].race)
      assert.are.equal("world-hk:173", saved.events[1].creditId)
      assert.are.equal(1, missions:Progress("m1").bars[1].done)
      missions = ns.PvPMissionService.New(deps)
      assert.is_false(feed:OnHonorKill("Xtrap Xtratos", "world", env.commits[1]))
      assert.are.equal(1, #saved.events)
      assert.are.equal(1, #feed:Entries())
    end
  )
  it("replays the observed warlock without HK followed by a hostile hunter and HK after 316ms", function()
    local env = build()
    env.see("warlock")
    env.tracker:OnDeath("warlock")
    env.advance(7)
    assert.are.equal(0, #env.commits)
    env.advance(2)
    env.see("hunter")
    env.tracker:OnDeath("hunter")
    env.advance(0.316)
    env.credit()
    env.advance(6)
    assert.are.equal(1, #env.commits)
    local row = env.commits[1]
    assert.are.equal("Xtrap Xtratos", row.name)
    assert.are.equal("HUNTER", row.class)
    assert.are.equal("ORC", row.race)
    assert.are.equal("world-hk:173", row.creditId)
  end)

  it("handles HK before death, duplicated raid notifications and PARTY_KILL/UNIT_DIED for the same GUID", function()
    local env = build()
    env.see("hunter")
    env.credit()
    env.tracker:Poll()
    env.advance(0.5)
    env.tracker:OnDeath("hunter")
    env.tracker:OnDeath("hunter")
    env.advance(6)
    env.tracker:Poll()
    assert.are.equal(1, #env.commits)
  end)

  it("merges named honor and death into a single credit, including repeated named notifications", function()
    local env = build()
    env.see("hunter")
    env.tracker:OnDeath("hunter")
    env.credit()
    assert.is_true(env.tracker:OnHonorName("Xtrap Xtratos"))
    env.tracker:OnHonorName("Xtrap Xtratos")
    env.advance(7)
    env.tracker:OnHonorName("Xtrap Xtratos")
    env.advance(7)
    assert.are.equal(1, #env.commits)
  end)

  it("preserves a directly named honor victim when no death event is available", function()
    local env = build()
    env.credit()
    env.tracker:OnHonorName("Direct Victim")
    env.advance(7)
    assert.are.equal("Direct Victim", env.commits[1].name)
  end)

  for _, scenario in ipairs({
    "two_enemies",
    "unknown_death",
    "two_hks",
    "conflicting_name",
    "no_hk",
    "unseen",
    "stale",
  }) do
    it("refuses ambiguity or missing evidence: " .. scenario, function()
      local env = build()
      if scenario ~= "unseen" then
        env.see("hunter")
      end
      if scenario == "stale" then
        env.advance(16)
      end
      env.tracker:OnDeath("hunter")
      if scenario == "two_enemies" then
        env.see("warlock")
        env.tracker:OnDeath("warlock")
      end
      if scenario == "unknown_death" then
        env.tracker:OnDeath("restricted")
      end
      if scenario == "conflicting_name" then
        env.tracker:OnHonorName("Another Victim")
      end
      if scenario ~= "no_hk" then
        env.credit(scenario == "two_hks" and 2 or 1)
      end
      env.advance(7)
      assert.are.equal(0, #env.commits)
    end)
  end

  it("ignores self, allies and NPCs without invalidating a genuine enemy HK", function()
    local env = build()
    for _, guid in ipairs({ "self", "ally", "npc" }) do
      env.tracker:OnDeath(guid)
    end
    env.see("hunter")
    env.tracker:OnDeath("hunter")
    env.credit()
    env.advance(7)
    assert.are.equal(1, #env.commits)
  end)

  it("does not transfer a late HK from an old death onto a new candidate", function()
    local env = build()
    env.see("hunter")
    env.tracker:OnDeath("hunter")
    env.advance(4)
    env.credit()
    env.advance(3)
    assert.are.equal(0, #env.commits)
  end)

  it("waits for session/lifetime counter updates to agree without counting their notifications twice", function()
    local env = build()
    env.see("hunter")
    env.tracker:OnDeath("hunter")
    env.session = env.session + 1
    env.tracker:Poll()
    env.advance(0.5)
    env.hk = env.hk + 1
    env.tracker:Poll()
    env.advance(6)
    assert.are.equal(1, #env.commits)
  end)

  it("refuses a reload history, counter recovery, BG entry and module deactivation", function()
    for _, scenario in ipairs({ "reload", "recovery", "bg", "disabled" }) do
      local env = build()
      env.see("hunter")
      env.tracker:OnDeath("hunter")
      if scenario == "reload" then
        env.tracker:Reset("reload")
      elseif scenario == "recovery" then
        env.hk, env.session = 0, 0
        env.advance(0.5)
      elseif scenario == "bg" then
        env.context = nil
        env.advance(0.5)
      else
        env.tracker.enabled = false
      end
      env.hk, env.session = 173, 2
      env.advance(7)
      assert.are.equal(0, #env.commits, scenario)
    end
  end)

  it("captures map and group filters at the death, not at deferred commit", function()
    local env = build()
    env.group = 2
    env.see("hunter")
    env.tracker:OnDeath("hunter")
    env.credit()
    env.group, env.map = 0, 999
    env.advance(7)
    assert.are.equal(2, env.commits[1].context.guildInGroup)
    assert.are.equal(2548, env.commits[1].context.mapId)
  end)

  it("vetoes a candidate that is visibly alive or feigning death at settlement", function()
    local env = build()
    env.see("hunter")
    env.tracker:OnDeath("hunter")
    env.credit()
    env.alive = true
    env.advance(7)
    assert.are.equal(0, #env.commits)
    assert.are.equal("victim_alive_or_feigning", env.tracker.decisions[1].reason)
  end)
end)
