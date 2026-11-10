local _, ns = ...

-- Shares how far this character is in each mission of the active season (docs/ANNOUNCEMENTS_MODULES_PVP_PLAN.md, C.7),
-- so an approver can see who is close to a goal. It sends the numbers only (no evidence), at most once per
-- PVP_PROGRESS_INTERVAL_SECONDS and only when they changed since the last time. Nothing here touches the client: the
-- mission service, the transport, the clock and the timers are injected, so the rules are tested with fakes.
--
-- deps = { missions = PvPMissionService, season = PvPSeasonService, send = function(payload) -> boolean, reason,
--          now = function() -> seconds, schedule = function(delay, fn), random = function(min, max),
--          isActive = function() -> boolean }
local PvPProgressPublisher = {}
PvPProgressPublisher.__index = PvPProgressPublisher

function PvPProgressPublisher.New(deps)
  return setmetatable({ deps = deps, pending = false, lastKey = nil, lastAt = nil }, PvPProgressPublisher)
end

-- { seasonId, rows = { { missionId, count, goal } } } for the active season, or nil when there is none. Only the
-- missions with something counted are listed, and a manual mission never (nothing is counted for it). A mission with
-- two bars (classes and races) adds them up.
function PvPProgressPublisher:Payload()
  local season = self.deps.season:ActiveSeason()
  if not (season and season.state == "active") then
    return nil
  end
  local rows = {}
  for _, mission in ipairs(self.deps.season:Missions(season.id)) do
    if mission.goal.kind ~= "manual" then
      local progress = self.deps.missions:Progress(mission.id)
      if progress and #progress.bars > 0 then
        local count, goal = 0, 0
        for _, bar in ipairs(progress.bars) do
          count, goal = count + bar.done, goal + bar.total
        end
        if count > 0 and goal > 0 then
          rows[#rows + 1] = { missionId = mission.id, count = math.min(count, goal), goal = goal }
        end
      end
    end
  end
  return { seasonId = season.id, rows = rows }
end

-- What identifies the content of a payload: the season and its rows.
local function keyOf(payload)
  local parts = { payload.seasonId }
  for _, row in ipairs(payload.rows) do
    parts[#parts + 1] = ("%s=%d/%d"):format(row.missionId, row.count, row.goal)
  end
  return table.concat(parts, ";")
end

-- Sends the progress now when it changed. Returns true, or false plus "no_season" | "unchanged" | "empty" | the
-- reason the transport gave ("locked").
function PvPProgressPublisher:Send()
  local payload = self:Payload()
  if not payload then
    return false, "no_season"
  end
  local key = keyOf(payload)
  if key == self.lastKey then
    return false, "unchanged"
  end
  -- Nothing counted and nothing told before: there is nothing to say. After a summary, an empty one clears it.
  if #payload.rows == 0 and self.lastKey == nil then
    return false, "empty"
  end
  local ok, sent, reason = pcall(self.deps.send, payload)
  if not ok or not sent then
    return false, ok and reason or "error"
  end
  self.lastKey = key
  self.lastAt = self.deps.now()
  return true
end

-- Something may have changed: a send is planned, no sooner than PVP_PROGRESS_INTERVAL_SECONDS after the last one (and
-- never two planned at once). A send the transport refused (the lockdown) is tried again after the interval.
function PvPProgressPublisher:Changed()
  if self.pending or not self.deps.isActive() then
    return false
  end
  local constants = ns.Constants
  local wait = constants.PVP_SYNC_MIN_DELAY_SECONDS
  local anchor = math.max(self.lastAt or -math.huge, self.retryAt or -math.huge)
  if anchor > -math.huge then
    wait = math.max(wait, constants.PVP_PROGRESS_INTERVAL_SECONDS - (self.deps.now() - anchor))
  end
  self.pending = true
  self.deps.schedule(wait, function()
    self.pending = false
    if not self.deps.isActive() then
      return
    end
    local sent, reason = self:Send()
    if not sent and reason == "locked" then
      self.retryAt = self.deps.now()
      self:Changed()
    end
  end)
  return true
end

-- A while after login, so the approvers see where this member stands without waiting for the next kill.
function PvPProgressPublisher:SendAtLogin()
  local constants = ns.Constants
  self.deps.schedule(
    self.deps.random(constants.PVP_LOGIN_SEND_DELAY_MIN, constants.PVP_LOGIN_SEND_DELAY_MAX),
    function()
      self:Changed()
    end
  )
end

ns.PvPProgressPublisher = PvPProgressPublisher
