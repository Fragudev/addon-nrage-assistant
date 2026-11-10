local _, ns = ...

-- Ties the codec, protocol, inbox guards and outbound queue together.
--   Comm.New(deps) builds the testable core; Comm.Start() wires it to AceComm and timers (client only).
-- Guild traffic arrives on GUILD; a snapshot for a late joiner arrives as a WHISPER from a leader.
-- The sender identity always comes from the client event, never from the payload.
local Comm = {}

local L = ns.L
Comm.__index = Comm

-- deps: platform, codec, inbox, queue, roster (table), events (table), tombstones (table),
--       pvpStats (table), pvpResets (table), onPvPChange(), onPvPReset(rev) and onPvPKill(sender, payload)
--       (all optional), blacklist (table) and onBlacklistChange(messageType) (optional), guildKos (the guild Kill On
--       Sight table) and onGuildKosChange(messageType) (optional),
--       layerDirectory, layerSwap and onLayerChange(messageType), lfgService and onLfgChange(messageType) (all
--       optional),
--       rosters and members (tables: raid rosters, and the role and roster of each member) and
--       onRosterChange(messageType) (optional), pvpSeason (the season ledger table, see PvPSeasonSync),
--       onPvPSeasonChange(messageType) and onPvPSeasonClosed(seasonId) (optional), ledgerInbox (optional),
--       rankMaps (the rank maps by guild, see RankMapSync), guildKey() -> key or nil, entryOf(name) -> { rankName,
--       rankIndex } or nil (the guild roster) and onRanksChange(messageType) (optional),
--       roleOf(sender) -> role or nil, ownRole() -> role or nil, isOnline(name) -> boolean or nil (optional),
--       snapshotInbox (optional), version (string), now() -> seconds, schedule(delaySeconds, fn),
--       random(low, high) -> number, onPeerSeen(sender, info) (optional: every valid message from a member, info as
--       InstallDirectory.Note takes it)
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
    isOnline = deps.isOnline,
    onLootChange = deps.onLootChange,
    onEventChange = deps.onEventChange,
    pvpStats = deps.pvpStats or {},
    pvpResets = deps.pvpResets or {},
    onPvPChange = deps.onPvPChange,
    onPvPReset = deps.onPvPReset,
    onPvPKill = deps.onPvPKill,
    blacklist = deps.blacklist or {},
    onBlacklistChange = deps.onBlacklistChange,
    guildKos = deps.guildKos or {},
    onGuildKosChange = deps.onGuildKosChange,
    readinessRules = deps.readinessRules or {},
    onRulesChange = deps.onRulesChange,
    rankMaps = deps.rankMaps or {},
    guildKey = deps.guildKey,
    entryOf = deps.entryOf,
    onRanksChange = deps.onRanksChange,
    -- The layer directory and swap flow are in memory and created after Comm (Init.StartLayer sets them).
    layerDirectory = deps.layerDirectory,
    layerSwap = deps.layerSwap,
    onLayerChange = deps.onLayerChange,
    -- The Groups service is in memory and created after Comm (Init.StartLfg sets it).
    lfgService = deps.lfgService,
    onLfgChange = deps.onLfgChange,
    rosters = deps.rosters or {},
    members = deps.members or {},
    onRosterChange = deps.onRosterChange,
    recipes = deps.recipes or {},
    onRecipesChange = deps.onRecipesChange,
    pvpSeason = deps.pvpSeason or {},
    onPvPSeasonChange = deps.onPvPSeasonChange,
    onPvPSeasonClosed = deps.onPvPSeasonClosed,
    -- Ledger pages arrive in bursts (one whisper per page), so they have a limit of their own.
    ledgerInbox = deps.ledgerInbox or ns.Inbox.New({ maxPerWindow = ns.Constants.PVP_LEDGER_PAGES_MAX }),
    ledgerServed = {},
    ledgerServedCount = 0,
    lastLedgerRequestAt = nil,
    -- Until when a catch-up whisper is expected: set by the own ledger request, a page outside it is unsolicited.
    ledgerExpectedUntil = nil,
    lastLedger = nil,
    -- A reply dropped as unknown_sender (the guild roster was not loaded): the requests are repeated, a bounded number
    -- of times.
    droppedUnknown = false,
    retryPending = false,
    retryCount = 0,
    -- The last failure worth looking at in `/nrage debug`, and how many there were.
    lastError = nil,
    errorCount = 0,
    recipeStaging = {},
    snapshotInbox = deps.snapshotInbox or ns.Inbox.New({ maxPerWindow = ns.Constants.SYNC_INBOX_MAX_PER_WINDOW }),
    served = {},
    servedCount = 0,
    deferred = {},
    deferredCount = 0,
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
    onPeerSeen = deps.onPeerSeen,
    lastAskAt = nil,
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

-- Asks every member online for its version: a HELLO with `ask`, which each one answers like a new peer (delayed and
-- rate limited on its side). At most once every INSTALL_ASK_COOLDOWN_SECONDS here. Returns true, or false plus
-- "cooldown" (and the seconds left) or what Send reported.
function Comm:AskVersions()
  local now = self.now()
  local cooldown = ns.Constants.INSTALL_ASK_COOLDOWN_SECONDS
  if self.lastAskAt and now - self.lastAskAt < cooldown then
    return false, "cooldown", math.ceil(cooldown - (now - self.lastAskAt))
  end
  local ok, reason = self:Send("HELLO", { version = self.version, ask = true }, "HELLO")
  if not ok then
    return false, reason
  end
  self.lastAskAt = now
  self.lastHelloAt = now
  return true
end

-- Tells onPeerSeen that `sender` runs the addon. A failing listener must not drop the message.
function Comm:NotePeer(sender, info)
  if self.onPeerSeen then
    pcall(self.onPeerSeen, sender, info)
  end
end

-- Makes room for a new peer: the ones not heard from for PEERS_TTL_SECONDS go first, then the one seen longest ago.
function Comm:MakePeerRoom(now)
  local constants = ns.Constants
  local oldestName, oldestAt
  for name, peer in pairs(self.peers) do
    if now - peer.seenAt >= constants.PEERS_TTL_SECONDS then
      self.peers[name] = nil
      self.peerCount = self.peerCount - 1
    elseif not oldestAt or peer.seenAt < oldestAt or (peer.seenAt == oldestAt and name < oldestName) then
      oldestName, oldestAt = name, peer.seenAt
    end
  end
  if self.peerCount >= constants.PEERS_MAX_ENTRIES and oldestName then
    self.peers[oldestName] = nil
    self.peerCount = self.peerCount - 1
  end
