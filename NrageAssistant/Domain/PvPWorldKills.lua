local _, ns = ...

-- Conservative world-only attribution. Every world honor-name notification and both death events enter the same
-- six-second batch. One matched session/lifetime HK, one hostile identity, no unknown deaths, no competing names.
-- Nothing is replayed after reload: only completed credit IDs are retained by the mission service.
local WorldKills = {}
WorldKills.__index = WorldKills
local SETTLE, MATCH, SEEN, DUPLICATE = 6, 2, 15, 3

function WorldKills.New(deps)
  local self = setmetatable({ deps = deps, enemies = {}, recent = {}, decisions = {}, enabled = false }, WorldKills)
  self.context = deps.contextKey()
  self.counters = deps.counters()
  self.guard = ns.PvPCounterGuard.New(self.counters, self.context or "unavailable")
  return self
end

function WorldKills:Decision(reason, info)
  local decision = { reason = reason, victim = info and info.name, guid = info and info.guid, at = self.deps.now() }
  self.decisions[#self.decisions + 1] = decision
  if #self.decisions > 20 then
    table.remove(self.decisions, 1)
  end
  if self.deps.onDecision then
    self.deps.onDecision(decision)
  end
end

function WorldKills:Reset(reason)
  if self.batch then
    self:Decision(reason)
  end
  self.batch, self.enemies = nil, {}
  self.guard:Reset(reason, self.deps.now())
end

function WorldKills:Remember(info)
  if not self.enabled or not info or not info.guid then
    return
  end
  local now = self.deps.now()
  for guid, row in pairs(self.enemies) do
    if now - row.seen > SEEN then
      self.enemies[guid] = nil
    end
  end
  local count = 0
  for _ in pairs(self.enemies) do
    count = count + 1
  end
  if count >= 500 then
    self.enemies = {}
  end
  self.enemies[info.guid] = { seen = now, name = info.name, class = info.class, race = info.race }
end

function WorldKills:Begin()
  if not self.batch then
    self.batch = { at = self.deps.now(), deaths = {}, names = {}, credits = 0, unknown = 0 }
  end
  return self.batch
end

function WorldKills:OnDeath(rawGUID)
  self:Poll()
  if not self.enabled or not self.context then
    return
  end
  local info = self.deps.deathInfo(rawGUID)
  if info == false then
    return
  end
  local batch = self:Begin()
  if not info then
    batch.unknown = batch.unknown + 1
    return
  end
  local now = self.deps.now()
  local recent = self.recent[info.guid]
  if recent and now - recent <= DUPLICATE then
    return
  end
  self.recent[info.guid] = now
  local cached = self.enemies[info.guid]
  if not cached or now - cached.seen > SEEN then
    batch.unknown = batch.unknown + 1
    return
  end
  info.name = info.name or cached.name
  info.class, info.race = info.class or cached.class, info.race or cached.race
  if not info.name then
    batch.unknown = batch.unknown + 1
    return
  end
  if batch.deaths[info.guid] then
    batch.unknown = batch.unknown + 1
    return
  end
  info.at, info.time = now, self.deps.serverTime()
  info.context = self.deps.killContext(info.name)
  batch.deaths[info.guid] = info
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
  if batch.invalid then
    self:Decision("counter_or_world_changed")
    return
  end
  if batch.credits ~= 1 then
    self:Decision(batch.credits == 0 and "no_hk" or "multiple_hks")
    return
  end
  if batch.unknown > 0 then
    self:Decision("unresolved_deaths")
    return
  end
  if count > 1 or names > 1 then
    self:Decision("multiple_victims")
    return
  end
  if victim and named and victim.name:lower() ~= named.name:lower() then
    self:Decision("conflicting_honor_name")
    return
  end
  victim = victim or named
  if not victim or math.abs(victim.at - batch.creditAt) > MATCH then
    self:Decision("no_nearby_victim")
    return
  end
  if victim.guid and self.deps.isAlive and self.deps.isAlive(victim.guid) == true then
    self:Decision("victim_alive_or_feigning", victim)
    return
  end
  victim.creditId = "world-hk:" .. batch.lifetime
  local accepted = self.deps.commit(victim)
  self:Decision(accepted == false and "duplicate_or_rejected" or "credited", victim)
end

function WorldKills:Poll()
  local now, context = self.deps.now(), self.deps.contextKey()
  if context ~= self.context then
    self:Reset("world_changed")
    self.context = context
  end
  for guid, at in pairs(self.recent) do
    if now - at > DUPLICATE then
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
    end
    self:Finish()
  end
end

ns.PvPWorldKills = WorldKills
