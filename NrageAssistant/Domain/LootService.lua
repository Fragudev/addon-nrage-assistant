local _, ns = ...

-- Loot council sessions, kept inside their raid event (event.loot). A session is opened for one item
-- after the encounter, members register as candidates, the council votes, and an award closes it
-- with a reason: that closed record is the minutes (acta).
--
-- ctx = {
--   events = db.global.events,        role = "member" | "rl" | "council" | "admin",
--   actor  = "Name-Realm",            now = function() -> server time,
--   newId  = function() -> unique id, isLockedDown = function() -> boolean (optional),
-- }
-- ctx.rosterId is the roster of the actor: a session is acted on by the members of its event's roster (and the guild
-- master), see RosterService.MayAct. Every operation returns its result, or nil/false plus a reason:
--   "forbidden" | "other_roster" | "not_found" | "closed" | "locked_down" | "limit" | "not_candidate" |
--   "invalid:<field>".
--
-- Addon messages are not confidential, and neither is anything here: anyone running the addon on
-- the guild channel can read votes. The UI says so wherever it shows them.
local LootService = {}

local function Can(role, action)
  return ns.PermissionService.Can(role, action)
end

local function stamp(ctx, record)
  record.rev = (record.rev or 0) + 1
  record.updatedAt = ctx.now()
  record.updatedBy = ctx.actor
end

local function countKeys(tbl)
  local count = 0
  for _ in pairs(tbl) do
    count = count + 1
  end
  return count
end

-- true when the actor may act on the loot of `event`.
local function inRoster(ctx, event)
  return ns.RosterService.MayAct(ctx.role, ctx.rosterId, event.rosterId)
end

-- Returns event, session; or nil, nil plus "not_found" | "closed" | "other_roster".
local function findOpenSession(ctx, eventId, sessionId)
  local event = ctx.events[eventId]
  if not event then
    return nil, nil, "not_found"
  end
  if not inRoster(ctx, event) then
    return nil, nil, "other_roster"
  end
  -- Events created before loot existed have no table yet.
  event.loot = event.loot or {}
  local session = event.loot[sessionId]
  if not session then
    return nil, nil, "not_found"
  end
  if session.status ~= "open" then
    return nil, nil, "closed"
  end
  return event, session
end

-- Opens a session for one item. Only after the encounter: while chat messaging is locked down the
-- session could not be announced, and item links may be unreadable.
function LootService.OpenSession(ctx, eventId, fields)
  if not Can(ctx.role, "loot_open") then
    return nil, "forbidden"
  end
  if ctx.isLockedDown and ctx.isLockedDown() then
    return nil, "locked_down"
  end
  local event = ctx.events[eventId]
  if not event then
    return nil, "not_found"
  end
  if not inRoster(ctx, event) then
    return nil, "other_roster"
  end
  local item, reason = ns.LootModel.ValidateItem(fields)
  if not item then
    return nil, reason
  end

  event.loot = event.loot or {}
  if countKeys(event.loot) >= ns.Constants.LOOT_SESSIONS_MAX then
    return nil, "limit"
  end

  local session = {
    sessionId = ctx.newId(),
    itemId = item.itemId,
    itemName = item.itemName,
    status = "open",
    candidates = {},
    votes = {},
    source = "declared",
  }
  stamp(ctx, session)
  event.loot[session.sessionId] = session
  return session
end

-- The actor puts themselves forward. Everyone can, nobody can register somebody else, and
-- registering again just updates the declaration.
function LootService.Register(ctx, eventId, sessionId, fields)
  if not Can(ctx.role, "loot_apply") then
    return nil, "forbidden"
  end
  local _, session, reason = findOpenSession(ctx, eventId, sessionId)
  if not session then
    return nil, reason
  end
  local clean
  clean, reason = ns.LootModel.ValidateCandidate(fields)
  if not clean then
    return nil, reason
  end

  local candidate = session.candidates[ctx.actor]
  if not candidate and countKeys(session.candidates) >= ns.Constants.LOOT_CANDIDATES_MAX then
    return nil, "limit"
  end

  candidate = candidate or {}
  candidate.spec, candidate.need, candidate.upgrade = clean.spec, clean.need, clean.upgrade
  candidate.source = "declared"
  stamp(ctx, candidate)
  session.candidates[ctx.actor] = candidate
  return candidate
end

