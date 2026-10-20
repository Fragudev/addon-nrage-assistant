local _, ns = ...

-- The interim slash commands of the PvP seasons (`/nrage pvp ...`), for testing the ledger until the PvP tab has its
-- own sub-tabs (docs/PVP_MISSIONS_PLAN.md, phase 4). Each method returns the lines to show, so the whole thing is
-- testable without a client. Every action goes through PvPSeasonService, which checks the permission and sends.
--   deps: service (PvPSeasonService), formatDate (function(timestamp) -> text, optional)
local PvPSeasonCommands = {}
PvPSeasonCommands.__index = PvPSeasonCommands

local L = ns.L
local Failure = ns.Validate.Failure

local SECONDS_PER_DAY = 86400
local MAX_SEASON_DAYS = 365

function PvPSeasonCommands.New(deps)
  return setmetatable({
    service = deps.service,
    formatDate = deps.formatDate or tostring,
  }, PvPSeasonCommands)
end

local ERRORS = ns.Locale.Table(function()
  return {
    forbidden = L("you are not allowed to do that."),
    active_exists = L("there is a season running already: close it first."),
    no_season = L("there is no season running."),
    closed = L("that season is closed."),
    not_found = L("not found."),
    decided = L("that claim was decided already."),
    unknown_mission = L("that mission does not exist."),
    unknown_player = L("that player is not in the guild."),
    self_grant = L("you cannot approve your own claim."),
    unchanged = L("nothing to change."),
    limit = L("limit reached."),
    inactive = L("that mission is paused."),
    out_of_season = L("that is outside the dates of the season."),
    ["invalid:note"] = L("this mission needs a note."),
    ["invalid:name"] = L("give a plain-text name (up to 40 characters)."),
    ["invalid:dates"] = L("the dates are not valid."),
    ["invalid:title"] = L("give a plain-text title (up to 40 characters)."),
    ["invalid:points"] = L("points go from 1 to 1000."),
    ["invalid:player"] = L("that is not a valid player name."),
    ["invalid:ref"] = L("that is not a valid player or mission."),
  }
end)

local function fail(reason)
  return ERRORS[reason] or tostring(reason)
end

-- Adds a note when the change was saved here but could not be queued for the guild.
local function sentNote(queued)
  if queued then
    return nil
  end
  return L("saved here, but it could not be sent to the guild right now.")
end

