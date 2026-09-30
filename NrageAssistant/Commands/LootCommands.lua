local _, ns = ...

-- Text commands for the loot council. Each method takes the words after `/nrage loot` and returns the
-- lines to print, so it is tested without a client. Every change goes through LootService first (which
-- checks the role derived from the guild rank) and is then sent to the guild through Comm.
--   deps: events, platform, comm
--
-- Addon messages are not confidential: the detail view says so wherever it shows votes.
local LootCommands = {}
LootCommands.__index = LootCommands

local USAGE = {
  "usage: /nrage loot <event>                     list the sessions of an event",
  "       /nrage loot <event> open <item link>    open a session (council, after the encounter)",
  "       /nrage loot <event> <n>                 show a session",
  "       /nrage loot <event> <n> apply <spec> <main|off|other> [upgrade]",
  "       /nrage loot <event> <n> vote <name>",
  "       /nrage loot <event> <n> award <name> <reason>",
  "       /nrage loot <event> <n> close           close without awarding",
  "       /nrage loot acta <event>                the minutes: what was decided and why",
}

function LootCommands.New(deps)
  return setmetatable({
    events = deps.events,
    platform = deps.platform,
    comm = deps.comm,
  }, LootCommands)
end

function LootCommands:Context()
  local platform = self.platform
  return {
    events = self.events,
    role = ns.PermissionService.OwnRole(platform),
    actor = platform.GetIdentityKey(),
    now = platform.ServerTime,
    newId = function()
      return self.comm:NextId()
    end,
    isLockedDown = platform.IsChatMessagingLockedDown,
  }
end

local function fail(ctx, reason)
  if reason == "forbidden" then
    return ("not allowed: your guild rank gives the role '%s', which cannot do this."):format(tostring(ctx.role))
  end
  local field = tostring(reason):match("^invalid:(.+)$")
  if field then
    return ("invalid %s."):format(field)
  end
  local messages = {
    not_found = "not found.",
    closed = "that session is already closed.",
    locked_down = "wait until the encounter ends: sessions cannot be opened while chat messaging is locked down.",
    limit = "limit reached.",
    not_candidate = "that character has not put themselves forward as a candidate for this item.",
  }
  return messages[reason] or tostring(reason)
end

-- Adds a note when the change was saved here but could not be queued for the guild.
local function sentNote(ok, reason)
  if ok then
    return nil
  end
  return ("saved here, but not sent to the guild (%s)."):format(tostring(reason))
end

-- Item id and plain-text name from a shift-clicked link, or from "<id> <name>".
local function parseItem(text)
  local id = text:match("|Hitem:(%d+)")
  local name
  if id then
    name = text:match("|h%[(.-)%]|h")
  else
    id, name = text:match("^(%d+)%s+(.+)$")
  end
  if not (id and name) then
    return nil
  end
  name = name:gsub("|", ""):gsub("%c", ""):match("^%s*(.-)%s*$")
  if name == "" then
    return nil
  end
  return { itemId = tonumber(id), itemName = name }
end

function LootCommands:ResolveEvent(token)
  local index = tonumber(token)
  local list = ns.EventService.List({ events = self.events })
  if not index or index % 1 ~= 0 or not list[index] then
    return nil, "give the event number from /nrage event."
  end
  return list[index]
end

local function resolveSession(event, token)
  local index = tonumber(token)
  local session = index and index % 1 == 0 and ns.LootService.Sessions(event)[index] or nil
  if not session then
    return nil, ("no session number %s: see /nrage loot <event>."):format(tostring(token))
  end
  return session
end