end

function Comm:RememberPeer(sender, info)
  local now = self.now()
  if not self.peers[sender] then
    if self.peerCount >= ns.Constants.PEERS_MAX_ENTRIES then
      self:MakePeerRoom(now)
    end
    self.peerCount = self.peerCount + 1
  end
  info.seenAt = now
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
  self:RememberPeer(sender, { version = payload.version })
  if not known or payload.ask then
    self:MaybeReplyHello()
  end
  return true
end

-- Makes room for a received profile: when the table is full the received one that arrived longest ago goes (a member
-- who left the guild stops sending), as PvPSync does. The own profile and anything else not received is never evicted.
-- Returns false when the table is full of those.
function Comm:MakeRosterRoom()
  local count = 0
  local oldestName, oldestAt
  for name, entry in pairs(self.roster) do
    count = count + 1
    if type(entry) == "table" and entry.source == "received" then
      local at = type(entry.receivedAt) == "number" and entry.receivedAt or 0
      if not oldestAt or at < oldestAt or (at == oldestAt and name < oldestName) then
        oldestName, oldestAt = name, at
      end
    end
  end
  if count < ns.Constants.ROSTER_MAX_ENTRIES then
    return true
  end
  if not oldestName then
    return false
  end
  self.roster[oldestName] = nil
  return true
end

function Comm:HandleProfile(sender, payload)
  local existing = self.roster[sender]
  if existing and existing.rev >= payload.rev then
    return false, "stale_rev"
  end

  if not existing and not self:MakeRosterRoom() then
    return false, "roster_full"
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
      self:NotePeer(sender, { incompatible = true })
    end
    return false, reason
  end

  if not self.inbox:MarkSeen(sender .. "\n" .. message.id) then
    return false, "duplicate"
  end
  self:NotePeer(sender, message.t == "HELLO" and { version = message.p.version } or {})

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
  if ns.ReadinessRulesSync.IsRulesMessage(message.t) then
    return self:HandleReadinessRules(sender, message)
  end
  if ns.RankMapSync.IsRankMapMessage(message.t) then
    return self:HandleRankMap(sender, message)
  end
  if ns.BlacklistSync.IsBlacklistMessage(message.t) then
    return self:HandleBlacklist(sender, message)
  end
  if ns.GuildKosSync.IsGuildKosMessage(message.t) then
    return self:HandleGuildKos(sender, message)
  end
  if ns.LayerSync.IsLayerMessage(message.t) then
    return self:HandleLayer(sender, message)
  end
  if ns.LfgSync.IsLfgMessage(message.t) then
    return self:HandleLfg(sender, message)
  end
  if ns.RosterSync.IsRosterMessage(message.t) then
    return self:HandleRoster(sender, message)
  end
  if ns.PvPSeasonSync.IsSeasonMessage(message.t) then
    return self:HandlePvPSeason(sender, message)
  end
  if ns.RecipeSync.IsRecipeMessage(message.t) then
    return self:HandleRecipes(sender, message)
  end
  -- SYNC_DATA is only ever accepted as a whisper.
  return false, "wrong_channel"
end

