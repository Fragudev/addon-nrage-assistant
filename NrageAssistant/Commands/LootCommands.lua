local _, ns = ...

-- The loot council operations the window calls. Each method returns the lines to show, so it is tested without a
-- client. Every change goes through LootService first (which checks the role derived from the guild rank) and is
-- then sent to the guild through Comm.
--   deps: events, platform, comm, onChange (optional: called after a change made here, so the window can react)
--
local LootCommands = {}
LootCommands.__index = LootCommands

local L = ns.L

function LootCommands.New(deps)
  return setmetatable({
    events = deps.events,
    platform = deps.platform,
    comm = deps.comm,
    onChange = deps.onChange,
    rosters = deps.rosters,
    members = deps.members,
  }, LootCommands)
end

function LootCommands:Changed()
  if self.onChange then
    self.onChange()
  end
end

function LootCommands:Context()
  local platform = self.platform
  return {
    events = self.events,
    role = ns.PermissionService.OwnRole(platform),
    actor = platform.GetIdentityKey(),
    rosterId = ns.RosterService.RosterOf(self.members or {}, self.rosters or {}, platform.GetIdentityKey()),
    now = platform.ServerTime,
    newId = function()
      return self.comm:NextId()
    end,
    isLockedDown = platform.IsChatMessagingLockedDown,
  }
end

local function fail(ctx, reason)
  if reason == "forbidden" then
    return L("not allowed: your guild rank gives the role '%s', which cannot do this."):format(tostring(ctx.role))
  end
  local field = tostring(reason):match("^invalid:(.+)$")
  if field then
    return L("invalid %s."):format(field)
  end
  local messages = {
    other_roster = L("that event belongs to another roster."),
    not_found = L("not found."),
    closed = L("that session is already closed."),
    locked_down = L("wait until the encounter ends: sessions cannot be opened while chat messaging is locked down."),
    limit = L("limit reached."),
    not_candidate = L("that character has not put themselves forward as a candidate for this item."),
  }
  return messages[reason] or tostring(reason)
end

-- Adds a note when the change was saved here but could not be queued for the guild.
local function sentNote(ok, reason, detail)
  if ok then
    return nil
  end
  local why = detail and ("%s: %s"):format(tostring(reason), detail) or tostring(reason)
  return L("saved here, but not sent to the guild (%s)."):format(why)
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

LootCommands.ParseItem = parseItem

function LootCommands:OpenItem(event, item)
  local ctx = self:Context()
  local session, reason = ns.LootService.OpenSession(ctx, event.eventId, item)
  if not session then
    return { fail(ctx, reason) }
  end
  self:Changed()
  return {
    L("opened a session for %s."):format(session.itemName),
    sentNote(self.comm:SendLootSession(event.eventId, session)),
  }
end

function LootCommands:Apply(event, session, fields)
  local ctx = self:Context()
  local candidate, reason = ns.LootService.Register(ctx, event.eventId, session.sessionId, fields)
  if not candidate then
    return { fail(ctx, reason) }
  end
  self:Changed()
  return {
    L("you are a candidate for %s (%s, %s)."):format(session.itemName, candidate.spec, candidate.need),
    sentNote(self.comm:SendLootCandidate(event.eventId, session.sessionId, candidate)),
  }
end

function LootCommands:VoteFor(event, session, target)
  local ctx = self:Context()
  local vote, reason = ns.LootService.Vote(ctx, event.eventId, session.sessionId, target)
  if not vote then
    return { fail(ctx, reason) }
  end
  self:Changed()
  return {
    L("voted for %s."):format(vote.target),
    sentNote(self.comm:SendLootVote(event.eventId, session.sessionId, vote)),
  }
end

function LootCommands:AwardTo(event, session, target, why)
  local ctx = self:Context()
  local awarded, reason = ns.LootService.Award(ctx, event.eventId, session.sessionId, target, why)
  if not awarded then
    return { fail(ctx, reason) }
  end
  self:Changed()
  return {
    L("%s awarded to %s."):format(awarded.itemName, target),
    sentNote(self.comm:SendLootAward(event.eventId, awarded)),
  }
end

function LootCommands:CloseSession(event, session)
  local ctx = self:Context()
  local closed, reason = ns.LootService.Close(ctx, event.eventId, session.sessionId)
  if not closed then
    return { fail(ctx, reason) }
  end
  self:Changed()
  return {
    L("closed the session for %s without awarding it."):format(closed.itemName),
    sentNote(self.comm:SendLootSession(event.eventId, closed)),
  }
end

ns.LootCommands = LootCommands
