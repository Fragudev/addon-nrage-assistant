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
--       (all optional), blacklist (table) and onBlacklistChange(messageType) (optional),
--       layerDirectory, layerSwap and onLayerChange(messageType) (all optional),
--       rosters and members (tables: raid rosters, and the role and roster of each member) and
--       onRosterChange(messageType) (optional), pvpSeason (the season ledger table, see PvPSeasonSync),
--       onPvPSeasonChange(messageType) and onPvPSeasonClosed(seasonId) (optional), ledgerInbox (optional),
--       roleOf(sender) -> role or nil, ownRole() -> role or nil,
--       snapshotInbox (optional), version (string), now() -> seconds, schedule(delaySeconds, fn),
--       random(low, high) -> number
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
    blacklist = deps.blacklist or {},
    onBlacklistChange = deps.onBlacklistChange,
    readinessRules = deps.readinessRules or {},
    onRulesChange = deps.onRulesChange,
    -- The layer directory and swap flow are in memory and created after Comm (Init.StartLayer sets them).
    layerDirectory = deps.layerDirectory,
    layerSwap = deps.layerSwap,
    onLayerChange = deps.onLayerChange,
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
    lastLedger = nil,
    recipeStaging = {},
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
  if ns.ReadinessRulesSync.IsRulesMessage(message.t) then
    return self:HandleReadinessRules(sender, message)
  end
  if ns.BlacklistSync.IsBlacklistMessage(message.t) then
    return self:HandleBlacklist(sender, message)
  end
  if ns.LayerSync.IsLayerMessage(message.t) then
    return self:HandleLayer(sender, message)
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

