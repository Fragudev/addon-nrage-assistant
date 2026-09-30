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
      index, ViewModel.Escape(event.title), ViewModel.Escape(event.status), when)

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
        ViewModel.Escape(assignment.encounter), ViewModel.Escape(assignment.characterKey), task)
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
            ViewModel.Escape(session.award.characterKey), ViewModel.Escape(session.award.reason))
        elseif session.status == "closed" then
          outcome = "closed, not awarded"
        else
          local candidates, votes = 0, 0
          for _ in pairs(session.candidates) do candidates = candidates + 1 end
          for _ in pairs(session.votes) do votes = votes + 1 end
          outcome = ("%d candidate(s), %d vote(s) cast"):format(candidates, votes)
        end
        lines[#lines + 1] = ("  %s [%s] - %s"):format(
          ViewModel.Escape(session.itemName), ViewModel.Escape(session.status), outcome)
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
    "/nrage attendance    attendance for an event (attendance <n> <Name-Realm> <state>)",
    "/nrage assign        assignments for an event (assign <n> add <Name-Realm> <encounter>)",
    "/nrage loot          loot council: sessions, candidates, votes, awards (loot for the full usage)",
    "/nrage report        attendance and loot reports (report attendance | report loot, optionally an event)",
    "/nrage export        copy all raid events, attendance and assignments as text",
    "/nrage import        paste an export to merge it into your data (RL/admin only)",
    "/nrage debug         diagnostics (debug selftest | info | identity | roster | lockdown)",
    "/nrage sync          sync state and peers (sync request: ask leaders for the latest raid data)",
  }
end

ns.ViewModel = ViewModel