local function words(text)
  local list = {}
  for word in text:gmatch("%S+") do
    list[#list + 1] = word
  end
  return list
end

local function rest(list, from)
  return table.concat(list, " ", from)
end

function PvPSeasonCommands.Usage()
  return {
    L("/nrage pvp season [create <days> <name> | close]  the season and its ranking"),
    L("/nrage pvp officer [add | remove <name>]  PvP officers"),
    L("/nrage pvp mission [add <points> <title> | pause | resume <id>]  missions"),
    L("/nrage pvp claim <missionId> [note]  claim a mission"),
    L("/nrage pvp queue | approve <claimId> | reject <claimId> [reason]  claims"),
    L("/nrage pvp grant <player> <missionId> [points]  give points without a claim"),
  }
end

function PvPSeasonCommands:Season(args)
  local service = self.service
  local action = args[1]
  if action == "create" then
    local days = tonumber(args[2])
    if not (days and days >= 1 and days <= MAX_SEASON_DAYS and days % 1 == 0) then
      return Failure(L("give the length of the season in days (1 to 365) and a name."))
    end
    local season, queued = service:CreateSeason({
      name = rest(args, 3),
      endsAt = service.now() + days * SECONDS_PER_DAY,
    })
    if not season then
      return Failure(fail(queued))
    end
    return {
      L("created the season '%s'; it ends %s."):format(season.name, self.formatDate(season.endsAt)),
      sentNote(queued),
    }
  elseif action == "close" then
    local final, expired = service:CloseSeason()
    if not final then
      return Failure(fail(expired))
    end
    return {
      L("closed the season '%s': %d player(s) ranked, %d claim(s) expired."):format(
        final.name,
        #final.standings,
        expired
      ),
    }
  end

  local season = service:ActiveSeason()
  if not season then
    return { L("no PvP season is running.") }
  end
  local lines = {
    L("season '%s': %s to %s, %d mission(s), %d claim(s) waiting."):format(
      season.name,
      self.formatDate(season.startsAt),
      self.formatDate(season.endsAt),
      #service:Missions(season.id),
      #service:Queue()
    ),
  }
  for index, row in ipairs(service:Standings(season.id)) do
    if index > 10 then
      break
    end
    lines[#lines + 1] = L("%d. %s - %d points"):format(row.pos, row.player, row.points)
  end
  return lines
end

function PvPSeasonCommands:Officer(args)
  local service = self.service
  local action, name = args[1], rest(args, 2)
  if action == "add" or action == "remove" then
    local officer, reason = service:SetOfficer(name, action == "add")
    if not officer then
      return Failure(fail(reason))
    end
    return {
      (action == "add" and L("%s is now a PvP officer.") or L("%s is no longer a PvP officer.")):format(name),
    }
  end
  local names = {}
  for _, officer in ipairs(service:Officers()) do
    if officer.active then
      names[#names + 1] = officer.player
    end
  end
  if #names == 0 then
    return { L("there are no PvP officers.") }
  end
  return { L("PvP officers: %s"):format(table.concat(names, ", ")) }
end

function PvPSeasonCommands:Mission(args)
  local service = self.service
  local action = args[1]
  if action == "add" then
    local points = tonumber(args[2])
    if not points then
      return Failure(L("give the points and a title."))
    end
    local mission, reason = service:UpsertMission({
      title = rest(args, 3),
      points = points,
      goal = { kind = "manual" },
      repeatKind = "once",
    })
    if not mission then
      return Failure(fail(reason))
    end
    return { L("created the mission '%s' (id %s, %d points)."):format(mission.title, mission.id, mission.points) }
  elseif action == "pause" or action == "resume" then
    local mission, reason = service:SetMissionActive(args[2] or "", action == "resume")
    if not mission then
      return Failure(fail(reason))
    end
    return {
      (action == "pause" and L("paused the mission '%s'.") or L("resumed the mission '%s'.")):format(mission.title),
    }
  end
  local season = service:ActiveSeason()
  if not season then
    return { L("no PvP season is running.") }
  end
  local lines = {}
  for _, mission in ipairs(service:Missions(season.id, true)) do
    local paused = mission.active and "" or (" " .. L("(paused)"))
    lines[#lines + 1] = L("%s  %d points  %s%s"):format(mission.id, mission.points, mission.title, paused)
  end
  if #lines == 0 then
    return { L("the season has no missions.") }
  end
  return lines
end

function PvPSeasonCommands:Claim(args)
  local claim, queued = self.service:SubmitClaim({
    missionId = args[1] or "",
    note = args[2] and rest(args, 2) or nil,
  })
  if not claim then
    return Failure(fail(queued))
  end
  return { L("claim sent for %s."):format(claim.id), sentNote(queued) }
end

function PvPSeasonCommands:Queue()
  local lines = {}
  for _, claim in ipairs(self.service:Queue()) do
    local mission = self.service:Mission(claim.missionId)
    lines[#lines + 1] = L("%s  %s  %s"):format(claim.id, claim.player, mission and mission.title or claim.missionId)
  end
  if #lines == 0 then
    return { L("no claims waiting.") }
  end
  return lines
end

function PvPSeasonCommands:Approve(args)
  local grant, queued = self.service:Approve(args[1] or "")
  if not grant then
    return Failure(fail(queued))
  end
  return { L("approved %s: %d points for %s."):format(grant.id, grant.points, grant.player), sentNote(queued) }
end

function PvPSeasonCommands:Reject(args)
  local reject, queued = self.service:Reject(args[1] or "", args[2] and rest(args, 2) or nil)
  if not reject then
    return Failure(fail(queued))
  end
  return { L("rejected %s."):format(reject.claimId), sentNote(queued) }
end

function PvPSeasonCommands:Grant(args)
  local grant, queued = self.service:DirectGrant(args[1] or "", args[2] or "", tonumber(args[3]))
  if not grant then
    return Failure(fail(queued))
  end
  return { L("gave %d points to %s."):format(grant.points, grant.player), sentNote(queued) }
end

local HANDLERS = {
  season = PvPSeasonCommands.Season,
  officer = PvPSeasonCommands.Officer,
  mission = PvPSeasonCommands.Mission,
  claim = PvPSeasonCommands.Claim,
  queue = PvPSeasonCommands.Queue,
  approve = PvPSeasonCommands.Approve,
  reject = PvPSeasonCommands.Reject,
  grant = PvPSeasonCommands.Grant,
}

-- Runs the text that follows `/nrage pvp` and returns the lines to show.
function PvPSeasonCommands:Run(text)
  local args = words(text or "")
  local handler = HANDLERS[table.remove(args, 1) or ""]
  if not handler then
    return PvPSeasonCommands.Usage()
  end
  return handler(self, args)
end

ns.PvPSeasonCommands = PvPSeasonCommands