-- Snapshot request from a late joiner. Only a leader (by guild rank) answers, because
-- only a leader's data will be accepted by the requester; each requester is served at most once per
-- cooldown, after a random delay so several leaders do not all answer at the same instant.
function Comm:HandleSyncRequest(sender)
  local constants = ns.Constants
  if not ns.PermissionService.Can(self.ownRole(), "raid_manage") then
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
    -- The PvP and blacklist parts shrink along with the events, so a snapshot that is too big gets smaller as a
    -- whole.
    local pvpMax = math.floor(constants.PVP_SNAPSHOT_MAX * count / constants.SYNC_MAX_EVENTS)
    local blacklistMax = math.floor(constants.BLACKLIST_SNAPSHOT_MAX * count / constants.SYNC_MAX_EVENTS)
    local items = ns.Transfer.BuildSnapshot(
      self.events,
      self.tombstones,
      count,
      self:PvPContext(),
      pvpMax,
      self.blacklist,
      blacklistMax,
      -- Only a gm or cogm snapshot carries the rules: a receiver applies them under the role of the sender (and, until
      -- the roster scoping of docs/NAV_PERMISSIONS_PLAN.md lands, only those two may set them).
      ns.PermissionService.CanAll(self.ownRole and self.ownRole(), "rules_edit") and self.readinessRules or nil,
      -- The same goes for the rosters and the assignments of members.
      ns.PermissionService.CanAll(self.ownRole and self.ownRole(), "members_manage") and self:RosterContext() or nil,
      math.floor(constants.MEMBER_SNAPSHOT_MAX * count / constants.SYNC_MAX_EVENTS)
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

-- A whisper can only carry a snapshot (SYNC_DATA) or one page of a PvP ledger catch-up (PVP_LEDGER_DATA), and only a
-- leader's snapshot or catch-up is worth decoding. Both are checked from the local guild roster before any
-- decompression happens. Snapshots have a much stricter rate limit than
-- guild traffic because each one is expensive to decode; a catch-up is many small pages, so it has a limit of its own.
function Comm:HandleWhisper(text, sender)
  local constants = ns.Constants
  local role = self.roleOf(sender)
  if role == nil then
    return false, "unknown_sender"
  end
  local leader = ns.PermissionService.Can(role, "raid_manage")
  if not leader then
    return false, "forbidden"
  end
  if not self.ledgerInbox:AllowRate(sender, self.now()) then
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
    if not self.inbox:MarkSeen(sender .. "\n" .. message.id) then
      return false, "duplicate"
    end
    return self:HandleLedgerData(sender, message.p)
  end
  if message.t ~= "SYNC_DATA" then
    return false, "wrong_channel"
  end
  -- Only a leader's snapshot counts, and each costs a lot to decode.
  if not leader then
    return false, "forbidden"
  end
  if not self.snapshotInbox:AllowRate(sender, self.now()) then
    return false, "rate_limited"
  end
  if not self.inbox:MarkSeen(sender .. "\n" .. message.id) then
    return false, "duplicate"
  end

  local ctx = self:PvPContext()
  ctx.events, ctx.tombstones = self.events, self.tombstones
  ctx.blacklist = self.blacklist
  ctx.readinessRules = self.readinessRules
  ctx.rosters, ctx.members = self.rosters, self.members
  local summary = ns.Transfer.ApplyItems(message.p.items, ctx, sender, role)
  self.lastSnapshot = { from = sender, applied = summary.applied, total = summary.total, at = self.now() }
  if summary.pvp > 0 and self.onPvPChange then
    self.onPvPChange("SYNC_DATA")
  end
  if summary.blacklist > 0 and self.onBlacklistChange then
    self.onBlacklistChange("SYNC_DATA")
  end
  if summary.rules > 0 and self.onRulesChange then
    self.onRulesChange("SYNC_DATA")
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

-- ROSTER_* and MEMBER_*: the sender's role is read from the local guild roster; only the guild master's are kept.
function Comm:HandleRoster(sender, message)
  local ok, reason = ns.RosterSync.Apply(self:RosterContext(), message, sender, self.roleOf(sender))
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
  return self:Send("PVP_LEDGER_REQ", ns.PvPSeasonSync.RequestPayload(self.pvpSeason, self.pvpSeason.activeId), "PLR")
end

-- Can this client answer a ledger request? Only a leader (raid_manage): they are the ones a requester accepts a
-- catch-up from.
function Comm:IsLedgerRelay()
  return ns.PermissionService.Can(self.ownRole and self.ownRole(), "raid_manage")
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

-- Whispers `target` the ledger the request is about, in pages that each fit the snapshot limit. Returns true plus the
-- number of pages, or false plus the first failure ("empty" when there is nothing to send).
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
  local first
  for number = 1, count do
    local ok, reason = self:Send(
      "PVP_LEDGER_DATA",
      { seasonId = request.seasonId, page = number, pages = count, items = pages[number] },
      ("PL:%s:%d"):format(target, number),
      { target = target, maxBytes = constants.SYNC_MAX_ENCODED_BYTES }
    )
    if not ok and not first then
      first = reason
    end
  end
  if first then
    return false, first
  end
  return true, count
end

-- One page of a catch-up, already checked to come from a trusted relay: each item is applied as if its author had sent
-- it, through the same validation, authority and conflict rules.
function Comm:HandleLedgerData(sender, payload)
  local summary = ns.PvPSeasonSync.ApplyItems(self:PvPSeasonContext(), payload.items)
  self.lastLedger = { from = sender, applied = summary.applied, total = summary.total, at = self.now() }
  if summary.applied > 0 and self.onPvPSeasonChange then
    self.onPvPSeasonChange("PVP_LEDGER_DATA")
  end
  return true
end

-- READINESS_RULES: the sender's role is read from the local guild roster; only a gm or cogm set is kept.
function Comm:HandleReadinessRules(sender, message)
  local ctx = { record = self.readinessRules, now = self.platform.ServerTime }
  local ok, reason = ns.ReadinessRulesSync.Apply(ctx, message, sender, self.roleOf(sender))
  if ok and self.onRulesChange then
    self.onRulesChange(message.t)
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

-- Tells the guild the stored set of readiness rules (one message, replacing one still waiting in the queue).
function Comm:SendReadinessRules()
  local payload = ns.ReadinessRulesSync.Payload(self.readinessRules)
  if not payload then
    return false, "no_rules"
  end
  return self:Send("READINESS_RULES", payload, "RR")
end

-- Admin only: replaces the guild's rules with `rules`. They are validated and applied here first (own messages are
-- never received), then told to the guild. Returns true, the revision used and whether it was queued; or false plus
-- the reason ("forbidden" or a ReadinessRules.Validate reason).
function Comm:SetReadinessRules(rules)
  local role = self.ownRole()
  if not ns.PermissionService.CanAll(role, "rules_edit") then
    return false, "forbidden"
  end
  local clean, reason = ns.ReadinessRules.Validate(rules)
  if not clean then
    return false, reason
  end
  local payload = {
    rev = (self.readinessRules.rev or 0) + 1,
    updatedAt = self.platform.ServerTime(),
    rules = clean,
  }
  local message = ns.Protocol.Validate(ns.Protocol.Build("READINESS_RULES", payload, "local"))
  if not message then
    return false, "bad_rules"
  end
  local ok, applied = ns.ReadinessRulesSync.Apply(
    { record = self.readinessRules, now = self.platform.ServerTime },
    message,
    self.platform.GetIdentityKey(),
    role
  )
  if not ok then
    return false, applied
  end
  if self.onRulesChange then
    self.onRulesChange(message.t)
  end
  return true, payload.rev, (self:SendReadinessRules())
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

-- The sync state as data, for the header pill and the Home card: { paused, queued, snapshot = { from, applied,
-- total, at } or nil, peers (members seen with a compatible addon), incompatible = sorted names }.
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
    blacklist = ns.db.global.blacklist,
    -- An entry that arrives may be about someone already in the group: Init redraws the tab and looks again.
    onBlacklistChange = function()
      if ns.BlacklistChanged then
        ns.BlacklistChanged()
      end
    end,
    readinessRules = ns.db.global.readinessRules,
    onRulesChange = function()
      if ns.UI and ns.UI.RulesChanged then
        ns.UI.RulesChanged()
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
      -- And what the guild holds of the PvP season, in case it moved on while this client was away.
      comm:RequestLedger()
      -- A gm or cogm also tells the guild the rules once, for the members who were not there when they were set.
      if ns.PermissionService.CanAll(comm.ownRole(), "rules_edit") then
        comm:SendReadinessRules()
      end
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
