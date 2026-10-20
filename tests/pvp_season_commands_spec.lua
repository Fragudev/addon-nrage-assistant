-- The interim /nrage pvp commands: they turn text into service calls and the answers into lines.
local function load_addon()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/PvPSeasonModel",
    "Domain/PvPSeasonService",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/PvPSeasonSync",
    "Commands/PvPSeasonCommands",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_addon()
local T0 = 1792454400

local ROLES = { Boss = "admin", Ann = "member", Off = "member", Bob = "member" }

-- A client named `name` with the real service; `queued` is what its transport answers.
local function build(name)
  local env = { clock = T0, ids = 0, queued = true, sent = {}, roles = ROLES }
  local service = ns.PvPSeasonService.New({
    ledger = ns.PvPSeasonSync.NewLedger(),
    now = function()
      return env.clock
    end,
    newId = function()
      env.ids = env.ids + 1
      return "id-" .. env.ids
    end,
    ownName = function()
      return name
    end,
    ownRole = function()
      return env.roles[name]
    end,
    roleOf = function(who)
      return env.roles[who]
    end,
    send = function(messageType, payload)
      env.sent[#env.sent + 1] = { t = messageType, p = payload }
      return env.queued
    end,
  })
  env.service = service
  env.commands = ns.PvPSeasonCommands.New({
    service = service,
    formatDate = function(timestamp)
      return "date:" .. timestamp
    end,
  })
  function env.run(text)
    local lines = env.commands:Run(text)
    local out = {}
    for _, line in ipairs(lines) do
      out[#out + 1] = line
    end
    return table.concat(out, "\n"), ns.Validate.IsFailure(lines)
  end
  return env
end

describe("PvPSeasonCommands", function()
  local admin

  before_each(function()
    ns.Locale.Use("enUS")
    admin = build("Boss")
  end)

  it("lists the commands for anything it does not know", function()
    for _, text in ipairs({ "", "frobnicate", "   " }) do
      local out, failed = admin.run(text)
      assert.is_truthy(out:find("/nrage pvp season", 1, true))
      assert.is_truthy(out:find("/nrage pvp grant", 1, true))
      assert.is_false(failed)
    end
  end)

  describe("season", function()
    it("says there is none, then creates one and shows it", function()
      assert.are.equal("no PvP season is running.", admin.run("season"))
      local out, failed = admin.run("season create 30 Season One")
      assert.is_false(failed)
      assert.are.equal("created the season 'Season One'; it ends date:" .. (T0 + 30 * 86400) .. ".", out)
      local status = admin.run("season")
      assert.is_truthy(
        status:find(
          "season 'Season One': date:"
            .. T0
            .. " to date:"
            .. (T0 + 30 * 86400)
            .. ", 0 mission(s), 0 claim(s) waiting.",
          1,
          true
        )
      )
    end)

    it("refuses a bad length or name, a second season and a member", function()
      for _, text in ipairs({
        "season create",
        "season create x Name",
        "season create 0 Name",
        "season create 366 Name",
        "season create 1.5 Name",
      }) do
        local out, failed = admin.run(text)
        assert.is_true(failed, text)
        assert.is_truthy(out:find("days"), text)
      end
      assert.is_truthy(admin.run("season create 5"):find("plain%-text name"))
      assert(admin.service:ActiveSeason() == nil)
      admin.run("season create 5 One")
      local out, failed = admin.run("season create 5 Two")
      assert.is_true(failed)
      assert.are.equal("there is a season running already: close it first.", out)
      out, failed = build("Ann").run("season create 5 Mine")
      assert.is_true(failed)
      assert.are.equal("you are not allowed to do that.", out)
    end)

    it("closes the season and says how many were ranked", function()
      admin.run("season create 5 One")
      admin.run("mission add 10 Hunt")
      local missionId = admin.service:Missions(admin.service:ActiveSeason().id)[1].id
      admin.run("grant Ann " .. missionId)
      local out = admin.run("season close")
      assert.are.equal("closed the season 'One': 1 player(s) ranked, 0 claim(s) expired.", out)
      local text, failed = admin.run("season close")
      assert.is_true(failed)
      assert.are.equal("there is no season running.", text)
    end)

    it("shows the ranking, ten rows at most", function()
      admin.run("season create 5 One")
      admin.run("mission add 10 Hunt")
      local missionId = admin.service:Missions(admin.service:ActiveSeason().id)[1].id
      for index = 1, 12 do
        admin.run(("grant Player%02d %s %d"):format(index, missionId, 100 - index))
      end
      local lines = {}
      for line in admin.run("season"):gmatch("[^\n]+") do
        lines[#lines + 1] = line
      end
      assert.are.equal(11, #lines)
      assert.are.equal("1. Player01 - 99 points", lines[2])
      assert.are.equal("10. Player10 - 90 points", lines[11])
    end)
  end)

  describe("officer", function()
    it("lists, adds and removes officers", function()
      admin.run("season create 5 One")
      assert.are.equal("there are no PvP officers.", admin.run("officer"))
      assert.are.equal("Off is now a PvP officer.", admin.run("officer add Off"))
      assert.are.equal("PvP officers: Off", admin.run("officer"))
      assert.are.equal("Off is no longer a PvP officer.", admin.run("officer remove Off"))
      assert.are.equal("there are no PvP officers.", admin.run("officer list"))
    end)

    it("says why it did not", function()
      local out, failed = admin.run("officer add Nobody")
      assert.is_true(failed)
      assert.are.equal("that player is not in the guild.", out)
      out, failed = admin.run("officer remove Bob")
      assert.is_true(failed)
      assert.are.equal("nothing to change.", out)
      out, failed = build("Ann").run("officer add Bob")
      assert.is_true(failed)
      assert.are.equal("you are not allowed to do that.", out)
      assert.is_true(select(2, admin.run("officer add")))
    end)
  end)

  describe("mission", function()
    it("needs a season, then adds, lists, pauses and resumes a manual mission", function()
      assert.are.equal("no PvP season is running.", admin.run("mission"))
      local out, failed = admin.run("mission add 10 Hunt")
      assert.is_true(failed)
      assert.are.equal("there is no season running.", out)
      admin.run("season create 5 One")
      assert.are.equal("the season has no missions.", admin.run("mission"))
      out = admin.run("mission add 25 Hunt them all")
      assert.is_truthy(out:find("created the mission 'Hunt them all' (id id-", 1, true))
      assert.is_truthy(out:find(", 25 points).", 1, true))
      local mission = admin.service:Missions(admin.service:ActiveSeason().id)[1]
      assert.are.equal("manual", mission.goal.kind)
      assert.are.equal("once", mission.repeatKind)
      assert.are.equal(mission.id .. "  25 points  Hunt them all", admin.run("mission"))
      assert.are.equal("paused the mission 'Hunt them all'.", admin.run("mission pause " .. mission.id))
      assert.are.equal(mission.id .. "  25 points  Hunt them all (paused)", admin.run("mission"))
      assert.are.equal("resumed the mission 'Hunt them all'.", admin.run("mission resume " .. mission.id))
    end)

    it("refuses bad points, a missing title and an unknown mission", function()
      admin.run("season create 5 One")
      assert.is_true(select(2, admin.run("mission add x Hunt")))
      assert.is_true(select(2, admin.run("mission add")))
      local out, failed = admin.run("mission add 0 Hunt")
      assert.is_true(failed)
      assert.are.equal("points go from 1 to 1000.", out)
      out, failed = admin.run("mission add 5")
      assert.is_true(failed)
      assert.are.equal("give a plain-text title (up to 40 characters).", out)
      out, failed = admin.run("mission pause nope")
      assert.is_true(failed)
      assert.are.equal("not found.", out)
      assert.is_true(select(2, admin.run("mission pause")))
    end)
  end)

  describe("claims", function()
    local member, missionId

    before_each(function()
      admin.run("season create 5 One")
      admin.run("mission add 10 Hunt")
      missionId = admin.service:Missions(admin.service:ActiveSeason().id)[1].id
      member = build("Ann")
      for _, entry in ipairs(admin.sent) do
        local message = assert(ns.Protocol.Validate(ns.Protocol.Build(entry.t, entry.p, "wire")))
        ns.PvPSeasonSync.Apply(member.service:Context(), message, "Boss")
      end
      member.sent = {}
    end)

    it("claims a manual mission with a note, and the admin sees it in the queue and approves it", function()
      local out, failed = member.run("claim " .. missionId)
      assert.is_true(failed)
      assert.are.equal("this mission needs a note.", out)
      out, failed = member.run("claim " .. missionId .. " I did it on Tuesday")
      assert.is_false(failed)
      assert.is_truthy(out:find("claim sent for Ann:" .. missionId, 1, true))
      local payload = member.sent[1].p
      assert.are.equal("I did it on Tuesday", payload.note)

      assert.are.equal("no claims waiting.", admin.run("queue"))
      assert.is_true(admin.service:ReceiveClaim(payload, "Ann"))
      assert.are.equal(payload.id .. "  Ann  Hunt", admin.run("queue"))
      out = admin.run("approve " .. payload.id)
      assert.are.equal("approved " .. payload.id .. ": 10 points for Ann.", out)
      assert.are.equal("no claims waiting.", admin.run("queue"))
      assert.is_truthy(admin.run("season"):find("1. Ann - 10 points", 1, true))
    end)

    it("rejects a claim with a reason, and says when it cannot", function()
      member.run("claim " .. missionId .. " note")
      local payload = member.sent[1].p
      assert(admin.service:ReceiveClaim(payload, "Ann"))
      assert.are.equal("rejected " .. payload.id .. ".", admin.run("reject " .. payload.id .. " no proof at all"))
      assert.are.equal("no proof at all", admin.service:Rejected()[1].reason)
      local out, failed = admin.run("approve Nobody:x:all:1")
      assert.is_true(failed)
      assert.are.equal("not found.", out)
      out, failed = member.run("approve " .. payload.id)
      assert.is_true(failed)
      assert.are.equal("you are not allowed to do that.", out)
      assert.is_true(select(2, admin.run("reject")))
    end)

    it("gives points without a claim and refuses what is not valid", function()
      assert.are.equal("gave 10 points to Bob.", admin.run("grant Bob " .. missionId))
      assert.are.equal("gave 40 points to Bob.", admin.run("grant Bob " .. missionId .. " 40"))
      local out, failed = admin.run("grant Bob nope")
      assert.is_true(failed)
      assert.are.equal("that mission does not exist.", out)
      out, failed = admin.run("grant a:b " .. missionId)
      assert.is_true(failed)
      assert.are.equal("that is not a valid player or mission.", out)
      out, failed = member.run("grant Bob " .. missionId)
      assert.is_true(failed)
      assert.are.equal("you are not allowed to do that.", out)
      assert.is_true(select(2, admin.run("grant")))
    end)

    it("says when a change was saved here but not sent", function()
      admin.queued = false
      assert.is_truthy(
        admin
          .run("grant Bob " .. missionId)
          :find("saved here, but it could not be sent to the guild right now.", 1, true)
      )
      assert.is_truthy(admin.run("officer add Off"))
      admin.run("season close")
      admin.queued = true
    end)

    it("reports a reason it has no text for as it is", function()
      member.service.SubmitClaim = function()
        return nil, "something_new"
      end
      local out, failed = member.run("claim x")
      assert.is_true(failed)
      assert.are.equal("something_new", out)
    end)
  end)

  it("speaks Spanish when the client does", function()
    ns.Locale.Use("esES")
    assert.is_truthy(build("Boss").run("season"):find("no hay ninguna temporada PvP en curso.", 1, true))
    ns.Locale.Use("enUS")
  end)
end)

describe("PvPSeasonService.ClearMissionLog", function()
  it("drops the kills and claims of the season that closed, and nothing else", function()
    local log = { seasonId = "s1", kills = { { at = 1 } }, claims = { c = {} } }
    assert.is_true(ns.PvPSeasonService.ClearMissionLog(log, "s1"))
    assert.are.same({ kills = {}, claims = {} }, log)
  end)

  it("keeps the log of another season, and copes with no log", function()
    local log = { seasonId = "s2", kills = { { at = 1 } }, claims = {} }
    assert.is_false(ns.PvPSeasonService.ClearMissionLog(log, "s1"))
    assert.are.equal(1, #log.kills)
    assert.is_false(ns.PvPSeasonService.ClearMissionLog(nil, "s1"))
    assert.is_false(ns.PvPSeasonService.ClearMissionLog({}, "s1"))
  end)
end)