-- Whether this client is one of the first SYNC_SERVE_LEADERS online leaders (by name) that should answer `requester`.
-- The candidates are this client plus the peers that sent a compatible HELLO, are leaders and online according to
-- the local guild roster, and were heard from within PEERS_TTL_SECONDS. A peer that cannot be confirmed online or as
-- a leader is not counted, so doubt only ever adds answers. Without the data (no online lookup, no own name) it
-- answers, as old versions do.
function Comm:IsElectedToServe(requester)
  local constants = ns.Constants
  local ownName = self.platform.GetIdentityKey()
  if not self.isOnline or type(ownName) ~= "string" or ownName == "" then
    return true
  end
  local now = self.now()
  local candidates = { ownName }
  for name, peer in pairs(self.peers) do
    if
      name ~= ownName
      and name ~= requester
      and not peer.incompatible
      and now - peer.seenAt < constants.PEERS_TTL_SECONDS
      and self.isOnline(name) == true
      and ns.PermissionService.Can(self.roleOf(name), "raid_manage")
    then
      candidates[#candidates + 1] = name
    end
  end
  table.sort(candidates)
  for i = 1, math.min(constants.SYNC_SERVE_LEADERS, #candidates) do
    if candidates[i] == ownName then
      return true
    end
  end
  return false
end

-- Remembers that `sender` was left to the elected leaders, so that asking again gets an answer from everyone.
function Comm:DeferRequester(sender, now)
  local constants = ns.Constants
  if not self.deferred[sender] then
    if self.deferredCount >= constants.SYNC_SERVED_MAX_ENTRIES then
      for name, at in pairs(self.deferred) do
        if now - at >= constants.SYNC_ELECTION_ESCALATE_SECONDS then
          self.deferred[name] = nil
          self.deferredCount = self.deferredCount - 1
        end
      end
      if self.deferredCount >= constants.SYNC_SERVED_MAX_ENTRIES then
        return
      end
    end
    self.deferredCount = self.deferredCount + 1
  end
  self.deferred[sender] = now
end

-- Snapshot request from a late joiner. Only a leader (by guild rank) answers, because
-- only a leader's data will be accepted by the requester; each requester is served at most once per
-- cooldown, after a random delay so several leaders do not all answer at the same instant.
function Comm:HandleSyncRequest(sender)
  local constants = ns.Constants
  if not ns.PermissionService.Can(self.ownRole(), "raid_manage") then
    return false, "not_leader"
  end
  -- A sender the guild roster does not know is not served (and does not take a slot of the served table).
  if self.roleOf(sender) == nil then
    return false, "unknown_sender"
  end

  local now = self.now()
  local last = self.served[sender]
  if last and now - last < constants.SYNC_SERVE_COOLDOWN_SECONDS then
    return false, "cooldown"
  end
  -- Not elected: stay silent, unless this requester already asked and went unanswered (it asks again after a while).
  local deferredAt = self.deferred[sender]
  if deferredAt and now - deferredAt < constants.SYNC_ELECTION_ESCALATE_SECONDS then
    self.deferred[sender] = nil
    self.deferredCount = self.deferredCount - 1
  elseif not self:IsElectedToServe(sender) then
    self:DeferRequester(sender, now)
    return false, "not_elected"
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
    -- The PvP, blacklist and Kill On Sight parts shrink along with the events, so a snapshot that is too big gets
    -- smaller as a whole.
    local pvpMax = math.floor(constants.PVP_SNAPSHOT_MAX * count / constants.SYNC_MAX_EVENTS)
    local blacklistMax = math.floor(constants.BLACKLIST_SNAPSHOT_MAX * count / constants.SYNC_MAX_EVENTS)
    local guildKosMax = math.floor(constants.INTEL_KOS_SNAPSHOT_MAX * count / constants.SYNC_MAX_EVENTS)
    local items = ns.Transfer.BuildSnapshot(
      self.events,
      self.tombstones,
      count,
      self:PvPContext(),
      pvpMax,
      self.blacklist,
      blacklistMax,
      -- Only a gm or cogm snapshot carries the rules of the rosters: a receiver applies them under the role of the
      -- sender, and an rl sets the rules of its own roster only.
      ns.PermissionService.CanAll(self.ownRole and self.ownRole(), "rules_edit") and self.readinessRules or nil,
      -- The same goes for the rosters and the assignments of members; an rl only carries those of its own roster.
      self:SnapshotRosterContext(),
      math.floor(constants.MEMBER_SNAPSHOT_MAX * count / constants.SYNC_MAX_EVENTS),
      math.floor(constants.ROSTERS_MAX * count / constants.SYNC_MAX_EVENTS),
      self.guildKos,
      guildKosMax,
      -- The rank map goes along only from somebody who may author it: a receiver applies it under the rank of the
      -- sender of the snapshot.
      self:AuthoredRankMap()
    )
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

-- Remembers a failure for `/nrage debug` (the last one, and how many there were).
function Comm:RecordError(kind, detail)
  self.lastError = { kind = kind, detail = tostring(detail):sub(1, 200), at = self.now() }
  self.errorCount = self.errorCount + 1
end

-- A reply (a whisper) from somebody the guild roster does not know arrived: usually the roster was not loaded yet when
-- the request went out. The requests are repeated after their cooldown, at most SYNC_RETRY_MAX times in all (and each
-- request keeps its own cooldown), so this never turns into a storm.
function Comm:NoteUnknownReply()
  local constants = ns.Constants
  if not (self.lastSyncRequestAt or self.lastLedgerRequestAt) or self.retryCount >= constants.SYNC_RETRY_MAX then
    return
  end
  self.droppedUnknown = true
  if self.retryPending then
    return
  end
  self.retryPending = true
  self.schedule(constants.SYNC_RETRY_DELAY_SECONDS, function()
    self.retryPending = false
    self:RetryRequests()
  end)
end

function Comm:RetryRequests()
  self.droppedUnknown = false
  self.retryCount = self.retryCount + 1
  -- The snapshot is only asked for again while none arrived; the ledger is cheap to ask for (a relay whose ledger is
  -- the same does not answer).
  if not self.lastSnapshot then
    self:RequestSync()
  end
  self:RequestLedger()
end

-- The guild roster became ready: when a reply was dropped because it was not, ask again now (the cooldowns still
-- apply).
function Comm:OnGuildRosterReady()
  if self.droppedUnknown and self.retryCount < ns.Constants.SYNC_RETRY_MAX then
    self:RetryRequests()
  end
end

-- A whisper can only carry a snapshot (SYNC_DATA) or one page of a PvP ledger catch-up (PVP_LEDGER_DATA), and only a
-- leader's snapshot or catch-up is worth decoding. Both are checked from the local guild roster before any
-- decompression happens, and so is the rate limit: a catch-up is many small pages, so while a ledger request of this
-- client is outstanding the whispers have the loose limit of the ledger inbox; otherwise they have the strict limit of
-- a snapshot, which is expensive to decode. A catch-up page when none was asked for is dropped.
function Comm:HandleWhisper(text, sender)
  local constants = ns.Constants
  local role = self.roleOf(sender)
  if role == nil then
    self:NoteUnknownReply()
    return false, "unknown_sender"
  end
  if not ns.PermissionService.Can(role, "raid_manage") then
    return false, "forbidden"
  end
  local now = self.now()
  local expectingLedger = self.ledgerExpectedUntil ~= nil and now <= self.ledgerExpectedUntil
  local limiter = expectingLedger and self.ledgerInbox or self.snapshotInbox
  if not limiter:AllowRate(sender, now) then
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
  if message.t == "PVP_LEDGER_DATA" then
    if not expectingLedger then
      return false, "unsolicited"
    end
    if not self.inbox:MarkSeen(sender .. "\n" .. message.id) then
      return false, "duplicate"
    end
    return self:HandleLedgerData(sender, message.p, role)
  end
  if message.t ~= "SYNC_DATA" then
    return false, "wrong_channel"
  end
  -- Each snapshot costs a lot to decode: while the loose ledger limit applied above, the strict one still counts.
  if expectingLedger and not self.snapshotInbox:AllowRate(sender, now) then
    return false, "rate_limited"
  end
  if not self.inbox:MarkSeen(sender .. "\n" .. message.id) then
    return false, "duplicate"
  end

  local ctx = self:PvPContext()
  ctx.events, ctx.tombstones = self.events, self.tombstones
  ctx.blacklist = self.blacklist
  ctx.guildKos = self.guildKos
  ctx.readinessRules = self.readinessRules
  ctx.rosters, ctx.members = self.rosters, self.members
  ctx.roleOf = self.roleOf
  ctx.rankMaps, ctx.rankGuildKey = self.rankMaps, self.guildKey and self.guildKey() or false
  ctx.entryOf = function(name)
    return self:EntryOf(name)
  end
  local summary = ns.Transfer.ApplyItems(message.p.items, ctx, sender, role)
  self.lastSnapshot = { from = sender, applied = summary.applied, total = summary.total, at = self.now() }
  if summary.firstError then
    self:RecordError("snapshot", summary.firstError)
  end
  if summary.pvp > 0 and self.onPvPChange then
    self.onPvPChange("SYNC_DATA")
  end
  if summary.blacklist > 0 and self.onBlacklistChange then
    self.onBlacklistChange("SYNC_DATA")
  end
  if summary.guildKos > 0 and self.onGuildKosChange then
    self.onGuildKosChange("SYNC_DATA")
  end
  if summary.rules > 0 and self.onRulesChange then
    self.onRulesChange("SYNC_DATA")
  end
  if (summary.rankMap or 0) > 0 and self.onRanksChange then
    self.onRanksChange("SYNC_DATA")
  end
  if summary.rosters > 0 and self.onRosterChange then
    self.onRosterChange("SYNC_DATA")
  end
  return true
end

-- Raid operations: the sender's role is read from the local guild roster, never from the message.
function Comm:HandleRaid(sender, message)
  local ctx = {
    events = self.events,
    tombstones = self.tombstones,
    now = self.platform.ServerTime,
    -- The roster of the sender is read from what this client holds, never from the message.
    members = self.members,
    rosters = self.rosters,
  }
  local ok, reason = ns.EventSync.Apply(ctx, message, sender, self.roleOf(sender))
  if ok and self.onLootChange and message.t:sub(1, 5) == "LOOT_" then
    self.onLootChange(message.t)
  elseif ok and self.onEventChange then
    self.onEventChange(message.t)
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

-- BLACKLIST_UPSERT and BLACKLIST_DELETE: the sender's role is read from the local guild roster, and the author is
-- the sender, never a payload field.
function Comm:HandleBlacklist(sender, message)
  local ctx = { blacklist = self.blacklist, tombstones = self.tombstones, now = self.platform.ServerTime }
  local ok, reason = ns.BlacklistSync.Apply(ctx, message, sender, self.roleOf(sender))
  if ok and self.onBlacklistChange then
    self.onBlacklistChange(message.t)
  end
  return ok, reason
end

-- KOS_UPSERT and KOS_DELETE: the sender's role is read from the local guild roster, and the author is the sender, never
-- a payload field.
function Comm:HandleGuildKos(sender, message)
  local ctx = { guildKos = self.guildKos, tombstones = self.tombstones, now = self.platform.ServerTime }
  local ok, reason = ns.GuildKosSync.Apply(ctx, message, sender, self.roleOf(sender))
  if ok and self.onGuildKosChange then
    self.onGuildKosChange(message.t)
  end
  return ok, reason
end

-- RECIPES: the record belongs to the sender (any guild member), read from the local guild roster; a list is stored
-- when its
-- last part arrives.
function Comm:HandleRecipes(sender, message)
  local ctx = {
    recipes = self.recipes,
    staging = self.recipeStaging,
    now = self.platform.ServerTime,
    onStored = function()
      if self.onRecipesChange then
        self.onRecipesChange(message.t)
      end
    end,
  }
  return ns.RecipeSync.Apply(ctx, message, sender, self.roleOf(sender))
end

-- Publishes the list of one profession of the own character, in the messages it needs. Each message is keyed by
-- profession
-- and part, so a newer list replaces one still waiting in the queue. Returns true, or false plus the first failure.
function Comm:SendRecipes(professionId, record)
  local first
  for _, chunk in ipairs(ns.RecipeService.Chunks(professionId, record, self.platform.ServerTime())) do
    local ok, reason = self:Send("RECIPES", chunk, ("RC:%d:%d"):format(professionId, chunk.part))
    if not ok and not first then
      first = reason
    end
  end
  if first then
    return false, first
  end
  return true
end

-- The tables the roster rules work with.
function Comm:RosterContext()
  return {
    rosters = self.rosters,
    members = self.members,
    tombstones = self.tombstones,
    now = self.platform.ServerTime,
  }
end

-- What a snapshot carries of the rosters: everything from a gm or cogm, the assignments to the own roster from an rl,
-- nothing from anybody else (the receiver would refuse them).
function Comm:SnapshotRosterContext()
  local role = self.ownRole and self.ownRole()
  if ns.PermissionService.CanAll(role, "members_manage") then
    return self:RosterContext()
  end
  if not ns.PermissionService.Can(role, "members_manage") then
    return nil
  end
  local ownRosterId = ns.RosterService.RosterOf(self.members, self.rosters, self.platform.GetIdentityKey())
  if not ownRosterId then
    return nil
  end
  local context = self:RosterContext()
  context.onlyRoster = ownRosterId
  return context
end

-- ROSTER_* and MEMBER_*: the sender's role is read from the local guild roster; only the guild master's are kept.
function Comm:HandleRoster(sender, message)
  local ok, reason = ns.RosterSync.Apply(self:RosterContext(), message, sender, self.roleOf(sender))
  if ok and message.t == "ROSTER_DELETE" then
    ns.ReadinessRulesSync.Forget(self.readinessRules, message.p.rosterId)
  end
  if ok and self.onRosterChange then
    self.onRosterChange(message.t)
  end
  return ok, reason
end

-- Does this client approve PvP claims (gm or cogm)? Claims are only kept by those that do.
function Comm:IsPvPApprover()
  return ns.PermissionService.Can(self.ownRole and self.ownRole(), "pvp_claim_decide")
end

-- The tables and callbacks the PvP season rules work with.
function Comm:PvPSeasonContext()
  return {
    ledger = self.pvpSeason,
    now = self.platform.ServerTime,
    roleOf = self.roleOf,
    isApprover = function()
      return self:IsPvPApprover()
    end,
    onSeasonClosed = self.onPvPSeasonClosed,
  }
end

-- PVP_SEASON, PVP_MISSION, PVP_PRIZES, PVP_OFFICER, PVP_CLAIM, PVP_REJECT, PVP_GRANT, PVP_VOID, PVP_DELIVERY, PVP_FINAL
-- and PVP_LEDGER_REQ. The author is the sender, read from the local guild roster (and, for an officer, from the officer
-- records), never a payload field.
function Comm:HandlePvPSeason(sender, message)
  if message.t == "PVP_LEDGER_REQ" then
    return self:HandleLedgerRequest(sender, message.p)
  end
  local activeBefore = self.pvpSeason.activeId
  local ok, reason = ns.PvPSeasonSync.Apply(self:PvPSeasonContext(), message, sender)
  if ok then
    if self.onPvPSeasonChange then
      self.onPvPSeasonChange(message.t)
    end
    -- A season that just became active: what the others hold of it (missions, grants) is worth asking for now.
    if self.pvpSeason.activeId and self.pvpSeason.activeId ~= activeBefore then
      self:RequestLedger()
    end
  end
  return ok, reason
end

-- Asks the guild for the ledger of the active season (or just the officers, seasons and finals when this client knows
-- no season yet); trusted relays whose own ledger differs answer by whisper. At most once per cooldown.
function Comm:RequestLedger()
  local now = self.now()
  local cooldown = ns.Constants.PVP_LEDGER_REQUEST_COOLDOWN_SECONDS
  if self.lastLedgerRequestAt and now - self.lastLedgerRequestAt < cooldown then
    return false, "cooldown"
  end
  self.lastLedgerRequestAt = now
  -- The catch-up that answers this request is expected for a while, and only then.
  self.ledgerExpectedUntil = now + ns.Constants.PVP_LEDGER_EXPECT_SECONDS
  return self:Send("PVP_LEDGER_REQ", ns.PvPSeasonSync.RequestPayload(self.pvpSeason, self.pvpSeason.activeId), "PLR")
end

-- Can this client answer a ledger request? Only a gm or cogm: every record of a catch-up is an admin record, and a
-- requester only believes the author an item names when the relay is a gm or cogm (see PvPSeasonSync.ApplyItems), so
-- the answer of an officer or rl would be thrown away.
function Comm:IsLedgerRelay()
  return ns.PermissionService.IsGlobal(self.ownRole and self.ownRole())
end

-- A ledger request from a late joiner: answered after a random delay, at most once a minute per requester, and only
-- when the ledger here differs from the one the request describes.
function Comm:HandleLedgerRequest(sender, request)
  local constants = ns.Constants
  if not self:IsLedgerRelay() then
    return false, "not_relay"
  end
  if self.roleOf(sender) == nil then
    return false, "unknown_sender"
  end
  if not ns.PvPSeasonSync.Differs(self.pvpSeason, request) then
    return false, "in_sync"
  end

  local now = self.now()
  local last = self.ledgerServed[sender]
  if last and now - last < constants.PVP_LEDGER_SERVE_COOLDOWN_SECONDS then
    return false, "cooldown"
  end
  if not last then
    if self.ledgerServedCount >= constants.SYNC_SERVED_MAX_ENTRIES then
      for name, servedAt in pairs(self.ledgerServed) do
        if now - servedAt >= constants.PVP_LEDGER_SERVE_COOLDOWN_SECONDS then
          self.ledgerServed[name] = nil
          self.ledgerServedCount = self.ledgerServedCount - 1
        end
      end
      if self.ledgerServedCount >= constants.SYNC_SERVED_MAX_ENTRIES then
        return false, "busy"
      end
    end
    self.ledgerServedCount = self.ledgerServedCount + 1
  end
  self.ledgerServed[sender] = now

  local delay = self.random(constants.SYNC_RESPONSE_DELAY_MIN, constants.SYNC_RESPONSE_DELAY_MAX)
  self.schedule(delay, function()
    self:SendLedger(sender, request)
  end)
  return true
end

-- Does a message of this type with this payload encode under the guild message limit? Used to cut what does not fit.
function Comm:Fits(messageType, payload)
  local message = ns.Protocol.Build(messageType, payload, "ffffffff-ffff-ffffff")
  return self.codec:Encode(message) ~= nil
end

-- Queues pages `from`..`count` of a catch-up for `target`, leaving QUEUE_RESERVED_ITEMS places of the queue free for
-- other traffic. What does not fit is tried again every QUEUE_PACE_SECONDS, at most QUEUE_PACE_RETRIES times; the pages
-- that never went out are recorded for `/nrage debug`. Returns the number of the first page that was not queued
-- (count + 1 when all were), and the first failure reason.
function Comm:SendLedgerPages(target, seasonId, pages, from, attempt)
  local constants = ns.Constants
  local count = #pages
  local number, first = from, nil
  while number <= count do
    if self.queue:Free() <= constants.QUEUE_RESERVED_ITEMS then
      break
    end
    local ok, reason = self:Send(
      "PVP_LEDGER_DATA",
      { seasonId = seasonId, page = number, pages = count, items = pages[number] },
      ("PL:%s:%d"):format(target, number),
      { target = target, maxBytes = constants.SYNC_MAX_ENCODED_BYTES }
    )
    if not ok and not first then
      first = reason
    end
    number = number + 1
  end
  if first then
    self:RecordError("ledger_page", first)
  end
  if number <= count then
    if attempt >= constants.QUEUE_PACE_RETRIES then
      self:RecordError(
        "ledger_pages",
        ("%d of %d page(s) not sent to %s: the queue was full"):format(count - number + 1, count, target)
      )
    else
      self.schedule(constants.QUEUE_PACE_SECONDS, function()
        self:SendLedgerPages(target, seasonId, pages, number, attempt + 1)
      end)
    end
  end
  return number, first
end

-- Whispers `target` the ledger the request is about, in pages that each fit the snapshot limit. The pages are paced:
-- when the queue has no room for all of them the rest follows later (see SendLedgerPages). Returns true plus the number
-- of pages (and "paced" when some wait), or false plus the first failure ("empty" when there is nothing to send).
function Comm:SendLedger(target, request)
  local constants = ns.Constants
  local sync = ns.PvPSeasonSync
  local items = sync.LedgerItems(self.pvpSeason, sync.ScopeFor(self.pvpSeason, request))
  if #items == 0 then
    return false, "empty"
  end
  local function fits(page)
    local payload = { seasonId = request.seasonId, page = 1, pages = constants.PVP_LEDGER_PAGES_MAX, items = page }
    local message = ns.Protocol.Build("PVP_LEDGER_DATA", payload, "ffffffff-ffff-ffffff")
    return self.codec:Encode(message, constants.SYNC_MAX_ENCODED_BYTES) ~= nil
  end
  local pages = sync.Paginate(items, fits, constants.PVP_LEDGER_PAGE_ITEMS)
  local count = math.min(#pages, constants.PVP_LEDGER_PAGES_MAX)
  for number = #pages, count + 1, -1 do
    pages[number] = nil
  end
  local nextPage, first = self:SendLedgerPages(target, request.seasonId, pages, 1, 0)
  if first then
    return false, first
  end
  return true, count, nextPage <= count and "paced" or nil
end

-- One page of a catch-up, already checked to come from a leader and to have been asked for: each item is applied as if
-- its author had sent it, through the same validation, authority and conflict rules, but an author other than the
-- relay itself is only believed when the relay is a gm or cogm.
function Comm:HandleLedgerData(sender, payload, role)
  local relay = { sender = sender, global = ns.PermissionService.IsGlobal(role) }
  local summary = ns.PvPSeasonSync.ApplyItems(self:PvPSeasonContext(), payload.items, relay)
  self.lastLedger =
    { from = sender, applied = summary.applied, total = summary.total, forged = summary.forged, at = self.now() }
  if summary.applied > 0 and self.onPvPSeasonChange then
    self.onPvPSeasonChange("PVP_LEDGER_DATA")
  end
  return true
end

-- The tables the readiness rules of the rosters work with.
function Comm:RulesContext()
  return {
    records = self.readinessRules,
    rosters = self.rosters,
    members = self.members,
    tombstones = self.tombstones,
    now = self.platform.ServerTime,
  }
end

-- ROSTER_RULES: the sender's role is read from the local guild roster and its roster from the local assignments; the
-- set of a roster is kept when a gm or cogm sent it, or the rl of that roster.
function Comm:HandleReadinessRules(sender, message)
  local ctx = self:RulesContext()
  local ok, reason = ns.ReadinessRulesSync.Apply(ctx, message, sender, self.roleOf(sender))
  if ok and self.onRulesChange then
    self.onRulesChange(message.t)
  end
  return ok, reason
end

-- The tables the rank map works with. The roster entry of a name is read from the local guild roster (the own
-- character from the client, since it is not in its own messages), never from a message.
function Comm:RankMapContext()
  return {
    maps = self.rankMaps,
    guildKey = self.guildKey and self.guildKey() or nil,
    now = self.platform.ServerTime,
    entryOf = function(name)
      return self:EntryOf(name)
    end,
  }
end

-- { rankName, rankIndex } of `name`: the own character reads the client (rank index 0 for the guild master, also when
-- only IsGuildLeader says so); anybody else the guild roster.
function Comm:EntryOf(name)
  if self.platform.GetOwnGuildRank and name == self.platform.GetIdentityKey() then
    local rankName, rankIndex = self.platform.GetOwnGuildRank()
    if type(rankName) ~= "string" or rankName == "" then
      return nil
    end
    if self.platform.IsGuildLeader and self.platform.IsGuildLeader() == true then
      rankIndex = ns.Constants.GUILD_MASTER_RANK_INDEX
    end
    return { rankName = rankName, rankIndex = rankIndex }
  end
  return self.entryOf and self.entryOf(name) or nil
end

-- RANK_MAP: the sender is authorized by the roster and the map this client holds, before the incoming map is applied
-- (RankMapSync); the author is the sender, never a payload field.
function Comm:HandleRankMap(sender, message)
  local ok, reason = ns.RankMapSync.Apply(self:RankMapContext(), message, sender)
  if ok and self.onRanksChange then
    self.onRanksChange(message.t)
  end
  return ok, reason
end

-- LAYER_STATE and LAYER_SWAP: live only, nothing is saved. The sender's role is read from the local guild roster and
-- the actor is always the sender, never a payload field.
function Comm:HandleLayer(sender, message)
  local ctx = { directory = self.layerDirectory, swap = self.layerSwap }
  local ok, reason = ns.LayerSync.Apply(ctx, message, sender, self.roleOf(sender))
  if ok and self.onLayerChange then
    self.onLayerChange(message.t)
  end
  return ok, reason
end

-- LFG_POST and LFG_APPLY: live only, nothing is saved. Same rules as the layer messages: the role comes from the local
-- roster and the actor is always the sender.
function Comm:HandleLfg(sender, message)
  local ok, reason = ns.LfgSync.Apply({ service = self.lfgService }, message, sender, self.roleOf(sender))
  if ok and self.onLfgChange then
    self.onLfgChange(message.t)
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

function Comm:SendSignup(eventId, characterKey, record)
  local payload = ns.EventSync.SignupPayload(eventId, characterKey, record)
  return self:Send("SIGNUP_UPSERT", payload, ("SU:%s:%s"):format(eventId, characterKey))
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

-- The own layer (or `layer = 0`, "forget me"). Live only, like a kill: refused during the lockdown instead of waiting,
-- because the next republication carries the latest layer anyway. Keyed, so it never piles up.
function Comm:SendLayerState(payload)
  if not self.queue.guard:CanSend() then
    return false, "locked"
  end
  return self:Send("LAYER_STATE", payload, "LY")
end

-- One step of a layer swap. Never queued: a step that is old by the time the encounter ends is not news.
function Comm:SendLayerSwap(payload)
  if not self.queue.guard:CanSend() then
    return false, "locked"
  end
  return self:Send("LAYER_SWAP", payload)
end

-- The own Groups post (open, changed or closed) and a step of an application. Live only, like the layer swap: refused
-- during the lockdown instead of queued, because the next republication carries the current post.
function Comm:SendLfgPost(payload)
  if not self.queue.guard:CanSend() then
    return false, "locked"
  end
  return self:Send("LFG_POST", payload)
end

function Comm:SendLfgApply(payload)
  if not self.queue.guard:CanSend() then
    return false, "locked"
  end
  return self:Send("LFG_APPLY", payload)
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

-- An entry added or changed here, or the removal of one (its tombstone is already in place). Keyed by player, so
-- a newer edit replaces one still waiting in the queue.
function Comm:SendBlacklistUpsert(key, entry)
  return self:Send("BLACKLIST_UPSERT", ns.BlacklistSync.UpsertPayload(key, entry), "BL:" .. key)
end

function Comm:SendBlacklistDelete(key)
  local payload = ns.BlacklistSync.DeletePayload(self.tombstones, key)
  if not payload then
    return false, "no_tombstone"
  end
  return self:Send("BLACKLIST_DELETE", payload, "BL:" .. key)
end

-- A guild Kill On Sight entry added or changed here, or the removal of one (its tombstone is already in place). Keyed
-- by player, so a newer edit replaces one still waiting in the queue.
function Comm:SendGuildKosUpsert(key, entry)
  return self:Send("KOS_UPSERT", ns.GuildKosSync.UpsertPayload(key, entry), "KOS:" .. key)
end

function Comm:SendGuildKosDelete(key)
  local payload = ns.GuildKosSync.DeletePayload(self.tombstones, key)
  if not payload then
    return false, "no_tombstone"
  end
  return self:Send("KOS_DELETE", payload, "KOS:" .. key)
end

-- Tells the guild the stored set of readiness rules of a roster (one message, replacing one still waiting in the
-- queue).
function Comm:SendReadinessRules(rosterId)
  local payload = ns.ReadinessRulesSync.Payload(rosterId, rosterId and self.readinessRules[rosterId])
  if not payload then
    return false, "no_rules"
  end
  return self:Send("ROSTER_RULES", payload, "RR:" .. rosterId)
end

-- Tells the guild every set the own role may author: all of them for a gm or cogm, the own roster's for an rl. Once
-- after login, for the members who were not there when they were set.
function Comm:SendAuthoredReadinessRules()
  local ownRoster = ns.RosterService.RosterOf(self.members, self.rosters, self.platform.GetIdentityKey())
  for _, payload in ipairs(ns.ReadinessRulesSync.Authored(self.readinessRules, self.ownRole(), ownRoster)) do
    self:Send("ROSTER_RULES", payload, "RR:" .. payload.rosterId)
  end
end

-- Replaces the rules of a roster with `rules`: a gm or cogm for any roster, an rl for its own. They are validated and
-- applied here first (own messages are never received), then told to the guild. Returns true, the revision used and
-- whether it was queued; or false plus the reason ("forbidden", "unknown_roster" or a ReadinessRules.Validate reason).
function Comm:SetReadinessRules(rosterId, rules)
  local role = self.ownRole()
  local ctx = self:RulesContext()
  local sender = self.platform.GetIdentityKey()
  if rosterId == nil or not self.rosters[rosterId] then
    return false, "unknown_roster"
  end
  if ns.ReadinessRulesSync.Authorize(role, ns.RosterService.SenderRoster(ctx, sender), rosterId) then
    return false, "forbidden"
  end
  local clean, reason = ns.ReadinessRules.Validate(rules)
  if not clean then
    return false, reason
  end
  local payload = {
    rosterId = rosterId,
    rev = ((self.readinessRules[rosterId] or {}).rev or 0) + 1,
    updatedAt = self.platform.ServerTime(),
    rules = clean,
  }
  local message = ns.Protocol.Validate(ns.Protocol.Build("ROSTER_RULES", payload, "local"))
  if not message then
    return false, "bad_rules"
  end
  local ok, applied = ns.ReadinessRulesSync.Apply(ctx, message, sender, role)
  if not ok then
    return false, applied
  end
  if self.onRulesChange then
    self.onRulesChange(message.t)
  end
  return true, payload.rev, (self:SendReadinessRules(rosterId))
end

-- Tells the guild the stored rank map (one message, replacing one still waiting in the queue).
function Comm:SendRankMap()
  local key = self.guildKey and self.guildKey() or nil
  local payload = ns.RankMapSync.Payload(key and self.rankMaps[key])
  if not payload then
    return false, "no_rank_map"
  end
  return self:Send("RANK_MAP", payload, "RM")
end

-- The stored map when this client may author it (the guild master, or a co-guild master by the map held), else nil:
-- what a snapshot carries.
function Comm:AuthoredRankMap()
  local key = self.guildKey and self.guildKey() or nil
  local held = key and self.rankMaps[key] or nil
  if held and ns.RankMapSync.MayAuthor(self:EntryOf(self.platform.GetIdentityKey()), held) then
    return held
  end
  return nil
end

-- Once after login, whoever saved the current map tells the guild again, for the members who were not there.
function Comm:SendAuthoredRankMap()
  local held = self:AuthoredRankMap()
  if held and held.by == self.platform.GetIdentityKey() then
    return self:SendRankMap()
  end
  return false, "not_author"
end

-- Replaces the rank map of the guild with `ranks` ({ [index] = { role, name } }): the guild master or a co-guild master.
-- It is validated and applied here first (own messages are never received), then told to the guild. Returns true, the
-- revision used and whether it was queued; or false plus the reason (RankMapSync.Apply: "no_guild", "invalid",
-- "forbidden", "self_row", "stale").
function Comm:SetRankMap(ranks)
  local ctx = self:RankMapContext()
  local sender = self.platform.GetIdentityKey()
  if type(ctx.guildKey) ~= "string" then
    return false, "no_guild"
  end
  local held = ctx.maps[ctx.guildKey]
  local heldRev = type(held) == "table" and type(held.rev) == "number" and held.rev or 0
  local heldAt = type(held) == "table" and type(held.updatedAt) == "number" and held.updatedAt or 0
  local payload = ns.RankMapModel.ToWire({
    ranks = ranks,
    rev = math.min(heldRev + 1, 2147483647),
    -- Later than the held map, so an edit made right after another one always outranks it.
    updatedAt = math.max(ctx.now(), heldAt + 1),
  })
  local message = ns.Protocol.Validate(ns.Protocol.Build("RANK_MAP", payload, "local"))
  if not message then
    return false, "invalid"
  end
  local ok, reason = ns.RankMapSync.Apply(ctx, message, sender)
  if not ok then
    return false, reason
  end
  if self.onRanksChange then
    self.onRanksChange(message.t)
  end
  return true, payload.rev, (self:SendRankMap())
end

-- Local roster changes -> wire. Keyed, so a newer edit replaces one still waiting in the queue.
function Comm:SendRoster(roster)
  return self:Send("ROSTER_UPSERT", ns.RosterSync.RosterPayload(roster), "RO:" .. roster.id)
end

function Comm:SendDeleteRoster(id)
  local payload = ns.RosterSync.DeleteRosterPayload(self.tombstones, id)
  if not payload then
    return false, "no_tombstone"
  end
  ns.ReadinessRulesSync.Forget(self.readinessRules, id)
  return self:Send("ROSTER_DELETE", payload, "RO:" .. id)
end

function Comm:SendMember(key, record)
  return self:Send("MEMBER_UPSERT", ns.RosterSync.MemberPayload(key, record), "MB:" .. key)
end

function Comm:SendDeleteMember(key)
  local payload = ns.RosterSync.DeleteMemberPayload(self.tombstones, key)
  if not payload then
    return false, "no_tombstone"
  end
  return self:Send("MEMBER_DELETE", payload, "MB:" .. key)
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

-- The sync state as data, for the header pill and the Home card: { paused, queued, dropped, lastError, errorCount,
-- snapshot = { from, applied, total, at } or nil, peers (members seen with a compatible addon), incompatible = sorted
-- names }.
function Comm:StatusInfo()
  local compatible, incompatible = 0, {}
  for name, peer in pairs(self.peers) do
    if peer.incompatible then
      incompatible[#incompatible + 1] = name
    else
      compatible = compatible + 1
    end
  end
  table.sort(incompatible)
  return {
    paused = self.queue:IsPaused(),
    queued = self.queue:Pending(),
    -- Messages that never left (expired, refused as full, or whose transmission kept raising).
    dropped = self.queue.dropped or 0,
    -- The last failure worth looking at, { kind, detail, at } or nil, and how many there were.
    lastError = self.lastError,
    errorCount = self.errorCount,
    snapshot = self.lastSnapshot,
    peers = compatible,
    incompatible = incompatible,
  }
end

-- Lines for the sync state on the Home tab.
function Comm:Status()
  local lines = {}
  if self.queue:IsPaused() then
    lines[1] = L("sync paused: encounter in progress")
  else
    lines[1] = L("sync ready")
  end
  lines[#lines + 1] = L("queued messages: %d"):format(self.queue:Pending())
  if self.lastSnapshot then
    local snapshot = self.lastSnapshot
    lines[#lines + 1] =
      L("last snapshot: %d of %d record(s) applied, from %s"):format(snapshot.applied, snapshot.total, snapshot.from)
  end

  local names = {}
  for name in pairs(self.peers) do
    names[#names + 1] = name
  end
  table.sort(names)
  lines[#lines + 1] = L("peers seen: %d"):format(#names)
  for _, name in ipairs(names) do
    local peer = self.peers[name]
    if peer.incompatible then
      lines[#lines + 1] = "  " .. L("%s - incompatible protocol version"):format(name)
    else
      lines[#lines + 1] = "  " .. L("%s - addon %s"):format(name, tostring(peer.version))
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
    -- nil when the roster does not know the member (or is not loaded): the election then does not count them.
    isOnline = function(name)
      local entry = ns.guildRoster and ns.guildRoster:Lookup(name)
      return entry and entry.online
    end,
    onLootChange = function()
      if ns.UI and ns.UI.LootChanged then
        ns.UI.LootChanged()
      end
    end,
    onEventChange = function()
      if ns.UI and ns.UI.EventsChanged then
        ns.UI.EventsChanged()
      end
    end,
    pvpStats = ns.db.global.pvpStats,
    pvpResets = ns.db.global.pvpResets,
    onPvPChange = function()
      if ns.UI and ns.UI.PvPChanged then
        ns.UI.PvPChanged()
      end
    end,
    blacklist = ns.db.global.blacklist,
    -- An entry that arrives may be about someone already in the group: Init redraws the tab and looks again.
    onBlacklistChange = function()
      if ns.BlacklistChanged then
        ns.BlacklistChanged()
      end
    end,
    guildKos = ns.db.global.guildKos,
    -- An entry that arrives may be about someone nearby now: Init redraws the Intel views.
    onGuildKosChange = function()
      if ns.GuildKosChanged then
        ns.GuildKosChanged()
      end
    end,
    readinessRules = ns.db.global.readinessRulesByRoster,
    onRulesChange = function()
      if ns.UI and ns.UI.RulesChanged then
        ns.UI.RulesChanged()
      end
    end,
    rankMaps = ns.db.global.rankMaps,
    guildKey = function()
      return ns.rankMapService and ns.rankMapService.guildKey() or nil
    end,
    entryOf = function(name)
      return ns.guildRoster and ns.guildRoster:Lookup(name) or nil
    end,
    -- A map that arrives changes roles: Init works out the own role again and the windows redraw.
    onRanksChange = function()
      if ns.RanksChanged then
        ns.RanksChanged()
      end
    end,
    recipes = ns.db.global.recipes,
    onRecipesChange = function()
      if ns.UI and ns.UI.RecipesChanged then
        ns.UI.RecipesChanged()
      end
    end,
    pvpSeason = ns.db.global.pvpSeason,
    onPvPSeasonChange = function(messageType)
      if ns.PvPSeasonChanged then
        ns.PvPSeasonChanged(messageType)
      end
    end,
    onPvPSeasonClosed = function(seasonId)
      if ns.PvPSeasonClosed then
        ns.PvPSeasonClosed(seasonId)
      end
    end,
    rosters = ns.db.global.rosters,
    members = ns.db.global.members,
    onRosterChange = function()
      if ns.UI and ns.UI.RostersChanged then
        ns.UI.RostersChanged()
      end
    end,
    version = ns.GetVersion(),
    -- Who runs the addon, saved for the Installed check tab.
    onPeerSeen = function(sender, info)
      if ns.InstallDirectory.Note(ns.db.global.installs, sender, info, platform.ServerTime()) and ns.UI then
        if ns.UI.InstallsChanged then
          ns.UI.InstallsChanged()
        end
      end
    end,
    now = platform.Now,
    schedule = C_Timer.After,
    random = math.random,
  })

  local receiver = {}
  AceComm:Embed(receiver)
  receiver:RegisterComm(constants.ADDON_PREFIX, function(_, message, distribution, sender)
    -- During an encounter arguments can be secret values: any error means "drop it silently".
    local ok, err = pcall(function()
      if ns.active then
        comm:HandleMessage(message, sender, distribution)
      end
    end)
    if not ok then
      pcall(comm.RecordError, comm, "handler", err)
    end
  end)

  -- Sightings of enemy players travel on their own prefix, outside the envelope (docs/PROTOCOL.md). The receiver is
  -- looked up when a message arrives: Init creates it right after Comm starts.
  platform.RegisterPrefix(constants.INTEL_PREFIX)
  local intelReceiver = {}
  AceComm:Embed(intelReceiver)
  intelReceiver:RegisterComm(constants.INTEL_PREFIX, function(_, message, distribution, sender)
    -- During an encounter the arguments can be secret values: any error means "drop it silently".
    pcall(function()
      if ns.active and ns.intelSync then
        ns.intelSync:Handle(message, distribution, sender)
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
      -- And what the guild holds of the PvP season, in case it moved on while this client was away.
      comm:RequestLedger()
      -- Whoever can set rules tells the guild the sets of their rosters once, for the members who were not there
      -- when they were set.
      comm:SendAuthoredReadinessRules()
      -- And the rank map, if this client saved the one in force.
      comm:SendAuthoredRankMap()
      -- And the roster definitions (the assignments of the members travel in the snapshot an admin answers).
      if ns.PermissionService.CanAll(comm.ownRole(), "members_manage") then
        for _, roster in ipairs(ns.RosterService.List(comm.rosters)) do
          comm:SendRoster(roster)
        end
      end
    end
  end)

  ns.comm = comm
  return comm
end

ns.Comm = Comm
