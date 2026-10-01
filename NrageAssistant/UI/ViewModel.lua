local _, ns = ...

-- Pure presentation logic for the window: turns state into lines of text. No frames, no client API,
-- so it is unit tested. Received data is escaped again here as a second line of defence.
local ViewModel = {}

-- "|" starts colour codes, links and textures in the client's text renderer.
function ViewModel.Escape(text)
  return (tostring(text):gsub("|", "||"))
end

-- args: version, syncLines (Comm:Status()), readinessText (summary.text)
function ViewModel.Home(args)
  local lines = { ("Nrage Assistant %s"):format(args.version), "" }
  lines[#lines + 1] = "Your readiness: " .. args.readinessText
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Sync:"
  for _, line in ipairs(args.syncLines) do
    lines[#lines + 1] = "  " .. ViewModel.Escape(line)
  end
  return lines
end

local function classText(entry)
  return ("%s %s"):format(ViewModel.Escape(entry.class), ViewModel.Escape(entry.level))
end

-- Received profiles, sorted by name. Data older than ROSTER_STALE_SECONDS is labelled stale
-- instead of verified-looking; nothing received is ever shown as verified.
function ViewModel.Roster(roster, now)
  local names = {}
  for name in pairs(roster) do
    names[#names + 1] = name
  end
  table.sort(names)

  if #names == 0 then
    return { "No profiles received yet. Members appear here once they publish theirs." }
  end

  local lines = { ("%d profile(s) received:"):format(#names) }
  for _, name in ipairs(names) do
    local entry = roster[name]
    local age = now - (entry.receivedAt or 0)
    local label = age > ns.Constants.ROSTER_STALE_SECONDS and "stale" or "received"

    local text = ("%s - %s"):format(ViewModel.Escape(name), classText(entry))
    if entry.ilvl then
      text = text .. (", ilvl %s"):format(ViewModel.Escape(entry.ilvl))
    end
    local role = entry.fields and entry.fields.role
    if role then
      text = text .. (", role %s"):format(ViewModel.Escape(role))
    end
    lines[#lines + 1] = ("  %s [%s]"):format(text, label)
  end
  return lines
end

local PUBLISH_ERRORS = {
  no_consent = "profile consent is off. Use /nrage consent profile on.",
  missing_data = "class or level is unknown, nothing to share yet.",
  cooldown = "you published a moment ago, wait a little.",
  full = "the send queue is full, try again shortly.",
  too_large = "the profile is too large to send.",
  encode_failed = "the profile could not be encoded.",
}

function ViewModel.PublishError(reason)
  return PUBLISH_ERRORS[reason] or tostring(reason)
end

-- Events with their attendance summary and assignments, in the order of /nrage event.
-- `formatDate(timestamp)` renders start times. Everything shown is escaped.
function ViewModel.Raid(events, formatDate)
  local list = ns.EventService.List({ events = events })
  if #list == 0 then
    return { "No events yet. A raid leader creates them with /nrage event new <title>." }
  end

  local lines = {}
  for index, event in ipairs(list) do
    local when = event.startAt and (" - " .. formatDate(event.startAt)) or ""
    lines[#lines + 1] = ("%d. %s [%s]%s"):format(
      index,
      ViewModel.Escape(event.title),
      ViewModel.Escape(event.status),
      when
    )

    local counts, states = {}, {}
    for _, record in pairs(event.attendance) do
      if not counts[record.state] then
        states[#states + 1] = record.state
        counts[record.state] = 0
      end
      counts[record.state] = counts[record.state] + 1
    end
    table.sort(states)
    if #states == 0 then
      lines[#lines + 1] = "    Attendance: none recorded"
    else
      local parts = {}
      for _, state in ipairs(states) do
        parts[#parts + 1] = ("%d %s"):format(counts[state], ViewModel.Escape(state))
      end
      lines[#lines + 1] = "    Attendance: " .. table.concat(parts, ", ")
    end

    local assignments = {}
    for _, assignment in pairs(event.assignments) do
      assignments[#assignments + 1] = assignment
    end
    table.sort(assignments, function(a, b)
      if a.encounter ~= b.encounter then
        return a.encounter < b.encounter
      end
      return a.characterKey < b.characterKey
    end)
    for _, assignment in ipairs(assignments) do
      local task = assignment.task and (" - " .. ViewModel.Escape(assignment.task)) or ""
      lines[#lines + 1] = ("    %s: %s%s"):format(
        ViewModel.Escape(assignment.encounter),
        ViewModel.Escape(assignment.characterKey),
        task
      )
    end
    lines[#lines + 1] = ""
  end
  return lines
end

-- Loot council sessions per event: what is open, what was awarded and why. Only aggregate vote
-- counts are shown here (never who voted for whom), and everything from the guild is escaped.
function ViewModel.Loot(events)
  local lines = {}
  for _, event in ipairs(ns.EventService.List({ events = events })) do
    local sessions = ns.LootService.Sessions(event)
    if #sessions > 0 then
      lines[#lines + 1] = ViewModel.Escape(event.title)
      for _, session in ipairs(sessions) do
        local outcome
        if session.award then
          outcome = ("awarded to %s - %s"):format(
            ViewModel.Escape(session.award.characterKey),
            ViewModel.Escape(session.award.reason)
          )
        elseif session.status == "closed" then
          outcome = "closed, not awarded"
        else
          local candidates, votes = 0, 0
          for _ in pairs(session.candidates) do
            candidates = candidates + 1
          end
          for _ in pairs(session.votes) do
            votes = votes + 1
          end
          outcome = ("%d candidate(s), %d vote(s) cast"):format(candidates, votes)
        end
        lines[#lines + 1] = ("  %s [%s] - %s"):format(
          ViewModel.Escape(session.itemName),
          ViewModel.Escape(session.status),
          outcome
        )
      end
      lines[#lines + 1] = ""
    end
  end
  if #lines == 0 then
    lines[1] = "No loot sessions yet. The council opens one after an encounter with /nrage loot <event> open <item>."
  end
  lines[#lines + 1] = "Addon messages are not private: anyone with the addon can read votes."
  return lines
end

ViewModel.EVENT_STATUSES = { "planned", "open", "closed", "cancelled" }
ViewModel.ATTENDANCE_STATES = { "invited", "confirmed", "present", "late", "leftEarly", "absent", "excused", "unknown" }

-- What the Raid tab offers a role. These are the same checks the commands make (EventService repeats
-- them on every change), so a hidden control is never the only thing standing between a member and a change.
function ViewModel.RaidActions(role)
  local can = ns.PermissionService.Can
  return {
    events = can(role, "manage_events"),
    attendance = can(role, "record_attendance"),
    assignments = can(role, "manage_assignments"),
  }
end

-- Dropdown entries for the events, in the order of /nrage event: list[eventId] = label, plus the ids in order.
function ViewModel.EventChoices(events)
  local list, order = {}, {}
  for index, event in ipairs(ns.EventService.List({ events = events })) do
    list[event.eventId] = ("%d. %s [%s]"):format(index, ViewModel.Escape(event.title), ViewModel.Escape(event.status))
    order[#order + 1] = event.eventId
  end
  return list, order
end

-- One row per member for the attendance grid: everyone in the guild roster plus anyone already recorded
-- for the event, sorted, narrowed by `filter` (case-insensitive part of a name) and cut at `limit` rows.
-- `state` is nil for someone with no record. Returns the rows and how many matched before the cut.
function ViewModel.AttendanceRows(event, memberNames, filter, limit)
  local seen, names = {}, {}
  local function add(name)
    if not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  for _, name in ipairs(memberNames) do
    add(name)
  end
  for name in pairs(event.attendance) do
    add(name)
  end
  table.sort(names)

  local needle = (filter or ""):lower()
  local rows, matched = {}, 0
  for _, name in ipairs(names) do
    if needle == "" or name:lower():find(needle, 1, true) then
      matched = matched + 1
      if matched <= limit then
        local record = event.attendance[name]
        rows[#rows + 1] = { name = name, state = record and record.state or nil }
      end
    end
  end
  return rows, matched
end

-- What the Loot tab offers a role: the same checks as the commands (LootService repeats them on every change).
function ViewModel.LootActions(role)
  local can = ns.PermissionService.Can
  return {
    open = can(role, "loot_open"),
    apply = can(role, "loot_apply"),
    vote = can(role, "loot_vote"),
    award = can(role, "loot_award"),
  }
end

ViewModel.LOOT_NEEDS = { "main", "off", "other" }

-- One loot session as lines: item, candidates, votes and decision. Vote counts follow the session's
-- visibility policy (hidden while open unless configured otherwise); everything is escaped.
function ViewModel.LootSession(session)
  local lines = { ("%s [%s]"):format(ViewModel.Escape(session.itemName), ViewModel.Escape(session.status)) }

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
    local upgrade = candidate.upgrade and (" - " .. ViewModel.Escape(candidate.upgrade)) or ""
    lines[#lines + 1] = ("  %s: %s, %s%s"):format(
      ViewModel.Escape(key),
      ViewModel.Escape(candidate.spec),
      ViewModel.Escape(candidate.need),
      upgrade
    )
  end

  if ns.LootService.VotesVisible(session) then
    local parts = {}
    for _, entry in ipairs(ns.LootService.Tally(session)) do
      parts[#parts + 1] = ("%s %d"):format(ViewModel.Escape(entry.characterKey), entry.count)
    end
    lines[#lines + 1] = "  " .. (#parts > 0 and ("votes: " .. table.concat(parts, ", ")) or "no votes yet")
  else
    local voters = 0
    for _ in pairs(session.votes) do
      voters = voters + 1
    end
    lines[#lines + 1] = ("  %d vote(s) cast (hidden until the session closes)"):format(voters)
  end

  if session.award then
    lines[#lines + 1] = ("  awarded to %s by %s: %s"):format(
      ViewModel.Escape(session.award.characterKey),
      ViewModel.Escape(session.award.awardedBy),
      ViewModel.Escape(session.award.reason)
    )
  elseif session.status == "closed" then
    lines[#lines + 1] = "  closed, not awarded"
  end
  return lines
end

-- Dropdown entries for the candidates of a session: list[characterKey] = label, plus the keys sorted.
function ViewModel.CandidateChoices(session)
  local list, order = {}, {}
  for key in pairs(session.candidates) do
    order[#order + 1] = key
  end
  table.sort(order)
  for _, key in ipairs(order) do
    local candidate = session.candidates[key]
    list[key] = ("%s (%s, %s)"):format(
      ViewModel.Escape(key),
      ViewModel.Escape(candidate.spec),
      ViewModel.Escape(candidate.need)
    )
  end
  return list, order
end

-- What a player may set by hand on a readiness item (ReadinessService.SetManual accepts the same four).
ViewModel.READY_STATUSES = { "met", "missing", "waived", "unknown" }

ViewModel.READY_SET_ERRORS = {
  unknown_rule = "unknown item.",
  not_manual = "that item is measured automatically and cannot be set by hand.",
  invalid_status = "status must be met, missing, waived or unknown.",
}

-- The items the player confirms by hand, with their current status: { ruleId, label, status } in rule order.
-- `results` is what ReadinessService.Evaluate returned for the same `rules`.
function ViewModel.ManualItems(rules, results)
  local items = {}
  for index, rule in ipairs(rules) do
    if rule.check == "confirm" and results[index] then
      items[#items + 1] = {
        ruleId = rule.id,
        label = ViewModel.Escape(rule.label),
        status = results[index].status,
      }
    end
  end
  return items
end

-- The event to put first in the minimap tooltip: among the planned or open events, the one starting soonest that
-- has not started yet (an open event is kept even after its start); undated ones come last. nil when none.
function ViewModel.NextEvent(events, now)
  local best
  for _, event in ipairs(ns.EventService.List({ events = events })) do
    local active = event.status == "planned" or event.status == "open"
    local upcoming = event.startAt == nil or event.startAt >= now or event.status == "open"
    if active and upcoming then
      best = best or event
      if event.startAt then
        return event
      end
    end
  end
  return best
end

-- Lines for the minimap tooltip. It reads only what the addon already holds: no game API is called, so it is
-- safe during an encounter lockdown.
-- args: events, now, formatDate(timestamp), readinessText, pending (queued messages), paused (queue held back)
function ViewModel.MinimapTooltip(args)
  local lines = {}
  local event = ViewModel.NextEvent(args.events, args.now)
  if event then
    local when = event.startAt and (" - " .. args.formatDate(event.startAt)) or ""
    lines[#lines + 1] = ("Next event: %s%s"):format(ViewModel.Escape(event.title), when)
  else
    lines[#lines + 1] = "Next event: none planned"
  end
  lines[#lines + 1] = "Readiness: " .. args.readinessText
  if args.pending == 0 then
    lines[#lines + 1] = "Sync queue: empty"
  else
    local held = args.paused and " (held back: encounter in progress)" or ""
    lines[#lines + 1] = ("Sync queue: %d message(s) waiting%s"):format(args.pending, held)
  end
  return lines
end

-- Right-click menu of the minimap button: a shortcut to each tab, then a sync request.
function ViewModel.MinimapMenu()
  local entries = {}
  for _, tab in ipairs(ViewModel.TABS) do
    entries[#entries + 1] = { text = tab.text, action = "tab", value = tab.value }
  end
  entries[#entries + 1] = { text = "Request a sync", action = "sync" }
  return entries
end

ViewModel.SYNC_REQUEST_ERRORS = {
  cooldown = "you asked a moment ago, wait a little.",
  full = "the send queue is full, try again shortly.",
}

-- The line to print after asking the guild for the latest raid data.
function ViewModel.SyncRequestResult(ok, reason)
  if ok then
    return "asked the guild for the latest raid data; leaders answer by whisper."
  end
  return "not requested: " .. (ViewModel.SYNC_REQUEST_ERRORS[reason] or tostring(reason))
end

-- Lines for the minimap tooltip when the silent self test found failures (Diagnostics.Failures).
function ViewModel.SelfTestFailures(failures)
  local lines = { ("Self test: %d check(s) failed"):format(#failures) }
  for _, entry in ipairs(failures) do
    local detail = entry.detail and (" - " .. ViewModel.Escape(entry.detail)) or ""
    lines[#lines + 1] = ("  [%s] %s%s"):format(ViewModel.Escape(entry.status), ViewModel.Escape(entry.name), detail)
  end
  lines[#lines + 1] = "Type /nrage debug selftest for the full result."
  return lines
end

-- The loot sessions waiting for an answer from `actor`: open, no candidacy of theirs yet, and not passed on or
-- dismissed (`dismissed[sessionId] = true`). Sorted by event title, item name, then id so the popup is stable.
-- Returns { eventId, sessionId, eventTitle, itemName } entries, text unescaped (escape when drawing).
function ViewModel.PendingLoot(events, actor, dismissed)
  local pending = {}
  for _, event in pairs(events) do
    for _, session in ipairs(ns.LootService.Sessions(event)) do
      if session.status == "open" and not session.candidates[actor] and not dismissed[session.sessionId] then
        pending[#pending + 1] = {
          eventId = event.eventId,
          sessionId = session.sessionId,
          eventTitle = event.title,
          itemName = session.itemName,
        }
      end
    end
  end
  table.sort(pending, function(a, b)
    if a.eventTitle ~= b.eventTitle then
      return a.eventTitle < b.eventTitle
    end
    if a.itemName ~= b.itemName then
      return a.itemName < b.itemName
    end
    return a.sessionId < b.sessionId
  end)
  return pending
end

-- The spec put on a candidacy made with one click: the declared role, else the class, else a placeholder.
function ViewModel.DefaultSpec(profile)
  local role = profile.fields and profile.fields.role and profile.fields.role.value
  if type(role) == "string" and role:match("%S") then
    return role
  end
  if type(profile.class) == "string" and profile.class:match("%S") then
    return profile.class
  end
  return "unknown"
end

ViewModel.LOOT_NEED_LABELS = { main = "Main spec", off = "Off spec", other = "Other" }

-- The items the voting window can switch between: every open session, plus the selected one even if it has
-- closed (so the decision stays visible). Entries are { eventId, sessionId, itemName, eventTitle, selected },
-- text escaped, ordered by event title, item name, then id.
function ViewModel.VotingSessions(events, selectedId)
  local list = {}
  for _, event in pairs(events) do
    for _, session in ipairs(ns.LootService.Sessions(event)) do
      if session.status == "open" or session.sessionId == selectedId then
        list[#list + 1] = {
          eventId = event.eventId,
          sessionId = session.sessionId,
          itemName = ViewModel.Escape(session.itemName),
          eventTitle = ViewModel.Escape(event.title),
          selected = session.sessionId == selectedId,
          sort = event.title .. "\n" .. session.itemName .. "\n" .. session.sessionId,
        }
      end
    end
  end
  table.sort(list, function(a, b)
    return a.sort < b.sort
  end)
  return list
end

-- One line on where a session stands.
function ViewModel.VotingStatus(session)
  if session.award then
    return ("Awarded to %s by %s: %s"):format(
      ViewModel.Escape(session.award.characterKey),
      ViewModel.Escape(session.award.awardedBy),
      ViewModel.Escape(session.award.reason)
    )
  end
  if session.status == "closed" then
    return "Closed without an award"
  end
  local candidates, votes = 0, 0
  for _ in pairs(session.candidates) do
    candidates = candidates + 1
  end
  for _ in pairs(session.votes) do
    votes = votes + 1
  end
  return ("Voting is open: %d candidate(s), %d vote(s) cast"):format(candidates, votes)
end

-- The table of the voting window: one row per candidate, most votes first (alphabetical while votes are
-- hidden). `votes` is nil while the visibility policy hides them. `mine` marks the candidate `actor` voted
-- for. `rankOf(name)` gives the guild rank name or nil. Text is escaped.
function ViewModel.VotingRows(session, actor, rankOf)
  local counts = {}
  local visible = ns.LootService.VotesVisible(session)
  for _, entry in ipairs(ns.LootService.Tally(session)) do
    counts[entry.characterKey] = entry.count
  end
  local myVote = session.votes[actor] and session.votes[actor].target

  local rows = {}
  for name, candidate in pairs(session.candidates) do
    rows[#rows + 1] = {
      name = name,
      label = ViewModel.Escape(name),
      rank = ViewModel.Escape(rankOf(name) or "?"),
      need = candidate.need,
      response = ("%s (%s)"):format(
        ViewModel.Escape(ViewModel.LOOT_NEED_LABELS[candidate.need] or candidate.need),
        ViewModel.Escape(candidate.spec)
      ),
      upgrade = candidate.upgrade and ViewModel.Escape(candidate.upgrade) or "",
      votes = visible and (counts[name] or 0) or nil,
      mine = myVote == name,
    }
  end
  table.sort(rows, function(a, b)
    if (a.votes or 0) ~= (b.votes or 0) then
      return (a.votes or 0) > (b.votes or 0)
    end
    return a.name < b.name
  end)
  return rows
end

ViewModel.TABS = {
  { value = "home", text = "Home" },
  { value = "profile", text = "Profile" },
  { value = "ready", text = "Readiness" },
  { value = "raid", text = "Raid" },
  { value = "loot", text = "Loot" },
  { value = "roster", text = "Roster" },
}

function ViewModel.HelpLines()
  return {
    "/nrage               open the window",
    "/nrage help          this list",
    "/nrage version       addon version",
    "/nrage role          your guild rank, addon role and what it allows",
    "/nrage profile       show your profile (profile set <role|main|notes> <text>)",
    "/nrage ready         readiness checklist (ready set <item> <met|missing|waived|unknown>)",
    "/nrage consent       what you agree to share (consent <key> on|off)",
    "/nrage publish       preview, then 'publish confirm' to share your profile",
    "/nrage event         raid events (event new <title> | rename | status | start | delete)",
    "/nrage attendance    attendance for an event (attendance <n> <name> <state>)",
    '/nrage assign        assignments for an event (assign <n> add <name> <encounter>; "quotes" for names with spaces)',
    "/nrage loot          loot council: sessions, candidates, votes, awards (loot for the full usage)",
    "/nrage template      save an event's assignments as a template and apply it to another event",
    "/nrage report        attendance and loot reports (report attendance | report loot, optionally an event)",
    "/nrage export        copy all raid events, attendance and assignments as text",
    "/nrage import        paste an export to merge it into your data (RL/admin only)",
    "/nrage debug         diagnostics (debug selftest | info | identity | roster | lockdown)",
    "/nrage minimap       show, hide or reset the minimap button (minimap show | hide | reset)",
    "/nrage sync          sync state and peers (sync request: ask leaders for the latest raid data)",
  }
end

ns.ViewModel = ViewModel
