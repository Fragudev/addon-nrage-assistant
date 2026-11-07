local _, ns = ...

-- Pure presentation logic for the window: turns state into lines of text. No frames, no client API,
-- so it is unit tested. Received data is escaped again here as a second line of defence.
local ViewModel = {}

local L = ns.L

-- "|" starts colour codes, links and textures in the client's text renderer.
function ViewModel.Escape(text)
  return (tostring(text):gsub("|", "||"))
end

-- How the states that the lists show are written (event status, attendance, session status, loot response,
-- readiness). The code keeps comparing and sending the English words; only what is shown changes.
local WORDS = ns.Locale.Table(function()
  return {
    planned = L("planned"),
    open = L("open"),
    closed = L("closed"),
    cancelled = L("cancelled"),
    invited = L("invited"),
    confirmed = L("confirmed"),
    present = L("present"),
    late = L("late"),
    leftEarly = L("leftEarly"),
    absent = L("absent"),
    excused = L("excused"),
    unknown = L("unknown"),
    met = L("met"),
    missing = L("missing"),
    waived = L("waived"),
    main = L("main"),
    off = L("off"),
    other = L("other"),
    gm = L("Guild master"),
    cogm = L("Co-guild master"),
    officer = L("Officer"),
    rl = L("Raid leader"),
    roster = L("Roster"),
    member = L("Member"),
    alter = L("Alter"),
  }
end)

function ViewModel.Word(value)
  return WORDS[value] or value
end

-- Why a declared profile field was not saved.
ViewModel.PROFILE_SET_ERRORS = ns.Locale.Table(function()
  return {
    unknown_field = L("unknown field. Allowed: role, role2, main, notes."),
    too_long = L("value is too long."),
    invalid_value = L("invalid value."),
  }
end)

-- Why the PvP counters of a member could not be reset (Comm:ResetPvP).
ViewModel.PVP_RESET_ERRORS = ns.Locale.Table(function()
  return {
    forbidden = L("only an admin can reset PvP counters."),
    stale = L("that member was already reset (or a later reset is known)."),
    limit = L("too many resets are remembered."),
    bad_target = L("that is not a valid member name."),
  }
end)

local PUBLISH_ERRORS = ns.Locale.Table(function()
  return {
    missing_data = L("class or level is unknown, nothing to share yet."),
    cooldown = L("you published a moment ago, wait a little."),
    full = L("the send queue is full, try again shortly."),
    too_large = L("the profile is too large to send."),
    encode_failed = L("the profile could not be encoded."),
  }
end)

function ViewModel.PublishError(reason)
  return PUBLISH_ERRORS[reason] or tostring(reason)
end

