local _, ns = ...

-- Ties the codec, protocol, inbox guards and outbound queue together.
--   Comm.New(deps) builds the testable core; Comm.Start() wires it to AceComm and timers (client only).
-- Guild traffic arrives on GUILD; a snapshot for a late joiner arrives as a WHISPER from a leader.
-- The sender identity always comes from the client event, never from the payload.
local Comm = {}
Comm.__index = Comm

-- deps: platform, codec, inbox, queue, roster (table), events (table), tombstones (table),
--       pvpStats (table), pvpResets (table), onPvPChange(), onPvPReset(rev) and onPvPKill(sender, payload)
--       (all optional),
--       roleOf(sender) -> role or nil, ownRole() -> role or nil, snapshotInbox (optional),
--       version (string), now() -> seconds, schedule(delaySeconds, fn), random(low, high) -> number
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
    ownRole = deps.ownRole,
    onLootChange = deps.onLootChange,
    pvpStats = deps.pvpStats or {},
    pvpResets = deps.pvpResets or {},
    onPvPChange = deps.onPvPChange,
    onPvPReset = deps.onPvPReset,
    onPvPKill = deps.onPvPKill,
    snapshotInbox = deps.snapshotInbox or ns.Inbox.New({ maxPerWindow = ns.Constants.SYNC_INBOX_MAX_PER_WINDOW }),
    served = {},
    servedCount = 0,
    recentSenders = {},
    lastSyncRequestAt = nil,
    lastSnapshot = nil,
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
-- `options` (optional): { target = whisper recipient, maxBytes = size limit override }.
function Comm:Send(messageType, payload, key, options)
  options = options or {}
  local message = ns.Protocol.Build(messageType, payload, self:NextId())
  local text, reason, detail = self.codec:Encode(message, options.maxBytes)
  if not text then
    return false, reason, detail
  end
  local ok, queueReason = self.queue:Enqueue(text, key, options.target)
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

local MAX_RECENT_SENDERS = 5

