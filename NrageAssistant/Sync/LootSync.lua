local _, ns = ...

-- Applies received loot council messages and builds the payloads for local changes. Same principles as
-- EventSync (see SyncRules): the sender's role comes from the receiver's own guild roster, the author
-- of every record is the message sender, and conflicts are settled by rev, then time, then sender.
--
--   LOOT_SESSION    open a session, or close it without an award      (loot_open)
--   LOOT_CANDIDATE  put oneself forward; the candidate is the sender  (loot_apply)
--   LOOT_VOTE       vote for a candidate; the voter is the sender     (loot_vote)
--   LOOT_AWARD      award the item and close the session              (loot_award)
--
-- Rosters: the sender needs a roster, and the event has to be of it (or of none yet); the guild master acts on any.
-- A council member votes only on the sessions of their own roster. See RosterService.MayAct.
-- Every function returns true, or false plus:
--   "unknown_sender" | "forbidden" | "other_roster" | "unknown_event" | "unknown_session" | "closed" | "not_candidate"
--   | "stale" | "limit"
local LootSync = {}

local Rules = ns.SyncRules

-- Returns event, session, or nil, nil plus the reason.
local function findSession(ctx, payload)
  local event = ctx.events[payload.eventId]
  if not event then
    return nil, nil, "unknown_event"
  end
  event.loot = event.loot or {}
  local session = event.loot[payload.sessionId]
  if not session then
    return event, nil, "unknown_session"
  end
  return event, session
end

-- nil when `sender` (with `role`) may act on the loot of `event`, else "other_roster".
local function rosterGuard(ctx, sender, role, event)
  local senderRoster = ns.RosterService.SenderRoster(ctx, sender)
  if ns.RosterService.MayAct(role, senderRoster, event.rosterId) then
    return nil
  end
  return "other_roster"
end

local function newSession(event, payload)
  if Rules.CountKeys(event.loot) >= ns.Constants.LOOT_SESSIONS_MAX then
    return nil
  end
  local session = { sessionId = payload.sessionId, candidates = {}, votes = {} }
  event.loot[payload.sessionId] = session
  return session
end

local function stampReceived(record, payload, updatedAt, sender)
  record.rev = payload.rev
  record.updatedAt = updatedAt
  record.updatedBy = sender
  record.source = "received"
end

local function applySession(ctx, payload, sender, role)
  local denied = Rules.Authorize(role, "loot_open")
  if denied then
    return false, denied
  end
  local event = ctx.events[payload.eventId]
  if not event then
    return false, "unknown_event"
  end
  local blocked = rosterGuard(ctx, sender, role, event)
  if blocked then
    return false, blocked
  end
  event.loot = event.loot or {}

  local updatedAt = Rules.ClampTimestamp(ctx, payload.updatedAt)
  local session = event.loot[payload.sessionId]
  if session then
    if not Rules.Wins(payload.rev, updatedAt, sender, session) then
      return false, "stale"
    end
  else
    session = newSession(event, payload)
    if not session then
      return false, "limit"
    end
  end

  session.itemId, session.itemName, session.status = payload.itemId, payload.itemName, payload.status
  -- A winning session record is the whole truth about the session, an award included.
  session.award = nil
  stampReceived(session, payload, updatedAt, sender)
  return true
end

-- Self-contained: it carries the item, so a client that never saw the session can still record the
-- decision (snapshots and imports rely on this).
local function applyAward(ctx, payload, sender, role)
  local denied = Rules.Authorize(role, "loot_award")
  if denied then
    return false, denied
  end
  local event = ctx.events[payload.eventId]
  if not event then
    return false, "unknown_event"
  end
  local blocked = rosterGuard(ctx, sender, role, event)
  if blocked then
    return false, blocked
  end
  event.loot = event.loot or {}

  local updatedAt = Rules.ClampTimestamp(ctx, payload.updatedAt)
  local session = event.loot[payload.sessionId]
  if session then
    if not Rules.Wins(payload.rev, updatedAt, sender, session) then
      return false, "stale"
    end
  else
    session = newSession(event, payload)
    if not session then
      return false, "limit"
    end
  end

  session.itemId, session.itemName = payload.itemId, payload.itemName
  session.status = "closed"
  session.award = { characterKey = payload.characterKey, reason = payload.reason, awardedBy = sender, at = updatedAt }
  stampReceived(session, payload, updatedAt, sender)
  return true
end

