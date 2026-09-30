local _, ns = ...

-- Ties the codec, protocol, inbox guards and outbound queue together.
--   Comm.New(deps) builds the testable core; Comm.Start() wires it to AceComm and timers (client only).
-- Only the GUILD channel is accepted in this MVP. The sender identity always comes from the
-- client event, never from the payload.
local Comm = {}
Comm.__index = Comm

-- deps: platform, codec, inbox, queue, roster (table), events (table), tombstones (table),
--       roleOf(sender) -> role or nil, version (string), now() -> seconds,
--       schedule(delaySeconds, fn), random(low, high) -> number
function Comm.New(deps)
  return setmetatable({
    platform = deps.platform,
    codec = deps.codec,
    inbox = deps.inbox,
    queue = deps.queue,
    roster = deps.roster,
    events = deps.events,
    tombstones = deps.tombstones,
    roleOf = deps.roleOf,
    version = deps.version,
    now = deps.now,
    schedule = deps.schedule,
    random = deps.random,
    peers = {},
    peerCount = 0,
    counter = 0,
    lastHelloAt = nil,
    helloReplyPending = false,
  }, Comm)
end

function Comm:NextId()
  self.counter = self.counter + 1
  return ("%x-%x-%x"):format(self.platform.ServerTime(), self.counter, self.random(0, 0xFFFFFF))
end

function Comm:Flush()
  return self.queue:Flush()
end

-- Encodes and queues a message; the queue holds it back during a lockdown.
function Comm:Send(messageType, payload, key)
  local message = ns.Protocol.Build(messageType, payload, self:NextId())
  local text, reason = self.codec:Encode(message)
  if not text then
    return false, reason
  end
  local ok, queueReason = self.queue:Enqueue(text, key)
  if not ok then
    return false, queueReason
  end
  self:Flush()
  return true
end

function Comm:SendHello()
  self.lastHelloAt = self.now()
  return self:Send("HELLO", { version = self.version }, "HELLO")
end

function Comm:RememberPeer(sender, info)
  local peer = self.peers[sender]
  if not peer then
    if self.peerCount >= ns.Constants.PEERS_MAX_ENTRIES then
      return false
    end
    self.peerCount = self.peerCount + 1
  end
  info.seenAt = self.now()
  self.peers[sender] = info
  return true
end

-- A new peer probably has not seen our HELLO: answer once, jittered and rate limited, so a
-- burst of logins does not turn into a storm of replies.
function Comm:MaybeReplyHello()
  local constants = ns.Constants
  if self.helloReplyPending then
    return
  end
  if self.lastHelloAt and self.now() - self.lastHelloAt < constants.HELLO_REPLY_COOLDOWN_SECONDS then
    return
  end
  self.helloReplyPending = true
  local delay = self.random(constants.HELLO_REPLY_DELAY_MIN, constants.HELLO_REPLY_DELAY_MAX)
  self.schedule(delay, function()
    self.helloReplyPending = false
    self:SendHello()
  end)
end

function Comm:HandleHello(sender, payload)
  local known = self.peers[sender] ~= nil
  if not self:RememberPeer(sender, { version = payload.version }) then
    return false, "peers_full"
  end
  if not known then
    self:MaybeReplyHello()
  end
  return true
end

function Comm:HandleProfile(sender, payload)
  local existing = self.roster[sender]
  if existing and existing.rev >= payload.rev then
    return false, "stale_rev"
  end

  if not existing then
    local count = 0
    for _ in pairs(self.roster) do
      count = count + 1
    end
    if count >= ns.Constants.ROSTER_MAX_ENTRIES then
      return false, "roster_full"
    end
  end

  self.roster[sender] = {
    identityKey = sender,
    rev = payload.rev,
    class = payload.class,
    level = payload.level,
    ilvl = payload.ilvl,
    professions = payload.professions,
    fields = payload.fields,
    source = "received",
    receivedAt = self.platform.ServerTime(),
  }
  return true
end

-- Full receive pipeline. Returns true, or false plus the reason the message was dropped.
function Comm:HandleMessage(text, sender, channel)
  if channel ~= "GUILD" then
    return false, "wrong_channel"
  end
  if type(sender) ~= "string" or sender == "" then
    return false, "bad_sender"
  end
  if sender == self.platform.GetIdentityKey() then
    return false, "own_message"
  end

  -- Cheapest check first: a flooding sender never reaches the decoder.
  if not self.inbox:AllowRate(sender, self.now()) then
    return false, "rate_limited"
  end

  local decoded, reason = self.codec:Decode(text)
  if not decoded then
    return false, reason
  end

  local message
  message, reason = ns.Protocol.Validate(decoded)
  if not message then
    if reason == "incompatible_version" then
      self:RememberPeer(sender, { incompatible = true })
    end
    return false, reason
  end

  if not self.inbox:MarkSeen(sender .. "\n" .. message.id) then
    return false, "duplicate"
  end

  if message.t == "HELLO" then
    return self:HandleHello(sender, message.p)
  end
  if ns.EventSync.IsRaidMessage(message.t) then
    return self:HandleRaid(sender, message)
  end
  return self:HandleProfile(sender, message.p)
