local _, ns = ...

-- Structured rows for the Raid and Loot tabs (plan 3.4 and 3.5): the event list, attendance, assignments by
-- encounter, report tables, the loot session cards and the minutes. They return tables of values, not lines of text.
local ViewModel = ns.ViewModel
local L = ns.L
local Escape = ViewModel.Escape

-- ---------------------------------------------------------------------------------------------------------------
-- Raid: the event list

ViewModel.EVENT_FILTERS = ns.Locale.Table(function()
  return {
    { value = "upcoming", text = L("Upcoming") },
    { value = "past", text = L("Past") },
  }
end)

-- An event is in the past when it started already, or it is closed or cancelled.
function ViewModel.IsPastEvent(event, now)
  if event.status == "closed" or event.status == "cancelled" then
    return true
  end
  return event.startAt ~= nil and event.startAt < now
end

-- The event list of the Raid tab. `events` is what the viewer sees (RosterService.FilterEvents). options = { filter =
-- "upcoming" (default) | "past", now, rosters }. Upcoming events come soonest first (undated last), past ones latest
-- first. Rows: { eventId, title, dateText, status, statusText, statusToken, rosterName }.
function ViewModel.EventListRows(events, options)
  local filter = options.filter or "upcoming"
  local list = {}
  for _, event in pairs(events) do
    if (filter == "past") == ViewModel.IsPastEvent(event, options.now) then
      list[#list + 1] = event
    end
  end
  table.sort(list, function(a, b)
    local left, right = a.startAt, b.startAt
    if left ~= right then
      if left == nil or right == nil then
        return left ~= nil
      end
      if filter == "past" then
        return left > right
      end
      return left < right
    end
    if a.title ~= b.title then
      return a.title < b.title
    end
    return a.eventId < b.eventId
  end)
  local rows = {}
  for _, event in ipairs(list) do
    rows[#rows + 1] = {
      eventId = event.eventId,
      title = Escape(event.title),
      dateText = event.startAt and ViewModel.DateText(event.startAt) or L("No date"),
      status = event.status,
      statusText = ViewModel.Word(event.status),
      statusToken = ns.Kit.Theme.StatusToken(event.status),
      rosterName = options.rosters and event.rosterId and Escape(
        ns.RosterService.NameOf(options.rosters, event.rosterId)
      ) or nil,
    }
  end
  return rows
end

-- The title, date and status of the selected event for the page header of the Raid tab.
function ViewModel.EventHeader(event, rosters)
  return {
    title = Escape(event.title),
    dateText = event.startAt and ViewModel.DateText(event.startAt) or L("No date"),
    status = event.status,
    statusText = ViewModel.Word(event.status),
    statusToken = ns.Kit.Theme.StatusToken(event.status),
    rosterName = event.rosterId and rosters and Escape(ns.RosterService.NameOf(rosters, event.rosterId) or "?") or nil,
  }
end

function ViewModel.EventStatusChoices()
  local items = {}
  for _, status in ipairs(ViewModel.EVENT_STATUSES) do
    items[#items + 1] = { value = status, text = ViewModel.Word(status), color = ns.Kit.Theme.StatusToken(status) }
  end
  return items
end

function ViewModel.AttendanceStateChoices()
  local items = {}
  for _, state in ipairs(ViewModel.ATTENDANCE_STATES) do
    items[#items + 1] = { value = state, text = ViewModel.Word(state) }
  end
  return items
end

-- The attendance summary of the Summary sub-tab: how many of each state, and the number of assignments.
function ViewModel.EventSummary(event)
  local counts, order = {}, {}
  for _, record in pairs(event.attendance) do
    if not counts[record.state] then
      counts[record.state] = 0
      order[#order + 1] = record.state
    end
    counts[record.state] = counts[record.state] + 1
  end
  local ranks = {}
  for index, state in ipairs(ViewModel.ATTENDANCE_STATES) do
    ranks[state] = index
  end
  table.sort(order, function(a, b)
    return (ranks[a] or 99) < (ranks[b] or 99)
  end)
  local stats = {}
  for _, state in ipairs(order) do
    stats[#stats + 1] = { caption = ViewModel.Word(state), value = tostring(counts[state]) }
  end
  local assignments = 0
  for _ in pairs(event.assignments) do
    assignments = assignments + 1
  end
  return { attendance = stats, assignments = assignments, recorded = #order > 0 }
end

-- ---------------------------------------------------------------------------------------------------------------
-- Raid: attendance

-- The members of `groupNames` (the current party or raid, names as the client gives them) that are in the guild, as
-- the guild roster writes them. A group name matches a guild name exactly, or, when it is one word, the first word of
-- one multi-word guild name (the client gives only that word for a multi-word name), but only when that is unambiguous.
-- Returns the matched guild names (each once) and how many group names matched none.
function ViewModel.MatchGroupToGuild(groupNames, guildNames)
  local exact, byFirstWord = {}, {}
  for _, name in ipairs(guildNames) do
    exact[name] = true
    local first = name:match("^(%S+)%s+%S")
    if first then
      local key = first:lower()
      byFirstWord[key] = byFirstWord[key] or {}
      table.insert(byFirstWord[key], name)
    end
  end
  local matched, seen, unmatched = {}, {}, 0
  for _, group in ipairs(groupNames) do
    local name
    if exact[group] then
      name = group
    elseif not group:find("%s") and byFirstWord[group:lower()] and #byFirstWord[group:lower()] == 1 then
      name = byFirstWord[group:lower()][1]
    end
    if name then
      if not seen[name] then
        seen[name] = true
        matched[#matched + 1] = name
      end
    else
      unmatched = unmatched + 1
    end
  end
  table.sort(matched)
  return matched, unmatched
end

-- What "Fill from current group" would do: the group members that are in the guild and not recorded yet (members
-- already
-- recorded are never overwritten). Returns { toMark = names, alreadyRecorded = n, unmatched = n }.
function ViewModel.FillFromGroup(event, groupNames, guildNames)
  local matched, unmatched = ViewModel.MatchGroupToGuild(groupNames, guildNames)
  local toMark, already = {}, 0
  for _, name in ipairs(matched) do
    if event.attendance[name] then
      already = already + 1
    else
      toMark[#toMark + 1] = name
    end
  end
  return { toMark = toMark, alreadyRecorded = already, unmatched = unmatched }
end

-- The recorded members of an event as table rows: { name, label, state, recordedBy, recordedAt }.
function ViewModel.AttendanceRows(event, now)
  local rows = {}
  for name, record in pairs(event.attendance) do
    rows[#rows + 1] = {
      name = name,
      label = Escape(name),
      state = record.state,
      recordedBy = record.recordedBy and Escape(record.recordedBy) or nil,
      recordedAt = record.updatedAt and now and ViewModel.AgeText(math.max(0, now - record.updatedAt)) or nil,
    }
  end
  table.sort(rows, function(a, b)
    return a.name < b.name
  end)
  return rows
end

-- ---------------------------------------------------------------------------------------------------------------
-- Raid: assignments by encounter

-- One group per encounter, sorted by name: { encounter, rows = { { assignmentId, characterKey, task, text } } }.
function ViewModel.AssignmentGroups(event)
  local groups, byEncounter = {}, {}
  for _, assignment in ipairs(ns.RaidCommands.SortedAssignments(event)) do
    local group = byEncounter[assignment.encounter]
    if not group then
      group = { encounter = Escape(assignment.encounter), rows = {} }
      byEncounter[assignment.encounter] = group
      groups[#groups + 1] = group
    end
    local text = Escape(assignment.characterKey)
    if assignment.task then
      text = text .. " \226\128\148 " .. Escape(assignment.task)
    end
    group.rows[#group.rows + 1] = {
      assignmentId = assignment.assignmentId,
      characterKey = assignment.characterKey,
      task = assignment.task,
      text = text,
      assignment = assignment,
    }
  end
  return groups
end

ViewModel.NEW_ENCOUNTER = "\0new"

-- The encounters already used in this event, plus an entry that turns into a text input ("New encounter...").
function ViewModel.EncounterChoices(event)
  local items, seen = {}, {}
  for _, assignment in pairs(event.assignments) do
    if not seen[assignment.encounter] then
      seen[assignment.encounter] = true
      items[#items + 1] = { value = assignment.encounter, text = Escape(assignment.encounter) }
    end
  end
  table.sort(items, function(a, b)
    return a.value < b.value
  end)
  items[#items + 1] = { value = ViewModel.NEW_ENCOUNTER, text = L("New encounter...") }
  return items
end

-- The members as dropdown items.
function ViewModel.MemberChoices(names)
  local items = {}
  for _, name in ipairs(names) do
    items[#items + 1] = { value = name, text = Escape(name) }
  end
  return items
end

-- Templates as cards: the suggested ones for the event, and the saved ones for a dropdown.
function ViewModel.TemplateChoices(names)
  local items = {}
  for _, name in ipairs(names) do
    items[#items + 1] = { value = name, text = Escape(name) }
  end
  return items
end

-- ---------------------------------------------------------------------------------------------------------------
-- Raid: reports as tables

ViewModel.REPORT_SCOPES = ns.Locale.Table(function()
  return {
    { value = "event", text = L("This event") },
    { value = "all", text = L("All events") },
  }
end)

-- The attendance and loot reports as tables. `events` is what the viewer sees; with `allEvents` false only `event`
-- counts. Returns { attendance = { rows, held, note }, loot = { rows, totals, note } }; every cell is escaped text.
function ViewModel.ReportTables(events, event, allEvents)
  local scope = allEvents and events or { [event.eventId] = event }
  local attendanceRows, held = ns.ReportService.Attendance(scope)
  local rows = {}
  for _, row in ipairs(attendanceRows) do
    local parts = {}
    for _, state in ipairs(ViewModel.ATTENDANCE_STATES) do
      if row.counts[state] then
        parts[#parts + 1] = ("%s %d"):format(ViewModel.Word(state), row.counts[state])
      end
    end
    rows[#rows + 1] = {
      name = Escape(row.characterKey),
      attended = tostring(row.attended),
      outcomes = tostring(row.outcomes),
      rate = row.rate and ("%d%%"):format(math.floor(row.rate * 100 + 0.5)) or "-",
      detail = Escape(table.concat(parts, ", ")),
    }
  end
  local note
  if held == 0 then
    note = L("No events held yet: only open or closed events count towards attendance.")
  elseif #rows == 0 then
    note = L("%d event(s) held, but no attendance recorded yet."):format(held)
  end

  local lootRows, totals = ns.ReportService.Loot(scope)
  local loot = {}
  for _, row in ipairs(lootRows) do
    loot[#loot + 1] = {
      name = Escape(row.characterKey),
      awards = tostring(row.awards),
      items = Escape(table.concat(row.items, ", ")),
    }
  end
  local lootNote
  if totals.sessions == 0 then
    lootNote = L("No loot sessions yet.")
  else
    lootNote = L("Loot: %d session(s), %d awarded, %d closed without an award, %d still open."):format(
      totals.sessions,
      totals.awarded,
      totals.notAwarded,
      totals.open
    )
  end
  return {
    attendance = { rows = rows, held = held, note = note },
    loot = { rows = loot, totals = totals, note = lootNote },
  }
end

-- ---------------------------------------------------------------------------------------------------------------
-- Loot

-- The event the Loot tab opens on: the most recent event with an open session, otherwise the most recent event.
-- `events` is what the viewer sees. Returns the event id, or nil when there are no events.
function ViewModel.DefaultLootEvent(events)
  local best, bestOpen
  local function newer(a, b)
    if not b then
      return true
    end
    local left, right = a.startAt or a.updatedAt or 0, b.startAt or b.updatedAt or 0
    if left ~= right then
      return left > right
    end
    return a.eventId < b.eventId
  end
  for _, event in pairs(events) do
    if newer(event, best) then
      best = event
    end
    local open = false
    for _, session in pairs(event.loot or {}) do
      open = open or session.status == "open"
    end
    if open and newer(event, bestOpen) then
      bestOpen = event
    end
  end
  local chosen = bestOpen or best
  return chosen and chosen.eventId or nil
end

-- The events as dropdown items, most recent first: "Raid night - Thu 23 Oct".
function ViewModel.LootEventChoices(events)
  local list = {}
  for _, event in pairs(events) do
    list[#list + 1] = event
  end
  table.sort(list, function(a, b)
    local left, right = a.startAt or a.updatedAt or 0, b.startAt or b.updatedAt or 0
    if left ~= right then
      return left > right
    end
    return a.eventId < b.eventId
  end)
  local items = {}
  for _, event in ipairs(list) do
    local when = event.startAt and (" - " .. ViewModel.DateText(event.startAt)) or ""
    items[#items + 1] = { value = event.eventId, text = Escape(event.title) .. when }
  end
  return items
end

-- The response color tokens: main spec = success, off spec = warning, other = accent (as in the voting window).
ViewModel.NEED_TOKENS = { main = "success", off = "warning", other = "accent" }

-- "1:05", the time left in the countdown, or nil.
function ViewModel.TimeLeftText(seconds)
  if type(seconds) ~= "number" then
    return nil
  end
  seconds = math.max(0, math.ceil(seconds))
  return L("%d:%02d left"):format(math.floor(seconds / 60), seconds % 60)
end

-- The session cards of an event, newest first. options = { actor, rankOf(name), actions = LootActions,
-- timeLeft(sessionId)
-- -> seconds or nil, sort, need }. A card: { sessionId, itemId, itemName, open, status, statusText, statusToken,
-- subtitle, timeLeft, candidates = rows, award = { winner, response, reason }, canVote, canAward }. A closed session
-- carries `summary` for its one-line form: "item -> winner (response)" and the reason.
function ViewModel.LootSessionCards(event, options)
  local sessions = ns.LootService.Sessions(event)
  table.sort(sessions, function(a, b)
    if a.updatedAt ~= b.updatedAt then
      return (a.updatedAt or 0) > (b.updatedAt or 0)
    end
    return a.sessionId < b.sessionId
  end)
  local cards = {}
  for _, session in ipairs(sessions) do
    local open = session.status == "open"
    local rows = ViewModel.VotingRows(session, options.actor, options.rankOf or function() end, {
      sort = options.sort,
      need = options.need,
    })
    for _, row in ipairs(rows) do
      row.needToken = ViewModel.NEED_TOKENS[row.need] or "muted"
      row.responseText = Escape(ViewModel.LOOT_NEED_LABELS[row.need] or row.need)
      row.canVote = open and options.actions.vote == true
      row.canAward = open and options.actions.award == true
    end
    local card = {
      sessionId = session.sessionId,
      itemId = session.itemId,
      itemName = Escape(session.itemName),
      open = open,
      status = session.status,
      statusText = ViewModel.Word(session.status),
      statusToken = open and "success" or "muted",
      subtitle = Escape(event.title),
      timeLeft = open and options.timeLeft and ViewModel.TimeLeftText(options.timeLeft(session.sessionId)) or nil,
      candidates = rows,
      canClose = open and options.actions.award == true,
      session = session,
    }
    if session.award then
      local candidate = session.candidates[session.award.characterKey]
      card.award = {
        winner = Escape(session.award.characterKey),
        response = candidate and Escape(ViewModel.LOOT_NEED_LABELS[candidate.need] or candidate.need) or nil,
        reason = Escape(session.award.reason),
      }
      card.summary = card.award.response
          and ("%s \226\134\146 %s (%s)"):format(card.itemName, card.award.winner, card.award.response)
        or ("%s \226\134\146 %s"):format(card.itemName, card.award.winner)
    elseif not open then
      card.summary = L("%s: closed, not awarded"):format(card.itemName)
    end
    cards[#cards + 1] = card
  end
  return cards
end

-- The minutes as a table: item, winner, response, reason and date, oldest first. Only decisions, never who voted.
function ViewModel.MinutesTable(event, formatDate)
  local sessions = {}
  for _, session in pairs(event.loot or {}) do
    if session.status == "closed" then
      sessions[#sessions + 1] = session
    end
  end
  table.sort(sessions, function(a, b)
    if a.updatedAt ~= b.updatedAt then
      return (a.updatedAt or 0) < (b.updatedAt or 0)
    end
    return a.sessionId < b.sessionId
  end)
  local rows = {}
  for _, session in ipairs(sessions) do
    local award = session.award
    local candidate = award and session.candidates[award.characterKey]
    rows[#rows + 1] = {
      item = Escape(session.itemName),
      winner = award and Escape(award.characterKey) or "-",
      response = candidate and Escape(ViewModel.LOOT_NEED_LABELS[candidate.need] or candidate.need) or "-",
      reason = award and Escape(award.reason) or L("not awarded"),
      date = (award and award.at or session.updatedAt) and formatDate and formatDate(
        award and award.at or session.updatedAt
      ) or "-",
    }
  end
  return rows
end

-- The spec a candidacy from the Loot tab carries, from the declared specs of the profile: main uses the main spec,
-- off the second spec (the main one when there is none), other the main spec. Nil when no spec is declared.
function ViewModel.LootApplySpec(profile, need)
  local fields = profile.fields or {}
  local main = fields.role and ns.ProfileService.NormalizeRole(fields.role.value)
  local second = fields.role2 and ns.ProfileService.NormalizeRole(fields.role2.value)
  if need == "off" then
    return second or main
  end
  return main
end

-- The quality (0 poor .. 5 legendary) of an item link, from the color code in it, or nil.
local LINK_QUALITY = {
  ["9d9d9d"] = 0,
  ["ffffff"] = 1,
  ["1eff00"] = 2,
  ["0070dd"] = 3,
  ["a335ee"] = 4,
  ["ff8000"] = 5,
}

function ViewModel.ItemQuality(link)
  local color = type(link) == "string" and link:match("|cff(%x%x%x%x%x%x)")
  return color and LINK_QUALITY[color:lower()] or nil
end

-- The preview of a pasted item link: { itemId, itemName, quality } or nil when it is not an item the sessions accept.
function ViewModel.ItemPreview(text)
  if type(text) ~= "string" then
    return nil
  end
  local parsed = ns.LootCommands.ParseItem(text)
  if not parsed then
    return nil
  end
  parsed.quality = ViewModel.ItemQuality(text)
  return parsed
end

-- The strip of the corpse the player last looted: up to `limit` { itemId, itemName, link, icon, quality } from what
-- Platform.GetLootWindowItems returned; entries that are not items a session accepts are left out.
function ViewModel.BossLootItems(items, limit)
  local result = {}
  for _, item in ipairs(items or {}) do
    local parsed = ns.LootCommands.ParseItem(item.link)
    if parsed and #result < (limit or 12) then
      result[#result + 1] = {
        itemId = parsed.itemId,
        itemName = parsed.itemName,
        link = item.link,
        icon = item.icon,
        quality = ViewModel.ItemQuality(item.link),
      }
    end
  end
  return result
end