-- One vote per council member per session; voting again changes it.
function LootService.Vote(ctx, eventId, sessionId, targetKey)
  if not Can(ctx.role, "loot_vote") then
    return nil, "forbidden"
  end
  local _, session, reason = findOpenSession(ctx, eventId, sessionId)
  if not session then
    return nil, reason
  end
  if not ns.LootModel.IsCharacterKey(targetKey) or not session.candidates[targetKey] then
    return nil, "not_candidate"
  end

  local vote = session.votes[ctx.actor]
  if not vote and countKeys(session.votes) >= ns.Constants.LOOT_VOTES_MAX then
    return nil, "limit"
  end

  vote = vote or {}
  vote.target = targetKey
  vote.source = "declared"
  stamp(ctx, vote)
  session.votes[ctx.actor] = vote
  return vote
end

-- Awards the item to a candidate, with a reason, and closes the session.
function LootService.Award(ctx, eventId, sessionId, targetKey, awardReason)
  if not Can(ctx.role, "loot_award") then
    return nil, "forbidden"
  end
  local _, session, reason = findOpenSession(ctx, eventId, sessionId)
  if not session then
    return nil, reason
  end
  if not ns.LootModel.IsCharacterKey(targetKey) or not session.candidates[targetKey] then
    return nil, "not_candidate"
  end
  if not ns.LootModel.IsReason(awardReason) then
    return nil, "invalid:reason"
  end

  session.award = { characterKey = targetKey, reason = awardReason, awardedBy = ctx.actor, at = ctx.now() }
  session.status = "closed"
  stamp(ctx, session)
  return session
end

-- Closes a session without awarding anything (the item is disenchanted, kept for later, etc.).
function LootService.Close(ctx, eventId, sessionId)
  if not Can(ctx.role, "loot_award") then
    return nil, "forbidden"
  end
  local _, session, reason = findOpenSession(ctx, eventId, sessionId)
  if not session then
    return nil, reason
  end
  session.status = "closed"
  stamp(ctx, session)
  return session
end

-- Whether votes may be shown as they are now: always once the session is closed, and while it is
-- open only if Constants.VOTE_VISIBILITY is "open". Views must check this before showing counts.
function LootService.VotesVisible(session)
  return session.status == "closed" or ns.Constants.VOTE_VISIBILITY == "open"
end

-- The sessions of an event in a stable order (item name, then id), the order the commands number them.
function LootService.Sessions(event)
  local sessions = {}
  for _, session in pairs(event.loot or {}) do
    sessions[#sessions + 1] = session
  end
  table.sort(sessions, function(a, b)
    if a.itemName ~= b.itemName then
      return a.itemName < b.itemName
    end
    return a.sessionId < b.sessionId
  end)
  return sessions
end

-- Vote counts per candidate, most votes first. `voters` (who voted for whom) is included only when
-- the policy allows: always once the session is closed, and while it is open only if
-- Constants.VOTE_VISIBILITY is "open".
function LootService.Tally(session)
  local reveal = session.status == "closed" or ns.Constants.VOTE_VISIBILITY == "open"
  local byTarget = {}
  for voter, vote in pairs(session.votes) do
    local entry = byTarget[vote.target]
    if not entry then
      entry = { characterKey = vote.target, count = 0, voters = {} }
      byTarget[vote.target] = entry
    end
    entry.count = entry.count + 1
    entry.voters[#entry.voters + 1] = voter
  end

  local list = {}
  for _, entry in pairs(byTarget) do
    table.sort(entry.voters)
    if not reveal then
      entry.voters = nil
    end
    list[#list + 1] = entry
  end
  table.sort(list, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return a.characterKey < b.characterKey
  end)
  return list
end

-- The minutes: every closed session of an event, oldest first, with what was decided and why.
function LootService.Acta(event)
  local sessions = {}
  for _, session in pairs(event.loot or {}) do
    if session.status == "closed" then
      sessions[#sessions + 1] = session
    end
  end
  table.sort(sessions, function(a, b)
    if a.updatedAt ~= b.updatedAt then
      return a.updatedAt < b.updatedAt
    end
    return a.sessionId < b.sessionId
  end)

  local acta = {}
  for _, session in ipairs(sessions) do
    local award = session.award
    acta[#acta + 1] = {
      sessionId = session.sessionId,
      itemId = session.itemId,
      itemName = session.itemName,
      awardedTo = award and award.characterKey or nil,
      reason = award and award.reason or nil,
      awardedBy = award and award.awardedBy or nil,
      votes = LootService.Tally(session),
    }
  end
  return acta
end

ns.LootService = LootService