local function applyCandidate(ctx, payload, sender, role)
  local denied = Rules.Authorize(role, "loot_apply")
  if denied then
    return false, denied
  end
  local event, session, reason = findSession(ctx, payload)
  if not session then
    return false, reason
  end
  local blocked = rosterGuard(ctx, sender, role, event)
  if blocked then
    return false, blocked
  end
  if session.status ~= "open" then
    return false, "closed"
  end

  local updatedAt = Rules.ClampTimestamp(ctx, payload.updatedAt)
  local candidate = session.candidates[sender]
  if candidate then
    if not Rules.Wins(payload.rev, updatedAt, sender, candidate) then
      return false, "stale"
    end
  else
    if Rules.CountKeys(session.candidates) >= ns.Constants.LOOT_CANDIDATES_MAX then
      return false, "limit"
    end
    candidate = {}
    session.candidates[sender] = candidate
  end

  candidate.spec, candidate.need, candidate.upgrade = payload.spec, payload.need, payload.upgrade
  stampReceived(candidate, payload, updatedAt, sender)
  return true
end

local function applyVote(ctx, payload, sender, role)
  local denied = Rules.Authorize(role, "loot_vote")
  if denied then
    return false, denied
  end
  local event, session, reason = findSession(ctx, payload)
  if not session then
    return false, reason
  end
  local blocked = rosterGuard(ctx, sender, role, event)
  if blocked then
    return false, blocked
  end
  if session.status ~= "open" then
    return false, "closed"
  end
  if not session.candidates[payload.target] then
    return false, "not_candidate"
  end

  local updatedAt = Rules.ClampTimestamp(ctx, payload.updatedAt)
  local vote = session.votes[sender]
  if vote then
    if not Rules.Wins(payload.rev, updatedAt, sender, vote) then
      return false, "stale"
    end
  else
    if Rules.CountKeys(session.votes) >= ns.Constants.LOOT_VOTES_MAX then
      return false, "limit"
    end
    vote = {}
    session.votes[sender] = vote
  end

  vote.target = payload.target
  stampReceived(vote, payload, updatedAt, sender)
  return true
end

ns.EventSync.RegisterApplier("LOOT_SESSION", applySession)
ns.EventSync.RegisterApplier("LOOT_AWARD", applyAward)
ns.EventSync.RegisterApplier("LOOT_CANDIDATE", applyCandidate)
ns.EventSync.RegisterApplier("LOOT_VOTE", applyVote)

-- Payload builders: what a local change looks like on the wire.

function LootSync.SessionPayload(eventId, session)
  return {
    eventId = eventId,
    sessionId = session.sessionId,
    rev = session.rev,
    updatedAt = session.updatedAt,
    itemId = session.itemId,
    itemName = session.itemName,
    status = session.status,
  }
end

function LootSync.AwardPayload(eventId, session)
  return {
    eventId = eventId,
    sessionId = session.sessionId,
    rev = session.rev,
    updatedAt = session.updatedAt,
    itemId = session.itemId,
    itemName = session.itemName,
    characterKey = session.award.characterKey,
    reason = session.award.reason,
  }
end

function LootSync.CandidatePayload(eventId, sessionId, candidate)
  return {
    eventId = eventId,
    sessionId = sessionId,
    rev = candidate.rev,
    updatedAt = candidate.updatedAt,
    spec = candidate.spec,
    need = candidate.need,
    upgrade = candidate.upgrade,
  }
end

function LootSync.VotePayload(eventId, sessionId, vote)
  return {
    eventId = eventId,
    sessionId = sessionId,
    rev = vote.rev,
    updatedAt = vote.updatedAt,
    target = vote.target,
  }
end

-- The messages that describe an event's sessions as a leader could author them: an award for a
-- session that has one, a session record for the others. Candidates and votes are not included,
-- because on the wire a candidate or a voter is always the sender and cannot be re-attributed.
function LootSync.SessionItems(eventId, event)
  local ids = {}
  for sessionId in pairs(event.loot or {}) do
    ids[#ids + 1] = sessionId
  end
  table.sort(ids)

  local items = {}
  for _, sessionId in ipairs(ids) do
    local session = event.loot[sessionId]
    if session.status == "closed" and session.award then
      items[#items + 1] = { t = "LOOT_AWARD", p = LootSync.AwardPayload(eventId, session) }
    else
      items[#items + 1] = { t = "LOOT_SESSION", p = LootSync.SessionPayload(eventId, session) }
    end
  end
  return items
end

ns.LootSync = LootSync