local function voteSummary(session)
  local voters = 0
  for _ in pairs(session.votes) do
    voters = voters + 1
  end
  if not ns.LootService.VotesVisible(session) then
    return ("%d vote(s) cast (hidden until the session closes)"):format(voters)
  end
  local parts = {}
  for _, entry in ipairs(ns.LootService.Tally(session)) do
    parts[#parts + 1] = ("%s %d"):format(entry.characterKey, entry.count)
  end
  return #parts > 0 and ("votes: " .. table.concat(parts, ", ")) or "no votes yet"
end

local function listSessions(event)
  local sessions = ns.LootService.Sessions(event)
  if #sessions == 0 then
    return { ("No loot sessions for '%s' yet."):format(event.title) }
  end
  local lines = { ("Loot sessions for '%s':"):format(event.title) }
  for index, session in ipairs(sessions) do
    local outcome = session.award and (" - awarded to " .. session.award.characterKey) or ""
    lines[#lines + 1] = ("  %d. %s [%s]%s"):format(index, session.itemName, session.status, outcome)
  end
  return lines
end

local function detail(session)
  local lines = { ("%s [%s]"):format(session.itemName, session.status) }
  local keys = {}
  for key in pairs(session.candidates) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  if #keys == 0 then
    lines[#lines + 1] = "  no candidates yet"
  end
  for _, key in ipairs(keys) do
    local candidate = session.candidates[key]
    local upgrade = candidate.upgrade and (" - " .. candidate.upgrade) or ""
    lines[#lines + 1] = ("  %s: %s, %s%s"):format(key, candidate.spec, candidate.need, upgrade)
  end
  lines[#lines + 1] = "  " .. voteSummary(session)
  if session.award then
    lines[#lines + 1] = ("  awarded to %s by %s: %s"):format(
      session.award.characterKey,
      session.award.awardedBy,
      session.award.reason
    )
  end
  lines[#lines + 1] = "  Addon messages are not private: anyone with the addon can read votes."
  return lines
end

function LootCommands:Open(event, args)
  local ctx = self:Context()
  local item = parseItem(args)
  if not item then
    return { "give an item link (shift-click the item), or an item id and a name: open 19019 Thunderfury." }
  end
  local session, reason = ns.LootService.OpenSession(ctx, event.eventId, item)
  if not session then
    return { fail(ctx, reason) }
  end
  return {
    ("opened a session for %s."):format(session.itemName),
    sentNote(self.comm:SendLootSession(event.eventId, session)),
  }
end

function LootCommands:Session(event, session, verb, args)
  local ctx = self:Context()
  local eventId, sessionId = event.eventId, session.sessionId

  if verb == "" then
    return detail(session)
  end

  if verb == "apply" then
    local spec, need, upgrade = args:match("^(%S+)%s+(%S+)%s*(.-)$")
    if not spec then
      return { "usage: /nrage loot <event> <n> apply <spec> <main|off|other> [upgrade]" }
    end
    local candidate, reason = ns.LootService.Register(ctx, eventId, sessionId, {
      spec = spec,
      need = need,
      upgrade = upgrade ~= "" and upgrade or nil,
    })
    if not candidate then
      return { fail(ctx, reason) }
    end
    return {
      ("you are a candidate for %s (%s, %s)."):format(session.itemName, candidate.spec, candidate.need),
      sentNote(self.comm:SendLootCandidate(eventId, sessionId, candidate)),
    }
  end

  if verb == "vote" then
    -- Everything after "vote" is the name, so spaces need no quotes here (they are accepted anyway).
    local vote, reason = ns.LootService.Vote(ctx, eventId, sessionId, ns.Args.Unquote(args))
    if not vote then
      return { fail(ctx, reason) }
    end
    return {
      ("voted for %s."):format(vote.target),
      sentNote(self.comm:SendLootVote(eventId, sessionId, vote)),
    }
  end

  if verb == "award" then
    -- A name with spaces goes in double quotes: award "Yonemon Gg" highest need
    local target, why = ns.Args.TakeName(args)
    if not target or why == "" then
      return { 'usage: /nrage loot <event> <n> award <name> <reason>   (put a name with spaces in "quotes")' }
    end
    local awarded, reason = ns.LootService.Award(ctx, eventId, sessionId, target, why)
    if not awarded then
      return { fail(ctx, reason) }
    end
    return {
      ("%s awarded to %s."):format(awarded.itemName, target),
      sentNote(self.comm:SendLootAward(eventId, awarded)),
    }
  end

  if verb == "close" then
    local closed, reason = ns.LootService.Close(ctx, eventId, sessionId)
    if not closed then
      return { fail(ctx, reason) }
    end
    return {
      ("closed the session for %s without awarding it."):format(closed.itemName),
      sentNote(self.comm:SendLootSession(eventId, closed)),
    }
  end

  return USAGE
end

function LootCommands:Acta(token)
  local event, problem = self:ResolveEvent(token)
  if not event then
    return { problem }
  end
  local acta = ns.LootService.Acta(event)
  if #acta == 0 then
    return { ("No closed loot sessions for '%s' yet."):format(event.title) }
  end
  local lines = { ("Loot minutes for '%s':"):format(event.title) }
  for _, entry in ipairs(acta) do
    if entry.awardedTo then
      lines[#lines + 1] = ("  %s -> %s (by %s): %s"):format(
        entry.itemName,
        entry.awardedTo,
        entry.awardedBy,
        entry.reason
      )
    else
      lines[#lines + 1] = ("  %s -> not awarded"):format(entry.itemName)
    end
  end
  return lines
end

function LootCommands:Loot(rest)
  local first, remainder = rest:match("^(%S*)%s*(.-)$")
  if first == "" or first == "help" then
    return USAGE
  end
  if first == "acta" then
    return self:Acta(remainder)
  end

  local event, problem = self:ResolveEvent(first)
  if not event then
    return { problem }
  end

  local action, args = remainder:match("^(%S*)%s*(.-)$")
  if action == "" or action == "list" then
    return listSessions(event)
  end
  if action == "open" then
    return self:Open(event, args)
  end

  local session, sessionProblem = resolveSession(event, action)
  if not session then
    return { sessionProblem }
  end
  local verb, verbArgs = args:match("^(%S*)%s*(.-)$")
  return self:Session(event, session, verb, verbArgs)
end

ns.LootCommands = LootCommands
