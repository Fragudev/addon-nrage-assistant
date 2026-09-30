local _, ns = ...

-- Local index of the guild roster (name -> rank, level, class), used to look up a sender's rank.
-- Rebuilt in chunks with `schedule`, throttled, bounded, and swapped in only when complete, so
-- readers never see a half-built index. An empty answer (roster not loaded yet) keeps the old one.
local GuildRoster = {}
GuildRoster.__index = GuildRoster

-- deps: platform, schedule(delaySeconds, fn), now() -> seconds
function GuildRoster.New(deps)
  local constants = ns.Constants
  return setmetatable({
    platform = deps.platform,
    schedule = deps.schedule,
    now = deps.now,
    max = deps.max or constants.GUILD_ROSTER_MAX,
    chunk = deps.chunk or constants.GUILD_ROSTER_CHUNK,
    minInterval = deps.minInterval or constants.GUILD_ROSTER_MIN_INTERVAL_SECONDS,
    -- Optional: how this character finds itself in the roster (by GUID) and what to do with the name.
    ownGuid = deps.ownGuid,
    onOwnName = deps.onOwnName,
    entries = {},
    count = 0,
    rebuilding = false,
    dirty = false,
    retryPending = false,
    lastStartedAt = nil,
    lastCompletedAt = nil,
  }, GuildRoster)
end

-- Exact match on the name as the client reports it; no fuzzy matching, so two members can never
-- be confused with each other.
function GuildRoster:Lookup(name)
  if type(name) ~= "string" then
    return nil
  end
  return self.entries[name]
end

-- Every known member name, sorted: what the window offers when a member has to be picked.
function GuildRoster:Names()
  local names = {}
  for name in pairs(self.entries) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

function GuildRoster:Count()
  return self.count
end

function GuildRoster:IsReady()
  return self.lastCompletedAt ~= nil
end

-- The roster is the authority on how this character's name is written, and it gives the GUID of each
-- member: the entry with our own GUID tells us our full name.
function GuildRoster:FindOwnName()
  if not (self.ownGuid and self.onOwnName) then
    return
  end
  local guid = self.ownGuid()
  if not guid then
    return
  end
  for name, entry in pairs(self.entries) do
    if entry.guid == guid then
      self.ownName = name
      self.onOwnName(name)
      return
    end
  end
end

function GuildRoster:Finish(entries, count)
  self.entries = entries
  self.count = count
  self.lastCompletedAt = self.now()
  self.rebuilding = false
  self:FindOwnName()
  if self.dirty then
    self.dirty = false
    self:Rebuild()
  end
end

-- Starts a chunked rebuild from the client's roster. Safe to call at any time.
function GuildRoster:Rebuild()
  if self.rebuilding then
    self.dirty = true
    return
  end

  local total = math.min(self.platform.GetNumGuildMembers(), self.max)
  if total == 0 then
    return
  end

  self.rebuilding = true
  self.lastStartedAt = self.now()

  local entries, count, index = {}, 0, 1
  local function step()
    local last = math.min(index + self.chunk - 1, total)
    for i = index, last do
      local entry = self.platform.GetGuildRosterEntry(i)
      if entry and type(entry.name) == "string" then
        if not entries[entry.name] then
          count = count + 1
        end
        entries[entry.name] = {
          rankName = entry.rankName,
          rankIndex = entry.rankIndex,
          level = entry.level,
          class = entry.class,
          guid = entry.guid,
        }
      end
    end
    index = last + 1
    if index <= total then
      self.schedule(0, step)
    else
      self:Finish(entries, count)
    end
  end
  step()
end

-- Called on GUILD_ROSTER_UPDATE (which fires often): rebuilds at most once per minInterval, and
-- never drops an update, it just delays it.
function GuildRoster:OnUpdate()
  local now = self.now()
  local elapsed = self.lastStartedAt and (now - self.lastStartedAt) or self.minInterval
  if elapsed >= self.minInterval then
    self:Rebuild()
    return
  end
  if not self.retryPending then
    self.retryPending = true
    self.schedule(self.minInterval - elapsed, function()
      self.retryPending = false
      self:Rebuild()
    end)
  end
end

-- Asks the server for a fresh roster; the reply comes back through OnUpdate.
function GuildRoster:Request()
  self.platform.RequestGuildRoster()
end

ns.GuildRoster = GuildRoster