end

-- Raid operations: the sender's role is read from the local guild roster, never from the message.
function Comm:HandleRaid(sender, message)
  local ctx = {
    events = self.events,
    tombstones = self.tombstones,
    now = self.platform.ServerTime,
  }
  return ns.EventSync.Apply(ctx, message, sender, self.roleOf(sender))
end

-- Local change -> wire. Each message is keyed so a newer edit of the same record replaces a
-- queued older one instead of both being sent.
function Comm:SendEvent(event)
  return self:Send("EVENT_UPSERT", ns.EventSync.EventPayload(event), "EV:" .. event.eventId)
end

function Comm:SendAttendance(eventId, characterKey, record)
  local payload = ns.EventSync.AttendancePayload(eventId, characterKey, record)
  return self:Send("ATTENDANCE_UPSERT", payload, ("AT:%s:%s"):format(eventId, characterKey))
end

function Comm:SendAssignment(eventId, assignment)
  local payload = ns.EventSync.AssignPayload(eventId, assignment)
  return self:Send("ASSIGN_UPSERT", payload, ("AS:%s:%s"):format(eventId, assignment.assignmentId))
end

function Comm:SendDeleteEvent(eventId)
  local payload = ns.EventSync.DeleteEventPayload(self.tombstones, eventId)
  if not payload then
    return false, "no_tombstone"
  end
  return self:Send("DELETE", payload, "DEL:" .. eventId)
end

function Comm:SendDeleteAssignment(eventId, assignmentId)
  local payload = ns.EventSync.DeleteAssignmentPayload(self.tombstones, eventId, assignmentId)
  if not payload then
    return false, "no_tombstone"
  end
  return self:Send("DELETE", payload, ("DEL:%s:%s"):format(eventId, assignmentId))
end

-- Lines for `/nrage sync`.
function Comm:Status()
  local lines = {}
  if self.queue:IsPaused() then
    lines[1] = "sync paused: encounter in progress"
  else
    lines[1] = "sync ready"
  end
  lines[#lines + 1] = ("queued messages: %d"):format(self.queue:Pending())

  local names = {}
  for name in pairs(self.peers) do
    names[#names + 1] = name
  end
  table.sort(names)
  lines[#lines + 1] = ("peers seen: %d"):format(#names)
  for _, name in ipairs(names) do
    local peer = self.peers[name]
    if peer.incompatible then
      lines[#lines + 1] = ("  %s - incompatible protocol version"):format(name)
    else
      lines[#lines + 1] = ("  %s - addon %s"):format(name, tostring(peer.version))
    end
  end
  return lines
end

-- Client wiring: AceComm transport, flush timer and the login HELLO.
function Comm.Start()
  if ns.comm then
    return ns.comm
  end

  local constants = ns.Constants
  local platform = ns.Platform
  local AceComm = LibStub("AceComm-3.0")

  ns.lockdown = ns.lockdown or ns.LockdownGuard.New(platform)
  platform.RegisterPrefix(constants.ADDON_PREFIX)

  local queue = ns.OutboundQueue.New({
    guard = ns.lockdown,
    now = platform.Now,
    send = function(text)
      AceComm:SendCommMessage(constants.ADDON_PREFIX, text, "GUILD")
    end,
  })

  local comm = Comm.New({
    platform = platform,
    codec = ns.Codec.Default(),
    inbox = ns.Inbox.New(),
    queue = queue,
    roster = ns.db.global.roster,
    events = ns.db.global.events,
    tombstones = ns.db.global.sync.tombstones,
    -- Looked up lazily: the guild roster is created right after Comm starts.
    roleOf = function(sender)
      if not ns.guildRoster then
        return nil
      end
      return ns.PermissionService.RoleOf(ns.guildRoster, sender)
    end,
    version = ns.GetVersion(),
    now = platform.Now,
    schedule = C_Timer.After,
    random = math.random,
  })

  local receiver = {}
  AceComm:Embed(receiver)
  receiver:RegisterComm(constants.ADDON_PREFIX, function(_, message, distribution, sender)
    -- During an encounter arguments can be secret values: any error means "drop it silently".
    pcall(function()
      if ns.active then
        comm:HandleMessage(message, sender, distribution)
      end
    end)
  end)

  C_Timer.NewTicker(constants.QUEUE_FLUSH_SECONDS, function()
    if ns.active and queue:Pending() > 0 then
      comm:Flush()
    end
  end)

  C_Timer.After(math.random(constants.HELLO_LOGIN_DELAY_MIN, constants.HELLO_LOGIN_DELAY_MAX), function()
    if ns.active then
      comm:SendHello()
    end
  end)

  ns.comm = comm
  return comm
end

ns.Comm = Comm
