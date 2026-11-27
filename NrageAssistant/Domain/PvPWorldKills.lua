local _, ns = ...

-- Conservative world-only attribution. Every world honor-name notification and both death events enter the same
-- six-second batch. One matched session/lifetime HK, one hostile identity, no unknown deaths, no competing names.
-- Nothing is replayed after reload: only completed credit IDs are retained by the mission service.
local WorldKills = {}
WorldKills.__index = WorldKills
local SETTLE, MATCH, SEEN, DUPLICATE = 6, 2, 15, 3

function WorldKills.New(deps)
  local self = setmetatable({
    deps = deps,
    enemies = {},
    recent = {},
    decisions = {},
    enabled = false,
    cacheHistory = {},
    historyOrder = {},
    nextBatch = 0,
  }, WorldKills)
  self.context = deps.contextKey()
  self.counters = deps.counters()
  self.guard = ns.PvPCounterGuard.New(self.counters, self.context or "unavailable")
  return self
end

function WorldKills:Trace(kind, fields)
  fields.batchId = self.batch and self.batch.id or fields.batchId
  if self.deps.onTrace then
    pcall(self.deps.onTrace, kind, fields)
  end
end

function WorldKills:Decision(reason, info, details)
  local decision = { reason = reason, victim = info and info.name, guid = info and info.guid, at = self.deps.now() }
  decision.details = details
  self.decisions[#self.decisions + 1] = decision
  if #self.decisions > 20 then
    table.remove(self.decisions, 1)
  end
  if self.deps.onDecision then
    self.deps.onDecision(decision)
  end
end

function WorldKills:CacheHistory(guid, row, state)
  if not self.cacheHistory[guid] then
    self.historyOrder[#self.historyOrder + 1] = guid
    if #self.historyOrder > 512 then
      self.cacheHistory[table.remove(self.historyOrder, 1)] = nil
    end
  end
  self.cacheHistory[guid] = { seen = row.seen, unit = row.unit, state = state }
end

function WorldKills:Reset(reason)
  if self.batch then
    self:Decision(reason, self.batch.firstUnknown, { batchId = self.batch.id, unknown = self.batch.unknown })
  end
  for guid, row in pairs(self.enemies) do
    self:CacheHistory(guid, row, "reset:" .. reason)
  end
  self.batch, self.enemies = nil, {}
  self.guard:Reset(reason, self.deps.now())
end

function WorldKills:Remember(info, unit)
  if not self.enabled or not info or not info.guid then
    return
  end
  local now = self.deps.now()
  for guid, row in pairs(self.enemies) do
    if now - row.seen > SEEN then
      self:CacheHistory(guid, row, "expired")
      self.enemies[guid] = nil
    end
  end
  local count = 0
  for _ in pairs(self.enemies) do
    count = count + 1
  end
  if count >= 500 then
    for guid, row in pairs(self.enemies) do
      self:CacheHistory(guid, row, "capacity")
    end
    self.enemies = {}
  end
  self.enemies[info.guid] = { seen = now, name = info.name, class = info.class, race = info.race, unit = unit }
  self:CacheHistory(info.guid, self.enemies[info.guid], "present")
end

function WorldKills:Begin()
  if not self.batch then
    self.nextBatch = self.nextBatch + 1
    self.batch = {
      id = self.nextBatch,
      at = self.deps.now(),
      deaths = {},
      names = {},
      credits = 0,
      unknown = 0,
      unknownReasons = {},
    }
  end
  return self.batch
end

function WorldKills:OnDeath(rawGUID, event, attacker)
  self:Poll()
  if not self.enabled or not self.context then
    return
  end
  local info, platform = self.deps.deathInfo(rawGUID)
  local fields = { event = event or "UNIT_DIED", context = self.context }
  for key, value in pairs(platform or {}) do
    fields[key] = value
  end
  if info == false then
    fields.outcome = "ignored"
    self:Trace("world_kill_death", fields)
    return
  end
  local batch = self:Begin()
  local function unresolved(reason)
    fields.outcome, fields.rejection = "unresolved", reason
    batch.unknown = batch.unknown + 1
    batch.unknownReasons[reason] = (batch.unknownReasons[reason] or 0) + 1
    batch.firstUnknown = batch.firstUnknown or info
    self:Trace("world_kill_death", fields)
  end
  if not info then
    unresolved("identity_unresolved")
    return
  end
  local now = self.deps.now()
  fields.guid, fields.name, fields.class, fields.race = info.guid, info.name, info.class, info.race
  local cached, history = self.enemies[info.guid], self.cacheHistory[info.guid]
  fields.cache = cached and (now - cached.seen > SEEN and "expired" or "present") or "missing"
  fields.cacheAge, fields.cacheUnit = cached and now - cached.seen, cached and cached.unit
  fields.historyState, fields.historyAge = history and history.state or "unavailable", history and now - history.seen
  fields.historyUnit = history and history.unit
  if self.deps.hostilityEvidence then
    local ok, evidence = pcall(self.deps.hostilityEvidence, info.guid, attacker)
    evidence = ok and type(evidence) == "table" and evidence or { hostility = "read_error" }
    evidence.event, evidence.guid, evidence.name = fields.event, info.guid, info.name
    self:Trace("world_kill_hostility", evidence)
    fields.hostility, fields.hostilityUnit = evidence.hostility, evidence.hostilityUnit
  end
  local recent = self.recent[info.guid]
  if recent and now - recent.at <= DUPLICATE then
    fields.outcome, fields.duplicateAge = "duplicate_ignored", now - recent.at
    fields.previousOutcome = recent.outcome
    self:Trace("world_kill_death", fields)
    return
  end
  local observation = { at = now, outcome = "unresolved" }
  self.recent[info.guid] = observation
  if not cached or now - cached.seen > SEEN then
    observation.outcome = cached and "cache_expired" or "cache_missing"
    unresolved(observation.outcome)
    return
  end
  info.name = info.name or cached.name
  info.class, info.race = info.class or cached.class, info.race or cached.race
  if not info.name then
    observation.outcome = "name_unavailable"
    unresolved(observation.outcome)
    return
  end
  if batch.deaths[info.guid] then
    observation.outcome = "repeat_death"
    unresolved(observation.outcome)
    return
  end
  info.at, info.time = now, self.deps.serverTime()
  info.context = self.deps.killContext(info.name)
  batch.deaths[info.guid] = info
  observation.outcome, fields.outcome = "candidate", "candidate"
  self:Trace("world_kill_death", fields)
end

-- Returns true when this route owns the notification. No immediate legacy write can race its deferred result.
function WorldKills:OnHonorName(name)
  self:Poll()
  if not self.enabled or not self.context then
    return false
  end
  local batch = self:Begin()
  batch.names[name:lower()] =
    { name = name, time = self.deps.serverTime(), at = self.deps.now(), context = self.deps.killContext(name) }
  return true
end

function WorldKills:Finish()
  local batch = self.batch
  self.batch = nil
  local count, victim, names, named = 0, nil, 0, nil
  for _, info in pairs(batch.deaths) do
    count, victim = count + 1, info
  end
  for _, info in pairs(batch.names) do
    names, named = names + 1, info
  end
  local reasons = {}
  for reason, total in pairs(batch.unknownReasons) do
    reasons[#reasons + 1] = reason .. ":" .. total
  end
  table.sort(reasons)
  local details = {
    batchId = batch.id,
    candidates = count,
    namedVictims = names,
    credits = batch.credits,
    unknown = batch.unknown,
    unresolvedReasons = table.concat(reasons, ","),
    invalidReason = batch.invalidReason,
    duration = self.deps.now() - batch.at,
    lifetime = batch.lifetime,
  }
  local function decide(reason, info)
    self:Decision(reason, info or batch.firstUnknown, details)
  end
  if batch.invalid then
    decide("counter_or_world_changed")
    return
  end
  if batch.credits ~= 1 then
    decide(batch.credits == 0 and "no_hk" or "multiple_hks")
    return
  end
  if batch.unknown > 0 then
    decide("unresolved_deaths")
    return
  end
  if count > 1 or names > 1 then
    decide("multiple_victims")
    return
  end
  if victim and named and victim.name:lower() ~= named.name:lower() then
    decide("conflicting_honor_name", victim)
    return
  end
  victim = victim or named
  details.creditOffset = victim and batch.creditAt and victim.at - batch.creditAt
  if not victim or math.abs(victim.at - batch.creditAt) > MATCH then
    decide("no_nearby_victim", victim)
    return
  end
  if victim.guid and self.deps.isAlive and self.deps.isAlive(victim.guid) == true then
    decide("victim_alive_or_feigning", victim)
    return
  end
  victim.creditId = "world-hk:" .. batch.lifetime
  local accepted = self.deps.commit(victim)
  decide(accepted == false and "duplicate_or_rejected" or "credited", victim)
end

function WorldKills:Poll()
  local now, context = self.deps.now(), self.deps.contextKey()
  if context ~= self.context then
    self:Reset("world_changed")
    self.context = context
  end
  for guid, at in pairs(self.recent) do
    if now - at.at > DUPLICATE then
      self.recent[guid] = nil
    end
  end
  local current = self.guard:Observe(self.deps.counters(), context or "unavailable", now)
  if not self.enabled or not context then
    self.batch, self.counters = nil, current
    return
  end
  local previous = self.counters
  if
    current.error
    or previous.error
    or current.guardReason
    or previous.guardReason
    or current.epoch ~= previous.epoch
  then
    if self.batch then
      self.batch.invalid = true
      self.batch.invalidReason = current.error
        or previous.error
        or current.guardReason
        or previous.guardReason
        or "counter_epoch_changed"
    end
    self.counters = current
  elseif type(current.sessionHK) == "number" and type(current.lifetimeHK) == "number" then
    local session = current.sessionHK - previous.sessionHK
    local lifetime = current.lifetimeHK - previous.lifetimeHK
    -- Wait for both APIs to catch up. A single lagging counter cannot grant another credit later.
    if session == lifetime and session >= 0 then
      if session > 0 then
        local batch = self:Begin()
        batch.credits = batch.credits + session
        batch.creditAt, batch.lifetime = now, current.lifetimeHK
      end
      self.counters = current
    end
  end
  if self.batch and now - self.batch.at >= SETTLE then
    if current.sessionHK ~= self.counters.sessionHK or current.lifetimeHK ~= self.counters.lifetimeHK then
      self.batch.invalid = true
      self.batch.invalidReason = self.batch.invalidReason or "counter_disagreement"
    end
    self:Finish()
  end
end

ns.PvPWorldKills = WorldKills