-- Remembers the last few senders exactly as the client delivered them, and how they were read, so
-- `/nrage debug senders` can show whether their names match the guild roster.
function Comm:RecordSender(raw, normalized)
  local recent = self.recentSenders
  recent[#recent + 1] = { raw = raw, name = normalized, at = self.now() }
  if #recent > MAX_RECENT_SENDERS then
    table.remove(recent, 1)
  end
end

-- Full receive pipeline. Returns true, or false plus the reason the message was dropped.
function Comm:HandleMessage(text, sender, channel)
  if channel ~= "GUILD" and channel ~= "WHISPER" then
    return false, "wrong_channel"
  end
  if type(sender) ~= "string" or sender == "" then
    return false, "bad_sender"
  end
  -- The client may deliver "Name-Realm" where the guild roster has "Name": compare without the realm.
  local rawSender = sender
  sender = self.platform.NormalizeName(sender)
  self:RecordSender(rawSender, sender)
  if sender == self.platform.GetIdentityKey() then
    return false, "own_message"
  end
  if channel == "WHISPER" then
    return self:HandleWhisper(text, sender)
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
  if message.t == "SYNC_REQ" then
    return self:HandleSyncRequest(sender)
  end
  if ns.EventSync.IsRaidMessage(message.t) then
    return self:HandleRaid(sender, message)
  end
  if message.t == "PROFILE" then
    return self:HandleProfile(sender, message.p)
  end
  if message.t == "PVP_KILL" then
    return self:HandlePvPKill(sender, message.p)
  end
  if ns.PvPSync.IsPvPMessage(message.t) then
    return self:HandlePvP(sender, message)
  end
  -- SYNC_DATA is only ever accepted as a whisper.
  return false, "wrong_channel"
end

-- Snapshot request from a late joiner. Only a leader (RL/admin by guild rank) answers, because
-- only a leader's data will be accepted by the requester; each requester is served at most once per
-- cooldown, after a random delay so several leaders do not all answer at the same instant.
function Comm:HandleSyncRequest(sender)
  local constants = ns.Constants
  if not ns.PermissionService.Can(self.ownRole(), "manage_events") then
    return false, "not_leader"
  end

  local now = self.now()
  local last = self.served[sender]
  if last and now - last < constants.SYNC_SERVE_COOLDOWN_SECONDS then
    return false, "cooldown"
  end
  if not last then
    if self.servedCount >= constants.SYNC_SERVED_MAX_ENTRIES then
      for name, servedAt in pairs(self.served) do
        if now - servedAt >= constants.SYNC_SERVE_COOLDOWN_SECONDS then
          self.served[name] = nil
          self.servedCount = self.servedCount - 1
        end
      end
      if self.servedCount >= constants.SYNC_SERVED_MAX_ENTRIES then
        return false, "busy"
      end
    end
    self.servedCount = self.servedCount + 1
  end
  self.served[sender] = now

  local delay = self.random(constants.SYNC_RESPONSE_DELAY_MIN, constants.SYNC_RESPONSE_DELAY_MAX)
  self.schedule(delay, function()
    self:SendSnapshot(sender)
  end)
  return true
end

-- Whispers `target` the most recent events, halving how many are sent until the message fits.
function Comm:SendSnapshot(target)
  local constants = ns.Constants
  local count = constants.SYNC_MAX_EVENTS
  while count >= 1 do
    -- The PvP part shrinks along with the events, so a snapshot that is too big gets smaller as a whole.
    local pvpMax = math.floor(constants.PVP_SNAPSHOT_MAX * count / constants.SYNC_MAX_EVENTS)
    local items = ns.Transfer.BuildSnapshot(self.events, self.tombstones, count, self:PvPContext(), pvpMax)
    if #items == 0 then
      return false, "empty"
    end
    local ok, reason = self:Send("SYNC_DATA", { items = items }, "SYNC:" .. target, {
      target = target,
      maxBytes = constants.SYNC_MAX_ENCODED_BYTES,
    })
    if ok or reason ~= "too_large" then
      return ok, reason
    end
    count = math.floor(count / 2)
  end
  return false, "too_large"
end

-- Asks the guild for a snapshot; leaders answer by whisper.
function Comm:RequestSync()
  local now = self.now()
  local cooldown = ns.Constants.SYNC_REQUEST_COOLDOWN_SECONDS
  if self.lastSyncRequestAt and now - self.lastSyncRequestAt < cooldown then
    return false, "cooldown"
  end
  self.lastSyncRequestAt = now
  return self:Send("SYNC_REQ", {}, "SYNC_REQ")
end

-- A whisper can only carry a snapshot, and only a leader's snapshot is worth decoding. Both are
-- checked from the local guild roster before any decompression happens, and snapshots have a much
-- stricter rate limit than guild traffic because each one is expensive to decode.
function Comm:HandleWhisper(text, sender)
  local constants = ns.Constants
  local role = self.roleOf(sender)
  if role == nil then
    return false, "unknown_sender"
  end
  if not ns.PermissionService.Can(role, "manage_events") then
    return false, "forbidden"
  end
  if not self.snapshotInbox:AllowRate(sender, self.now()) then
    return false, "rate_limited"
  end

  local decoded, reason = self.codec:Decode(text, {
    encoded = constants.SYNC_MAX_ENCODED_BYTES,
    decompressed = constants.SYNC_MAX_DECOMPRESSED_BYTES,
  })
  if not decoded then
    return false, reason
  end
  local message
  message, reason = ns.Protocol.Validate(decoded)
  if not message then
    return false, reason
  end
  if message.t ~= "SYNC_DATA" then
    return false, "wrong_channel"
  end
  if not self.inbox:MarkSeen(sender .. "\n" .. message.id) then
    return false, "duplicate"
  end

  local ctx = self:PvPContext()
  ctx.events, ctx.tombstones = self.events, self.tombstones
  local summary = ns.Transfer.ApplyItems(message.p.items, ctx, sender, role)
  self.lastSnapshot = { from = sender, applied = summary.applied, total = summary.total, at = self.now() }
  if summary.pvp > 0 and self.onPvPChange then
    self.onPvPChange("SYNC_DATA")
  end
  return true
end

-- Raid operations: the sender's role is read from the local guild roster, never from the message.
function Comm:HandleRaid(sender, message)
  local ctx = {
    events = self.events,
    tombstones = self.tombstones,
    now = self.platform.ServerTime,
  }
  local ok, reason = ns.EventSync.Apply(ctx, message, sender, self.roleOf(sender))
  if ok and self.onLootChange and message.t:sub(1, 5) == "LOOT_" then
    self.onLootChange(message.t)
  end
  return ok, reason
end

-- The tables and callbacks the PvP rules work with.
function Comm:PvPContext()
  return {
    pvpStats = self.pvpStats,
    pvpResets = self.pvpResets,
    now = self.platform.ServerTime,
    ownKey = self.platform.GetIdentityKey,
    onOwnReset = self.onPvPReset,
  }
end

-- PVP_STATS and PVP_RESET: the sender's role is read from the local guild roster, and a record belongs to the
-- sender, never to a name in the payload.
function Comm:HandlePvP(sender, message)
  local ok, reason = ns.PvPSync.Apply(self:PvPContext(), message, sender, self.roleOf(sender))
  if ok and self.onPvPChange then
    self.onPvPChange(message.t)
  end
  return ok, reason
end

-- A kill for the guild feed: nothing is stored here. The killer is the sender (never a payload field); the
-- sender must be a known guild member who may publish PvP data. The feed decides what to show.
function Comm:HandlePvPKill(sender, payload)
  local denied = ns.SyncRules.Authorize(self.roleOf(sender), "pvp_publish")
  if denied then
    return false, denied
  end
  if self.onPvPKill then
    self.onPvPKill(sender, payload)
  end
  return true
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

function Comm:SendLootSession(eventId, session)
  local payload = ns.LootSync.SessionPayload(eventId, session)
  return self:Send("LOOT_SESSION", payload, ("LS:%s:%s"):format(eventId, session.sessionId))
end

function Comm:SendLootAward(eventId, session)
  if not session.award then
    return false, "no_award"
  end
  local payload = ns.LootSync.AwardPayload(eventId, session)
  return self:Send("LOOT_AWARD", payload, ("LA:%s:%s"):format(eventId, session.sessionId))
end

function Comm:SendLootCandidate(eventId, sessionId, candidate)
  local payload = ns.LootSync.CandidatePayload(eventId, sessionId, candidate)
  return self:Send("LOOT_CANDIDATE", payload, ("LC:%s:%s"):format(eventId, sessionId))
end

function Comm:SendLootVote(eventId, sessionId, vote)
  local payload = ns.LootSync.VotePayload(eventId, sessionId, vote)
  return self:Send("LOOT_VOTE", payload, ("LV:%s:%s"):format(eventId, sessionId))
end

-- The own counters. Keyed, so a newer message replaces one still waiting in the queue.
function Comm:SendPvPStats(payload)
  return self:Send("PVP_STATS", payload, "pvp")
end

-- A kill for the feed. Never queued: during the lockdown it is refused instead of waiting, because a kill that
-- is old by the time the encounter ends is not news.
function Comm:SendPvPKill(payload)
  if not self.queue.guard:CanSend() then
    return false, "locked"
  end
  return self:Send("PVP_KILL", payload)
end

-- Admin only: resets a member. The reset is applied here first (own messages are never received), then told to
-- the guild. Returns true, the revision used and whether it was queued; or false plus the reason.
function Comm:ResetPvP(target)
  local role = self.ownRole()
  if not ns.PermissionService.Can(role, "moderate") then
    return false, "forbidden"
  end
  local ctx = self:PvPContext()
  local payload = { target = target, rev = ns.PvPSync.NextResetRev(ctx, target) }
  local message = ns.Protocol.Validate(ns.Protocol.Build("PVP_RESET", payload, "local"))
  if not message then
    return false, "bad_target"
  end
  local ok, reason = ns.PvPSync.Apply(ctx, message, self.platform.GetIdentityKey(), role)
  if not ok then
    return false, reason
  end
  if self.onPvPChange then
    self.onPvPChange(message.t)
  end
  return true, payload.rev, (self:Send("PVP_RESET", message.p, "PVPR:" .. target))
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
  if self.lastSnapshot then
    local snapshot = self.lastSnapshot
    lines[#lines + 1] = ("last snapshot: %d of %d record(s) applied, from %s"):format(
      snapshot.applied,
      snapshot.total,
      snapshot.from
    )
  end

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
    send = function(text, target)
      if target then
        AceComm:SendCommMessage(constants.ADDON_PREFIX, text, "WHISPER", target)
      else
        AceComm:SendCommMessage(constants.ADDON_PREFIX, text, "GUILD")
      end
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
    ownRole = function()
      return ns.PermissionService.OwnRole(platform)
    end,
    onLootChange = function()
      if ns.UI and ns.UI.LootChanged then
        ns.UI.LootChanged()
      end
    end,
    pvpStats = ns.db.global.pvpStats,
    pvpResets = ns.db.global.pvpResets,
    onPvPChange = function()
      if ns.UI and ns.UI.PvPChanged then
        ns.UI.PvPChanged()
      end
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

  -- Late joiners ask for a snapshot once the guild roster has had time to load, so that the
  -- role checks on the answer have something to check against.
  C_Timer.After(math.random(constants.SYNC_LOGIN_REQUEST_DELAY_MIN, constants.SYNC_LOGIN_REQUEST_DELAY_MAX), function()
    if ns.active then
      comm:RequestSync()
    end
  end)

  ns.comm = comm
  return comm
end

ns.Comm = Comm