-- The sub-tabs of the Raid tab for a role (ViewModel.RaidActions): everyone gets the summary, and each
-- group of controls gets its own tab only when the role may use it.
function ViewModel.RaidSubTabs(actions)
  local tabs = { { value = "summary", text = L("Summary") } }
  if actions.events then
    tabs[#tabs + 1] = { value = "details", text = L("Details") }
  end
  if actions.attendance then
    tabs[#tabs + 1] = { value = "attendance", text = L("Attendance") }
  end
  if actions.assignments then
    tabs[#tabs + 1] = { value = "assignments", text = L("Assignments") }
    tabs[#tabs + 1] = { value = "templates", text = L("Templates") }
  end
  tabs[#tabs + 1] = { value = "reports", text = L("Reports") }
  return tabs
end

-- "Rank: Knight (512 honourable kills) - 288 to Knight-Lieutenant", or the top rank, or no rank yet.
function ViewModel.PvPRankLine(kills, ranks)
  local rank = ns.PvPService.RankFor(kills, ranks)
  local current = rank.name and L("%s (%d honourable kills)"):format(rank.name, kills) or L("none yet")
  if rank.next then
    return L("Rank: %s - %d to %s"):format(current, rank.next.remaining, rank.next.name)
  end
  if rank.name then
    return L("Rank: %s, the highest rank"):format(current)
  end
  return L("Rank: none (no ranks are configured)")
end

-- `honor` and `blows` are the counters shown (all time or today); `rankKills` is the all-time total of
-- honourable kills, because the rank never depends on the period shown.
local function rankRow(name, honor, blows, rankKills, updatedAt, mine, options, ranks)
  local total = honor.world + honor.bg
  local rank = ns.PvPService.RankFor(rankKills, ranks)
  return {
    name = name,
    label = ViewModel.Escape(name),
    rank = ViewModel.Escape(rank.name or "-"),
    rankIndex = rank.index or 0,
    rankKills = rankKills,
    world = honor.world,
    bg = honor.bg,
    total = total,
    blows = blows and (blows.world + blows.bg) or nil,
    updatedAt = updatedAt,
    updated = (mine and L("now")) or (updatedAt and options.now and ViewModel.AgeText(
      math.max(0, options.now - updatedAt)
    )) or "-",
    mine = mine,
  }
end

local PVP_SORT_KEYS = { name = true, rank = true, world = true, bg = true, total = true, blows = true, updated = true }
-- The columns that sort highest first on the first click.
ViewModel.PVP_FIRST_DESCENDING = { rank = true, world = true, bg = true, total = true, blows = true, updated = true }

local function validPair(pair)
  return type(pair) == "table" and type(pair.world) == "number" and type(pair.bg) == "number"
end

local ZERO_PAIR = { world = 0, bg = 0 }

-- Today's counters of a received record: its `today` block when it is for `day`, else zeros (the member has not
-- sent anything today). Killing blows stay nil when the member never sent any.
local function todayOf(record, day, hasBlows)
  local block = record.today
  if type(block) ~= "table" or block.day ~= day or type(day) ~= "string" or not validPair(block.honor) then
    return ZERO_PAIR, hasBlows and ZERO_PAIR or nil
  end
  local blows = validPair(block.blows) and block.blows or (hasBlows and ZERO_PAIR or nil)
  return block.honor, blows
end

-- The guild ranking of the PvP tab: one row per member with counters, most honourable kills first. `records` is
-- db.global.pvpStats (received); `options`:
--   own = { name, stats }     this character, always listed, from the local counters (not from the synced copy)
--   rosterNames               set of the names in the guild roster now; received records of anyone else are hidden
--   ranks                     default Constants.PVP_RANKS
--   blowsAvailable            this client reads killing blows (the own row has them)
--   now                       server time, for the "last update" text
--   period                    "total" (default) or "today": which counters the columns show; the rank is always
--                             the all-time one
--   day                       today as "YYYY-MM-DD" (server date), for period "today": a record whose day is
--                             another one counts as zero
--   sort = { key, descending }  key: "name" | "rank" | "world" | "bg" | "total" | "blows" | "updated"
--                             (default: total, highest first). Ties fall back to the name.
-- Returns the rows and { blows = boolean }: the killing blows column is only worth showing when this client reads
-- them or somebody sent them. Text is escaped.
function ViewModel.PvPRanking(records, options)
  local ranks = options.ranks or ns.Constants.PVP_RANKS
  local roster = options.rosterNames or {}
  local own = options.own
  local today = options.period == "today"
  local rows = {}

  for name, record in pairs(records or {}) do
    if type(name) == "string" and roster[name] and not (own and own.name == name) then
      if type(record) == "table" and validPair(record.honor) then
        local blows = validPair(record.blows) and record.blows or nil
        local updatedAt = type(record.updatedAt) == "number" and record.updatedAt or nil
        local rankKills = record.honor.world + record.honor.bg
        local honor = record.honor
        if today then
          honor, blows = todayOf(record, options.day, blows ~= nil)
        end
        rows[#rows + 1] = rankRow(name, honor, blows, rankKills, updatedAt, false, options, ranks)
      end
    end
  end
  if own then
    local totals = ns.PvPService.Totals(own.stats)
    local shown = today and ns.PvPService.Today(own.stats, options.day) or totals
    local blows = options.blowsAvailable and shown.blows or nil
    rows[#rows + 1] = rankRow(own.name, shown.honor, blows, totals.honor.total, nil, true, options, ranks)
  end

  local showBlows = options.blowsAvailable and true or false
  for _, row in ipairs(rows) do
    showBlows = showBlows or row.blows ~= nil
  end

  local sort = options.sort or { key = "total", descending = true }
  local key, descending = sort.key, sort.descending
  if not PVP_SORT_KEYS[key] then
    key, descending = "total", true
  end
  table.sort(rows, function(a, b)
    local left, right
    if key == "name" then
      left, right = a.name:lower(), b.name:lower()
    elseif key == "rank" then
      left, right = a.rankKills, b.rankKills
    elseif key == "world" or key == "bg" or key == "total" then
      left, right = a[key], b[key]
    elseif key == "blows" then
      left, right = a.blows or -1, b.blows or -1
    else -- "updated"
      -- The own row is the freshest there is.
      left, right = a.mine and math.huge or (a.updatedAt or -1), b.mine and math.huge or (b.updatedAt or -1)
    end
    if left ~= right then
      if descending then
        return left > right
      end
      return left < right
    end
    return a.name < b.name
  end)
  return rows, { blows = showBlows }
end

ViewModel.EVENT_STATUSES = { "planned", "open", "closed", "cancelled" }
ViewModel.ATTENDANCE_STATES = { "invited", "confirmed", "present", "late", "leftEarly", "absent", "excused", "unknown" }

-- What the Raid tab offers a role. These are the same checks the commands make (EventService repeats
-- them on every change), so a hidden control is never the only thing standing between a member and a change.
function ViewModel.RaidActions(role)
  local can = ns.PermissionService.Can
  return {
    events = can(role, "raid_manage"),
    attendance = can(role, "raid_manage"),
    assignments = can(role, "raid_manage"),
  }
end

-- The attendance tab: who is already recorded for the event (sorted, with their state), and, for a typed
-- `filter` (case-insensitive part of a name), the members of `memberNames` not recorded yet that match, cut at
-- `limit`. Nothing is listed for an empty filter, so a guild of hundreds never turns into hundreds of rows.
-- Returns recorded = { { name, label, state } }, matches = { { name, label } } and how many matched before the cut.
function ViewModel.AttendanceView(event, memberNames, filter, limit)
  local recorded = {}
  for name, record in pairs(event.attendance) do
    recorded[#recorded + 1] = { name = name, label = ViewModel.Escape(name), state = record.state }
  end
  table.sort(recorded, function(a, b)
    return a.name < b.name
  end)

  local matches, matched = {}, 0
  local needle = (filter or ""):lower()
  if needle ~= "" then
    local names = {}
    for _, name in ipairs(memberNames) do
      names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
      if not event.attendance[name] and name:lower():find(needle, 1, true) then
        matched = matched + 1
        if matched <= limit then
          matches[#matches + 1] = { name = name, label = ViewModel.Escape(name) }
        end
      end
    end
  end
  return recorded, matches, matched
end

-- Does `role` have `action` on an event of `eventRosterId`? gm and cogm on any roster; the others on their own roster
-- (an event no roster owns counts, as RosterService.MayAct does). Without an event it asks whether the role has the
-- action on some roster.
local function allowedOn(role, action, ownRosterId, event)
  local scope = ns.PermissionService.Scope(role, action, ownRosterId)
  if scope == "all" then
    return true
  elseif scope == "own" then
    return event == nil or event.rosterId == nil or event.rosterId == ownRosterId
  end
  return false
end

-- What the Loot tab offers a role on an event (nil: on some roster): the same checks as the commands (LootService
-- repeats them on every change). `apply` is the apply row of the tab, which the roster rank never gets: a roster
-- player applies only from the popup.
function ViewModel.LootActions(role, ownRosterId, event)
  local manage = allowedOn(role, "loot_manage", ownRosterId, event)
  return {
    open = manage,
    apply = manage and allowedOn(role, "loot_apply", ownRosterId, event),
    vote = manage,
    award = manage,
  }
end

ViewModel.LOOT_NEEDS = { "main", "off", "other" }

-- What a player may set by hand on a readiness item (ReadinessService.SetManual accepts the same four).
ViewModel.READY_STATUSES = { "met", "missing", "waived", "unknown" }

ViewModel.READY_SET_ERRORS = ns.Locale.Table(function()
  return {
    unknown_rule = L("unknown item."),
    not_manual = L("that item is measured automatically and cannot be set by hand."),
    invalid_status = L("status must be met, missing, waived or unknown."),
  }
end)

-- The event to put first in the minimap tooltip: among the planned or open events, the one starting soonest that
-- has not started yet (an open event is kept even after its start); undated ones come last. nil when none.
function ViewModel.NextEvent(events, now)
  local best, undated
  for _, event in ipairs(ns.EventService.List({ events = events })) do
    local active = event.status == "planned" or event.status == "open"
    local upcoming = event.startAt == nil or event.startAt >= now or event.status == "open"
    if active and upcoming then
      if not event.startAt then
        undated = undated or event
      elseif not best or event.startAt < best.startAt then
        best = event
      end
    end
  end
  return best or undated
end

-- What a command returned (a list of lines) as a banner: the kind (a failure is "danger", a change that was saved here
-- but could not be sent is "warning", anything else is "success") and the text, escaped.
function ViewModel.ReportBanner(lines)
  local kind = "success"
  if ns.Validate.IsFailure(lines) then
    kind = "danger"
  elseif lines[2] then
    kind = "warning"
  end
  local parts = {}
  for _, line in ipairs(lines) do
    parts[#parts + 1] = ViewModel.Escape(line)
  end
  return kind, table.concat(parts, " ")
end

-- Lines for the minimap tooltip. It reads only what the addon already holds: no game API is called, so it is
-- safe during an encounter lockdown.
-- args: events, now, formatDate(timestamp), readinessText, pending (queued messages), paused (queue held back)
function ViewModel.MinimapTooltip(args)
  local lines = {}
  local event = ViewModel.NextEvent(args.events, args.now)
  if event then
    local when = event.startAt and (" - " .. args.formatDate(event.startAt)) or ""
    lines[#lines + 1] = L("Next event: %s%s"):format(ViewModel.Escape(event.title), when)
  else
    lines[#lines + 1] = L("Next event: none planned")
  end
  lines[#lines + 1] = L("Readiness: ") .. args.readinessText
  if args.pending == 0 then
    lines[#lines + 1] = L("Sync queue: empty")
  else
    local held = args.paused and L(" (held back: encounter in progress)") or ""
    lines[#lines + 1] = L("Sync queue: %d message(s) waiting%s"):format(args.pending, held)
  end
  return lines
end

-- Right-click menu of the minimap button: a shortcut to each tab. There is no sync entry: sync is automatic.
function ViewModel.MinimapMenu(role, rosterId)
  local entries = {}
  for _, tab in ipairs(ViewModel.TabsFor(role, rosterId)) do
    entries[#entries + 1] = { text = tab.text, icon = tab.icon, action = "tab", value = tab.value }
  end
  entries[#entries + 1] = { text = L("Intel"), icon = "search", action = "intel", value = "@intel" }
  entries[#entries + 1] = { text = L("Settings"), icon = "gear", action = "settings", value = "@settings" }
  return entries
end

ViewModel.SYNC_REQUEST_ERRORS = ns.Locale.Table(function()
  return {
    cooldown = L("you asked a moment ago, wait a little."),
    full = L("the send queue is full, try again shortly."),
  }
end)

-- The line to print after asking the guild for the latest raid data.
function ViewModel.SyncRequestResult(ok, reason)
  if ok then
    return L("asked the guild for the latest raid data; leaders answer by whisper.")
  end
  return L("not requested: ") .. (ViewModel.SYNC_REQUEST_ERRORS[reason] or tostring(reason))
end

-- Lines for the minimap tooltip when the silent self test found failures (Diagnostics.Failures).
function ViewModel.SelfTestFailures(failures)
  local lines = { L("Self test: %d check(s) failed"):format(#failures) }
  for _, entry in ipairs(failures) do
    local detail = entry.detail and (" - " .. ViewModel.Escape(entry.detail)) or ""
    lines[#lines + 1] = ("  [%s] %s%s"):format(ViewModel.Escape(entry.status), ViewModel.Escape(entry.name), detail)
  end
  lines[#lines + 1] = L("Type /nrage debug selftest for the full result.")
  return lines
end

-- The loot sessions waiting for an answer from `actor`: open, no candidacy of theirs yet, and not passed on or
-- dismissed (`dismissed[sessionId] = true`). Sorted by event title, item name, then id so the popup is stable.
-- Only the sessions `role` may apply to (loot_apply on the roster of the event, `ownRosterId` being the roster of the
-- actor) are returned: nothing for a member or an alter, nor for another roster's session.
-- Returns { eventId, sessionId, eventTitle, itemName } entries, text unescaped (escape when drawing).
function ViewModel.PendingLoot(events, actor, dismissed, role, ownRosterId)
  local pending = {}
  for _, event in pairs(events) do
    if allowedOn(role, "loot_apply", ownRosterId, event) then
      for _, session in ipairs(ns.LootService.Sessions(event)) do
        if session.status == "open" and not session.candidates[actor] and not dismissed[session.sessionId] then
          pending[#pending + 1] = {
            eventId = event.eventId,
            sessionId = session.sessionId,
            eventTitle = event.title,
            itemId = session.itemId,
            itemName = session.itemName,
          }
        end
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

ViewModel.LOOT_NEED_LABELS = ns.Locale.Table(function()
  return { main = L("Main spec"), off = L("Off spec"), other = L("Other") }
end)

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
          itemId = session.itemId,
          itemName = ViewModel.Escape(session.itemName),
          eventTitle = ViewModel.Escape(event.title),
          candidates = ViewModel.CountKeys(session.candidates),
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

function ViewModel.CountKeys(tbl)
  local count = 0
  for _ in pairs(tbl or {}) do
    count = count + 1
  end
  return count
end

-- One line on where a session stands.
function ViewModel.VotingStatus(session)
  if session.award then
    return L("Awarded to %s by %s: %s"):format(
      ViewModel.Escape(session.award.characterKey),
      ViewModel.Escape(session.award.awardedBy),
      ViewModel.Escape(session.award.reason)
    )
  end
  if session.status == "closed" then
    return L("Closed without an award")
  end
  local candidates, votes = 0, 0
  for _ in pairs(session.candidates) do
    candidates = candidates + 1
  end
  for _ in pairs(session.votes) do
    votes = votes + 1
  end
  return L("Voting is open: %d candidate(s), %d vote(s) cast"):format(candidates, votes)
end

-- "ilvl 213 - Two-Hand" from Platform.GetItemDetails, or nil when the client told us nothing.
function ViewModel.ItemDetailsLine(details)
  if not details then
    return nil
  end
  local parts = {}
  if details.level then
    parts[#parts + 1] = L("ilvl %d"):format(details.level)
  end
  if details.slot then
    parts[#parts + 1] = ViewModel.Escape(details.slot)
  end
  return #parts > 0 and table.concat(parts, " - ") or nil
end

-- The items `name` has won, newest first: { itemName, eventTitle, reason } (not escaped). `limit` caps the list.
-- Read from the awards already stored, so it shows exactly what this client knows.
function ViewModel.WonItems(events, name, limit)
  local won = {}
  for _, event in pairs(events) do
    for _, session in pairs(event.loot or {}) do
      local award = session.award
      if award and award.characterKey == name then
        won[#won + 1] = {
          itemName = session.itemName,
          eventTitle = event.title,
          reason = award.reason,
          at = award.at or 0,
        }
      end
    end
  end
  table.sort(won, function(a, b)
    if a.at ~= b.at then
      return a.at > b.at
    end
    return a.itemName < b.itemName
  end)
  while #won > limit do
    table.remove(won)
  end
  return won
end

ViewModel.VOTING_SORTS = { "name", "rank", "response", "votes" }

-- The sort after clicking the header `key`: the same column flips its direction, another column starts in its
-- natural one (votes high to low, the rest A to Z; `firstDescending` = set of keys that start high to low
-- instead, default only "votes"). `current` = { key, descending } or nil.
function ViewModel.NextSort(current, key, firstDescending)
  if current and current.key == key then
    return { key = key, descending = not current.descending }
  end
  return { key = key, descending = (firstDescending or { votes = true })[key] == true }
end

local NEED_ORDER = { main = 1, off = 2, other = 3 }

-- The table of the voting window: one row per candidate. `votes` is nil while the visibility policy hides
-- them. `mine` marks the candidate `actor` voted for. `rankOf(name)` gives the guild rank name or nil. Text is
-- escaped. `options` (all optional): sort = { key = "name"|"rank"|"response"|"votes", descending = boolean }
-- (default: most votes first), need = "main"|"off"|"other" to show only that response. Ties fall back to the
-- name, and sorting by votes falls back to the name while they are hidden.
function ViewModel.VotingRows(session, actor, rankOf, options)
  options = options or {}
  local counts = {}
  local visible = ns.LootService.VotesVisible(session)
  for _, entry in ipairs(ns.LootService.Tally(session)) do
    counts[entry.characterKey] = entry.count
  end
  local myVote = session.votes[actor] and session.votes[actor].target

  local rows = {}
  for name, candidate in pairs(session.candidates) do
    if not options.need or candidate.need == options.need then
      local rank = rankOf(name)
      rows[#rows + 1] = {
        name = name,
        label = ViewModel.Escape(name),
        rank = ViewModel.Escape(rank or "?"),
        need = candidate.need,
        spec = ViewModel.Escape(candidate.spec),
        response = ("%s (%s)"):format(
          ViewModel.Escape(ViewModel.LOOT_NEED_LABELS[candidate.need] or candidate.need),
          ViewModel.Escape(candidate.spec)
        ),
        upgrade = candidate.upgrade and ViewModel.Escape(candidate.upgrade) or "",
        votes = visible and (counts[name] or 0) or nil,
        mine = myVote == name,
        sortRank = (rank or ""):lower(),
        sortResponse = ("%d %s"):format(NEED_ORDER[candidate.need] or 9, candidate.spec:lower()),
      }
    end
  end

  local sort = options.sort or { key = "votes", descending = true }
  local key, descending = sort.key, sort.descending
  if key == "votes" and not visible then
    key, descending = "name", false
  end
  table.sort(rows, function(a, b)
    local left, right
    if key == "votes" then
      left, right = a.votes, b.votes
    elseif key == "rank" then
      left, right = a.sortRank, b.sortRank
    elseif key == "response" then
      left, right = a.sortResponse, b.sortResponse
    else
      left, right = a.name:lower(), b.name:lower()
    end
    if left ~= right then
      if descending then
        return left > right
      end
      return left < right
    end
    return a.name < b.name
  end)
  return rows
end

-- What the group alert says about a match of BlacklistService.Match. An approximate match is a guess: the client
-- gives only the first word of a multi-word name.
function ViewModel.BlacklistAlertLine(match)
  local reason = ViewModel.Escape(match.entry.reason)
  if match.approximate then
    return L("%s may be %s, who is on the blacklist: %s"):format(
      ViewModel.Escape(match.member),
      ViewModel.Escape(match.entry.name),
      reason
    )
  end
  return L("%s is on the blacklist: %s"):format(ViewModel.Escape(match.entry.name), reason)
end

-- The tabs of the window with the icon and the sidebar group of each ("guild" or "admin"). Profile, Layers and
-- Blacklist are not listed: their files and services stay, they only left the sidebar (plan 0.1). The text is
-- translated again when the language changes (Locale.Table).
ViewModel.TABS = ns.Locale.Table(function()
  return {
    { value = "home", text = L("Home"), icon = "home", group = "guild" },
    { value = "professions", text = L("Professions"), icon = "book", group = "guild" },
    { value = "events", text = L("Raid"), icon = "calendar", group = "guild" },
    { value = "ready", text = L("Raid check"), icon = "check-circle", group = "guild" },
    { value = "loot", text = L("Loot"), icon = "gem", group = "guild" },
    { value = "pvp", text = "PvP", icon = "swords", group = "guild" },
    { value = "groups", text = L("Groups"), icon = "users", group = "guild" },
    { value = "raid", text = L("Raid"), icon = "calendar", group = "admin" },
    { value = "rules", text = L("Roster rules"), icon = "list", group = "admin" },
    { value = "roster", text = L("Members"), icon = "users", group = "admin" },
    { value = "pvpadmin", text = "PvP", icon = "swords", group = "admin" },
  }
end)

-- The action whose scope decides who sees a tab; the tabs that are not listed are for everyone.
local TAB_ACTIONS = {
  events = "events_view",
  ready = "raidcheck_view",
  loot = "loot_view",
  raid = "raid_manage",
  rules = "rules_view",
  roster = "members_view",
  pvpadmin = "pvp_admin",
}

-- Does a player with `role` and the roster `rosterId` (nil without one) see `tab` (an entry of TABS)?
local function tabVisible(tab, role, rosterId)
  local permission = ns.PermissionService
  if tab.group == "admin" and permission.Scope(role, "admin_view", rosterId) == "none" then
    return false
  end
  local action = TAB_ACTIONS[tab.value]
  return action == nil or permission.Scope(role, action, rosterId) ~= "none"
end

-- The tabs a player with `role` and the roster `rosterId` (nil without one) sees: the single gate of the sidebar, the
-- minimap menu and UI.OpenTab.
function ViewModel.TabsFor(role, rosterId)
  local tabs = {}
  for _, tab in ipairs(ViewModel.TABS) do
    if tabVisible(tab, role, rosterId) then
      tabs[#tabs + 1] = tab
    end
  end
  return tabs
end

-- Is `value` a tab this player sees? (false for a hidden tab or an unknown value)
function ViewModel.TabVisible(value, role, rosterId)
  for _, tab in ipairs(ViewModel.TabsFor(role, rosterId)) do
    if tab.value == value then
      return true
    end
  end
  return false
end

-- The kinds of rule an admin can add, in the order of the dropdown, and what each one needs typed in "Details".
ViewModel.RULE_CHECKS = { "level", "ilvl", "enchants", "buff", "profession", "field", "confirm" }
ViewModel.RULE_CHECK_TEXT = ns.Locale.Table(function()
  return {
    level = L("Minimum level"),
    ilvl = L("Minimum item level"),
    enchants = L("Enchanted slots"),
    buff = L("Active buff (flask, food...)"),
    profession = L("Profession"),
    field = L("Declared profile field"),
    confirm = L("Confirmed by hand"),
  }
end)
ViewModel.RULE_DETAIL_HINTS = ns.Locale.Table(function()
  return {
    level = L("a number, e.g. 60"),
    ilvl = L("a number, e.g. 60"),
    enchants = L("slots by name or number: mainhand, chest, back, 16"),
    buff = L("spell ids and/or names, separated by commas"),
    profession = L("name and minimum skill, e.g. Alchemy 300"),
    field = "role",
    confirm = L("nothing needed"),
  }
end)

-- Equipment slot names an admin may type instead of the number (the slots that can carry an enchant).
ViewModel.ENCHANT_SLOTS = {
  head = 1,
  shoulders = 3,
  chest = 5,
  wrist = 9,
  hands = 10,
  legs = 7,
  feet = 8,
  back = 15,
  mainhand = 16,
  offhand = 17,
  ranged = 18,
}

ViewModel.RULE_ERRORS = ns.Locale.Table(function()
  return {
    forbidden = L("only the guild master and the co-guild master can change the rules."),
    empty = L("keep at least one rule."),
    too_many = L("there is room for 30 rules at most."),
    bad_id = L("that rule name cannot be used."),
    bad_label = L("the name is empty, too long or has unsupported characters."),
    bad_category = L("that rule category cannot be used."),
    bad_check = L("that kind of rule is not supported."),
    bad_details = L("the details do not fit this kind of rule (see the hint under Details)."),
    duplicate_id = L("two rules would have the same name."),
    bad_rules = L("those rules are not valid."),
    last_rule = L("keep at least one rule; add another before removing this one."),
    unknown_rule = L("that rule no longer exists."),
  }
end)

local function trim(text)
  return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

local function splitList(text)
  local items = {}
  for piece in text:gmatch("[^,]+") do
    local item = trim(piece)
    if item ~= "" then
      items[#items + 1] = item
    end
  end
  return items
end

-- A name for the rule, from its label, that no other rule in `rules` has.
local function uniqueRuleId(label, rules)
  local base = label:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  base = base:sub(1, 24)
  if base == "" then
    base = "rule"
  end
  local taken = {}
  for _, rule in ipairs(rules) do
    taken[rule.id] = true
  end
  local id, counter = base, 1
  while taken[id] do
    counter = counter + 1
    id = base .. "_" .. counter
  end
  return id
end

-- Reads what the admin typed into the rule it describes. Returns the rule (already clean, ready to add to `rules`),
-- or nil plus a reason from RULE_ERRORS.
function ViewModel.RuleFromInput(check, label, details, rules)
  label, details = trim(label), trim(details)
  if label == "" then
    return nil, "bad_label"
  end
  local rule = { id = uniqueRuleId(label, rules), label = label, check = check }

  if check == "level" or check == "ilvl" then
    rule.min = tonumber(details)
  elseif check == "profession" then
    -- A skill number alone has no profession: it must not be saved as the profession's name.
    if details:match("^%d+$") then
      return nil, "bad_details"
    end
    local name, skill = details:match("^(.-)%s+(%d+)$")
    rule.profession = name or details
    rule.min = skill and tonumber(skill) or nil
  elseif check == "enchants" then
    rule.slots = {}
    for _, token in ipairs(splitList(details)) do
      local slot = tonumber(token) or ViewModel.ENCHANT_SLOTS[token:lower():gsub("%s", "")]
      if not slot then
        return nil, "bad_details"
      end
      rule.slots[#rule.slots + 1] = slot
    end
  elseif check == "buff" then
    for _, token in ipairs(splitList(details)) do
      local id = tonumber(token)
      local key = id and "spellIds" or "names"
      rule[key] = rule[key] or {}
      rule[key][#rule[key] + 1] = id or token
    end
  elseif check == "field" then
    rule.field = details:lower()
  end

  return ns.ReadinessRules.ValidateRule(rule)
end

-- A copy of `rules` with `rule` added, or without the rule called `id`.
function ViewModel.WithRule(rules, rule)
  local list = {}
  for index, existing in ipairs(rules) do
    list[index] = existing
  end
  list[#list + 1] = rule
  return list
end

-- Returns the new list, or nil plus "unknown_rule" | "last_rule".
function ViewModel.WithoutRule(rules, id)
  local list, found = {}, false
  for _, rule in ipairs(rules) do
    if rule.id == id then
      found = true
    else
      list[#list + 1] = rule
    end
  end
  if not found then
    return nil, "unknown_rule"
  end
  if #list == 0 then
    return nil, "last_rule"
  end
  return list
end

-- What a rule asks for, in a few words, for the list in the editor.
function ViewModel.RuleSummary(rule)
  local check = rule.check
  if check == "level" or check == "ilvl" then
    return L("%s %d or more"):format(check == "level" and L("level") or L("item level"), rule.min)
  elseif check == "profession" then
    return rule.min and L("%s %d or more"):format(rule.profession, rule.min) or rule.profession
  elseif check == "enchants" then
    return L("enchanted slots: ") .. table.concat(rule.slots, ", ")
  elseif check == "buff" then
    local parts = {}
    for _, id in ipairs(rule.spellIds or {}) do
      parts[#parts + 1] = tostring(id)
    end
    for _, name in ipairs(rule.names or {}) do
      parts[#parts + 1] = name
    end
    return L("any buff of: ") .. table.concat(parts, ", ")
  elseif check == "field" then
    return L("declared: ") .. rule.field
  end
  return L("confirmed by the player")
end

-- The count on the Groups item of the sidebar: a text, or nil when there is nothing to count.
function ViewModel.GroupsBadge(count)
  if type(count) ~= "number" or count <= 0 then
    return nil
  end
  return count > 99 and "99+" or tostring(math.floor(count))
end

-- The sidebar: the groups Guild and Admin, each with its { value, text, icon } items, for a player with `role` and the
-- roster `rosterId`. A group without items is left out. `openGroups` (optional) is the number of open groups of the
-- board: the Groups item gets it as `badge`; no other item has one.
function ViewModel.NavGroups(role, rosterId, openGroups)
  local groups = {
    { label = L("Guild"), items = {} },
    { label = L("Admin"), items = {} },
  }
  local index = { guild = 1, admin = 2 }
  for _, tab in ipairs(ViewModel.TabsFor(role, rosterId)) do
    local group = groups[index[tab.group] or 1]
    local item = { value = tab.value, text = tab.text, icon = tab.icon }
    if tab.value == "groups" then
      item.badge = ViewModel.GroupsBadge(openGroups)
    end
    group.items[#group.items + 1] = item
  end
  local result = {}
  for _, group in ipairs(groups) do
    if #group.items > 0 then
      result[#result + 1] = group
    end
  end
  return result
end

-- The roster selector shared by the tabs that show one roster at a time (plan 2.2). `action` is the view action of the
-- tab: the selector is visible when the role has it on every roster, otherwise the roster is the player's own and
-- only its name is shown. `rosters` = db.global.rosters, `selected` = what the player picked in this tab (or nil).
-- Returns { visible, options = { { value, text } }, selected = a roster id or nil, label = the name of the own roster
-- (when the selector is not visible) }. The default selection is the own roster, else the first by name.
function ViewModel.RosterSelector(role, action, ownRosterId, rosters, selected)
  local scope = ns.PermissionService.Scope(role, action, ownRosterId)
  if scope ~= "all" then
    local own = scope == "own" and rosters[ownRosterId] and ownRosterId or nil
    return {
      visible = false,
      options = {},
      selected = own,
      label = own and ViewModel.Escape(rosters[own].name) or nil,
    }
  end
  local options = {}
  for _, roster in ipairs(ns.RosterService.List(rosters)) do
    options[#options + 1] = { value = roster.id, text = ViewModel.Escape(roster.name) }
  end
  local chosen
  if selected ~= nil and rosters[selected] then
    chosen = selected
  elseif ownRosterId ~= nil and rosters[ownRosterId] then
    chosen = ownRosterId
  elseif options[1] then
    chosen = options[1].value
  end
  return { visible = #options > 0, options = options, selected = chosen }
end

-- How many players answered "yes" to an event (old events have no sign-up table).
function ViewModel.GoingCount(event)
  local count = 0
  for _, record in pairs(event.signups or {}) do
    if record.status == "yes" then
      count = count + 1
    end
  end
  return count
end

-- The answer of a player, as a word: "Going", "Not going", or "-" when they did not answer.
function ViewModel.SignupText(record)
  if record and record.status == "yes" then
    return L("Going")
  elseif record and record.status == "no" then
    return L("Not going")
  end
  return "-"
end

-- The upcoming events of the Raid tab of the Guild group, soonest first (undated last): `events` is what the viewer
-- sees (RosterService.FilterEvents). Rows: { eventId, title, dateText, rosterText, goingCount, goingText, answer,
-- canAnswer } with the name of the roster, or "Guild" for an event no roster owns. Past, closed and cancelled events
-- are left out. `own` = { key, role, rosterId } of the player: `answer` is their sign-up ("yes", "no" or nil) and
-- `canAnswer` tells whether they may change it now (their rank allows it and the sign-up is still open).
function ViewModel.UpcomingEventRows(events, now, rosters, own)
  local rows = ViewModel.EventListRows(events, { filter = "upcoming", now = now, rosters = rosters })
  local allowed = own ~= nil and ns.PermissionService.Scope(own.role, "event_signup", own.rosterId) ~= "none"
  for _, row in ipairs(rows) do
    local event = events[row.eventId]
    row.rosterText = row.rosterName or L("Guild")
    row.goingCount = ViewModel.GoingCount(event)
    row.goingText = L("%d going"):format(row.goingCount)
    local record = own and event.signups and event.signups[own.key]
    row.answer = record and record.status or nil
    row.canAnswer = allowed and ns.EventService.SignupOpen(event, now)
  end
  return rows
end

-- The user card at the bottom of the sidebar: the character name, and "rank - addon role" under it.
function ViewModel.UserCard(identityKey, rank, role)
  local name = tostring(identityKey or "?")
  local detail = {}
  if rank and rank ~= "" then
    detail[#detail + 1] = rank
  end
  detail[#detail + 1] = role and ViewModel.Word(role) or L("none")
  return { name = name, detail = table.concat(detail, " \194\183 ") }
end

-- The sync pill of the window header from Comm:StatusInfo(): { text, status } where status is a color token.
function ViewModel.SyncPill(info)
  if not info then
    return { text = L("Sync off"), status = "muted" }
  end
  if info.paused then
    return { text = L("Sync paused"), status = "warning" }
  end
  if info.queued > 0 then
    return { text = L("%d queued"):format(info.queued), status = "warning" }
  end
  return { text = L("Sync ready"), status = "success" }
end

function ViewModel.HelpLines()
  return {
    L("/nrage               open the window, where everything else is done"),
    L("/nrage help          this list"),
    L(
      "/nrage debug         diagnostics (debug selftest | info | identity | roster | senders | lockdown | pvp | layer)"
    ),
  }
end

ns.ViewModel = ViewModel
