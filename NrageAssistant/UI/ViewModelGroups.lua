local _, ns = ...

-- Rows for the Groups tab and the text of its popup (docs/LFG_PLAN.md 6): the board, the own post with its applicants,
-- the own application, the form to post or edit a group, and the count of the sidebar. Functions that return tables of
-- values, not frames, so every decision is tested here. Everything that was received (a title, a note, a name) goes
-- through ViewModel.Escape.
local ViewModel = ns.ViewModel
local L = ns.L
local Escape = ViewModel.Escape

local KIND_ORDER = { "dungeon", "quest", "other", "raid" }
local ROLE_ORDER = { "tank", "heal", "dps" }

ViewModel.GROUP_KINDS = ns.Locale.Table(function()
  return { dungeon = L("Dungeon"), quest = L("Quest"), other = L("Other"), raid = L("Raid") }
end)

local KIND_FILTER_TEXT = ns.Locale.Table(function()
  return { all = L("All"), dungeon = L("Dungeons"), quest = L("Quests"), other = L("Others"), raid = L("Raids") }
end)

ViewModel.GROUP_ROLES = ns.Locale.Table(function()
  return { tank = L("Tank"), heal = L("Heal"), dps = L("DPS") }
end)

local ROLE_FILTER_TEXT = ns.Locale.Table(function()
  return { all = L("Any role"), tank = L("Tank"), heal = L("Heal"), dps = L("DPS") }
end)

-- The line shown at the top of the screen when another member opens a group: "New group (Dungeon): title - leader".
-- The kind of a post as shown: "Dungeon", or "Raid 25" for a raid with its size. `fallback` is shown for a kind this
-- client does not know (nil: its escaped name).
function ViewModel.GroupKindText(post, fallback)
  if post.kind == "raid" and type(post.size) == "number" then
    return L("Raid %d"):format(post.size)
  end
  return ViewModel.GROUP_KINDS[post.kind] or fallback or Escape(tostring(post.kind))
end

function ViewModel.GroupAlertText(sender, post)
  local kind = ViewModel.GroupKindText(post, ViewModel.GROUP_KINDS.other)
  return L("New group (%s): %s - %s"):format(kind, Escape(tostring(post.title or "")), Escape(tostring(sender)))
end

-- Why something cannot be done now: shown beside a disabled button and after a click that was refused. Every reason
-- the service, the rules and the transport give has a text here.
ViewModel.GROUP_REASONS = ns.Locale.Table(function()
  return {
    locked = L("An encounter is in progress"),
    raid = L("You are in a raid"),
    not_leader = L("You do not lead your group"),
    full = L("Your group is full"),
    no_needs = L("Pick at least one role"),
    busy = L("You already have an application"),
    in_group = L("You are already in a group"),
    own_post = L("You have an open group"),
    level = L("Your level is too low"),
    role = L("That role is not needed"),
    no_post = L("That group is gone"),
    combat = L("You are in combat"),
    unknown_applicant = L("That applicant is gone"),
    no_application = L("You have no application"),
    bad_kind = L("Pick a type"),
    bad_size = L("Pick a raid size"),
    convert = L("Your party could not become a raid"),
    bad_title = L("The title is not valid"),
    bad_needs = L("The roles do not fit in the group"),
    bad_members = L("Your group size is not valid"),
    bad_level = L("The minimum level must be a number from 1 to 100"),
    bad_note = L("The note is not valid"),
    unavailable = L("This client cannot do that"),
    error = L("The client refused the action"),
  }
end)

function ViewModel.GroupReason(reason)
  local text = ViewModel.GROUP_REASONS[reason]
  if text then
    return text
  end
  return L("It could not be done (%s)"):format(Escape(tostring(reason)))
end

local function sameName(a, b)
  return type(a) == "string" and type(b) == "string" and ns.Validate.NameKey(a) == ns.Validate.NameKey(b)
end

-- "2:05" from seconds.
local function clock(seconds)
  seconds = math.max(0, math.ceil(seconds))
  return ("%d:%02d"):format(math.floor(seconds / 60), seconds % 60)
end

-- The needs as chips: "1 Tank", "2 DPS" (only the roles still needed).
local function needChips(needs)
  local chips = {}
  for _, role in ipairs(ROLE_ORDER) do
    if (needs[role] or 0) > 0 then
      chips[#chips + 1] = L("%d %s"):format(needs[role], ViewModel.GROUP_ROLES[role])
    end
  end
  return chips
end

-- The seats of a party, for Kit.Seats: the members first ({ filled, class, role } from `party`, the leader first; a
-- member the post does not describe has no class), then one seat per role still needed (tank, heal, dps), then the
-- free seats nobody is asked for. The tooltip says the same as text: the count, then a line per member. A raid (`size`)
-- has too many seats to draw: its list is nil and the third value is the count as text ("12/25").
local function seats(members, needs, party, size)
  local total = size or ns.Constants.LFG_PARTY_SIZE
  local filled = math.max(0, math.min(total, members or 1))
  local list, lines = {}, { L("%d of %d members"):format(filled, total) }
  if size then
    return nil, lines[1], ("%d/%d"):format(filled, total)
  end
  for index = 1, filled do
    local seat = type(party) == "table" and party[index] or nil
    local class = seat and seat.c or nil
    local role = seat and seat.r or nil
    list[#list + 1] = { filled = true, class = class, role = role }
    if class then
      local text = ns.IntelModel.ClassName(class)
      if role and ViewModel.GROUP_ROLES[role] then
        text = text .. " · " .. ViewModel.GROUP_ROLES[role]
      end
      lines[#lines + 1] = text
    end
  end
  for _, role in ipairs(ROLE_ORDER) do
    for _ = 1, (needs and needs[role] or 0) do
      if #list < total then
        list[#list + 1] = { filled = false, role = role }
      end
    end
  end
  while #list < total do
    list[#list + 1] = { filled = false }
  end
  return list, table.concat(lines, "\n")
end

local function filterItems(order, texts, current)
  local items = {}
  for _, value in ipairs(order) do
    items[#items + 1] = { value = value, text = texts[value], active = (current or "all") == value }
  end
  return items
end

-- The line of the Home card: how many groups are open.
function ViewModel.GroupsSummary(count)
  if count == 1 then
    return L("1 open group")
  elseif type(count) == "number" and count > 1 then
    return L("%d open groups"):format(count)
  end
  return L("No open groups")
end

---------------------------------------------------------------------------------------------------------------------
-- The own post
---------------------------------------------------------------------------------------------------------------------

local CLOSED_TEXT = ns.Locale.Table(function()
  return {
    full = L("Group complete"),
    cancelled = L("Group closed"),
    expired = L("Group expired"),
  }
end)

local function applicantRow(row, state)
  local view = {
    name = Escape(row.name),
    key = row.name,
    role = row.role,
    roleLabel = ViewModel.GROUP_ROLES[row.role] or Escape(tostring(row.role)),
    note = row.note and Escape(row.note) or "",
    state = row.state,
    pending = row.state == "pending",
    retry = row.state == "retry",
    invited = row.state == "invited",
    canInvite = row.state ~= "invited",
    inviteEnabled = state.inviteOk == true,
    inviteReason = state.inviteOk ~= true and ViewModel.GroupReason(state.inviteReason) or nil,
    declineEnabled = not state.locked,
  }
  if row.state == "invited" then
    view.stateText = L("Invitation sent...")
  elseif row.state == "retry" then
    view.stateText = L("Did not join")
  end
  return view
end

local function ownView(post, state)
  local seatsView, membersLabel, count = seats(post.members, post.needs, post.party, post.size)
  local view = {
    title = Escape(post.title),
    header = L("Your group · %s"):format(ViewModel.GroupKindText(post)),
    chips = needChips(post.needs),
    seats = seatsView,
    count = count,
    membersLabel = membersLabel,
    applicants = {},
    editEnabled = not state.locked,
    closeEnabled = not state.locked,
    waiting = #post.applicants == 0,
  }
  for _, row in ipairs(post.applicants) do
    view.applicants[#view.applicants + 1] = applicantRow(row, state)
  end
  if post.minLevel then
    view.levelText = L("Level %d+"):format(post.minLevel)
  end
  if post.note then
    view.note = Escape(post.note)
  end
  return view
end

---------------------------------------------------------------------------------------------------------------------
-- The own application
---------------------------------------------------------------------------------------------------------------------

-- { title, detail, status (a kit status), action = "withdraw" | "dismiss", actionText } for the own application.
local function applicationView(app, locked)
  local leader = Escape(app.leader)
  local title = Escape(app.title)
  local role = ViewModel.GROUP_ROLES[app.role] or Escape(tostring(app.role))
  local state = app.state
  local view = { enabled = not locked, action = "dismiss", actionText = L("Close"), status = "muted" }
  if state == "applied" then
    view.title = L("Application sent to %s"):format(leader)
    local detail = L("%s · as %s"):format(title, role)
    if app.left then
      detail = detail .. " · " .. L("expires in %s"):format(clock(app.left))
    end
    view.detail = detail
    view.status = "warning"
    view.action, view.actionText = "withdraw", L("Withdraw")
  elseif state == "invited" then
    view.title = L("%s invited you"):format(leader)
    view.detail = L("Accept the game invitation to join.")
    view.status = "warning"
    view.action, view.actionText = "withdraw", L("Withdraw")
  elseif state == "joined" then
    view.title = L("You are in the group of %s"):format(leader)
    view.detail = L("%s · as %s"):format(title, role)
    view.status = "success"
  elseif state == "declined" then
    view.title = L("%s declined your application"):format(leader)
    view.detail = title
    view.status = "danger"
  elseif state == "withdrawn" then
    view.title = L("You withdrew your application")
    view.detail = title
  elseif app.reason == "post_closed" then
    view.title = L("%s closed the group"):format(leader)
    view.detail = title
  else
    view.title = L("Your application expired")
    view.detail = L("%s · apply again if you still want to join."):format(title)
  end
  -- Closing a finished card is local: it works during a lockdown too.
  if view.action == "dismiss" then
    view.enabled = true
  end
  return view
end

---------------------------------------------------------------------------------------------------------------------
-- The tab
---------------------------------------------------------------------------------------------------------------------

-- The Groups tab. `state` = {
--   available (the service exists), locked, status = LfgService:Status(), posts = LfgBoard:Query(filter) (the open
--   posts, the own one included), filter = { kind, role }, ownName, canPost, postReason, canInvite, inviteReason,
--   canApply = function(pid) -> ok, reason }.
-- Returns { available, locked, newGroup = { enabled, reason }, own, closed, application, rows, kindFilters,
-- roleFilters, empty (text) } where each row is { pid, title, leader, needs, kindLabel, line, chips, seats,
-- membersLabel, cta, enabled, reason }.
function ViewModel.GroupsView(state)
  local view = { available = state.available ~= false, locked = state.locked == true, rows = {} }
  local filter = state.filter or {}
  view.kindFilters = filterItems({ "all", "dungeon", "quest", "other", "raid" }, KIND_FILTER_TEXT, filter.kind)
  view.roleFilters = filterItems({ "all", "tank", "heal", "dps" }, ROLE_FILTER_TEXT, filter.role)
  if not view.available then
    view.empty = L("Groups are not available yet.")
    view.newGroup = { enabled = false }
    return view
  end

  local status = state.status or {}
  local ctx = {
    locked = view.locked,
    inviteOk = state.canInvite == true,
    inviteReason = state.inviteReason,
  }
  if status.post then
    view.own = ownView(status.post, ctx)
  elseif status.closed then
    view.closed =
      { title = Escape(status.closed.title), text = CLOSED_TEXT[status.closed.outcome] or CLOSED_TEXT.cancelled }
  end
  if status.application then
    view.application = applicationView(status.application, view.locked)
  end

  local newGroup = { enabled = state.canPost == true }
  if status.post then
    newGroup = { enabled = false, reason = ViewModel.GroupReason("own_post") }
  elseif not newGroup.enabled then
    newGroup.reason = ViewModel.GroupReason(state.postReason)
  end
  view.newGroup = newGroup

  local applied = status.application
  for _, entry in ipairs(state.posts or {}) do
    if not sameName(entry.owner, state.ownName) then
      local parts = { L("Leader: %s"):format(Escape(entry.owner)) }
      if entry.minLevel then
        parts[#parts + 1] = L("Level %d+"):format(entry.minLevel)
      end
      parts[#parts + 1] = ViewModel.AgeText(entry.age)
      if entry.note then
        parts[#parts + 1] = Escape(entry.note)
      end
      local seatsView, membersLabel, count = seats(entry.members, entry.needs, entry.party, entry.size)
      local row = {
        pid = entry.pid,
        title = Escape(entry.title),
        leader = Escape(entry.owner),
        needs = { tank = entry.needs.tank, heal = entry.needs.heal, dps = entry.needs.dps },
        kindLabel = ViewModel.GroupKindText(entry),
        line = table.concat(parts, " · "),
        chips = needChips(entry.needs),
        seats = seatsView,
        count = count,
        membersLabel = membersLabel,
      }
      local active = applied and (applied.state == "applied" or applied.state == "invited")
      if active and applied.pid == entry.pid then
        row.cta, row.enabled, row.applied = L("Applied"), false, true
      else
        local ok, reason = state.canApply(entry.pid)
        row.cta, row.enabled = L("Apply"), ok == true
        if not row.enabled then
          row.reason = ViewModel.GroupReason(reason)
        end
      end
      view.rows[#view.rows + 1] = row
    end
  end
  if #view.rows == 0 then
    view.empty = L("No groups with these filters. Create yours.")
  end
  return view
end

-- The roles a post still needs, as { value, text } in display order, for the dialog of an application.
function ViewModel.GroupApplyRoles(needs)
  local roles = {}
  for _, role in ipairs(ROLE_ORDER) do
    if (needs[role] or 0) > 0 then
      roles[#roles + 1] = { value = role, text = ViewModel.GROUP_ROLES[role] }
    end
  end
  return roles
end

-- The role the dialog starts on: the first of `preferred` (the roles the player declared, as wire roles) that the post
-- needs, else the first role it needs.
function ViewModel.GroupDefaultRole(needs, preferred)
  for _, role in ipairs(preferred or {}) do
    if (needs[role] or 0) > 0 then
      return role
    end
  end
  local roles = ViewModel.GroupApplyRoles(needs)
  return roles[1] and roles[1].value or nil
end

---------------------------------------------------------------------------------------------------------------------
-- The form (new group and edit)
---------------------------------------------------------------------------------------------------------------------

-- The smallest raid size with a free seat for a group of `members`, else the largest.
local function raidSizeFor(members)
  local sizes = ns.Constants.LFG_RAID_SIZES
  for _, size in ipairs(sizes) do
    if size > members then
      return size
    end
  end
  return sizes[#sizes]
end

local function formSize(form)
  return form.kind == "raid" and form.size or ns.Constants.LFG_PARTY_SIZE
end

-- Changes the kind of the form `form` for a group of `members`. Moving between a party and a raid starts the roles
-- again, fitted to the new size; a raid starts at the smallest size with room.
function ViewModel.GroupFormSetKind(form, kind, members)
  members = math.max(1, members or 1)
  local wasRaid = form.kind == "raid"
  form.kind = kind
  if kind == "raid" then
    form.size = form.size or raidSizeFor(members)
  end
  if wasRaid ~= (kind == "raid") then
    form.needs = ns.LfgModel.DefaultNeeds(formSize(form), members)
  end
end

-- Changes the size of a raid form; the roles start again for that size.
function ViewModel.GroupFormSetSize(form, size, members)
  form.size = size
  form.needs = ns.LfgModel.DefaultNeeds(size, math.max(1, members or 1))
end

-- The form of a new group for a leader who already has `members` in the group (at least 1): the roles that fit. A
-- leader of a raid (`inRaid`) or of a full party starts with a raid.
function ViewModel.GroupFormNew(members, inRaid)
  members = math.max(1, members or 1)
  local form = { kind = "dungeon", title = "", min = "", note = "" }
  if inRaid or members >= ns.Constants.LFG_PARTY_SIZE then
    form.kind, form.size = "raid", raidSizeFor(members)
  end
  form.needs = ns.LfgModel.DefaultNeeds(formSize(form), members)
  if form.kind ~= "raid" then
    form.needs = ns.LfgModel.FitNeeds({ tank = 1, heal = 1, dps = 1 }, formSize(form) - members)
  end
  return form
end

-- The form of the own post `post` (LfgService:Status().post), to edit it.
function ViewModel.GroupFormFrom(post)
  return {
    kind = post.kind,
    size = post.size,
    title = post.title,
    needs = { tank = post.needs.tank, heal = post.needs.heal, dps = post.needs.dps },
    min = post.minLevel and tostring(post.minLevel) or "",
    note = post.note or "",
  }
end

local function trimmed(text)
  return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

-- The minimum level typed in: a number, nil for none, or false for an invalid text.
local function parseLevel(text)
  text = trimmed(text)
  if text == "" then
    return nil
  end
  if not text:match("^%d+$") then
    return false
  end
  local level = tonumber(text)
  if level < 1 or level > ns.Constants.LFG_LEVEL_MAX then
    return false
  end
  return level
end

-- What the form shows and what it would send. `form` = { kind, size (a raid), title, needs, min, note }; `options` =
-- { members (the group now, at least 1), edit (boolean), locked }.
-- Returns { heading, description, submitText, kinds = { { value, text, active } }, isRaid, sizes (a raid: { { value,
-- text, active } }), steppers = { { role, label, value, canDec, canInc } }, minError (text or nil), canSubmit, reason
-- (why not), fields (for LfgService:Post/Update) }.
function ViewModel.GroupFormView(form, options)
  options = options or {}
  local constants = ns.Constants
  local isRaid = form.kind == "raid"
  local size = formSize(form) or constants.LFG_PARTY_SIZE
  local room = size - math.max(1, options.members or 1)
  local total = form.needs.tank + form.needs.heal + form.needs.dps
  local view = {
    heading = options.edit and L("Edit group") or L("New group"),
    description = options.edit and L("Change what you are looking for. The roles are the seats still free.")
      or L("Say what you are going to do and who you need. The post only lasts while you are online."),
    submitText = options.edit and L("Save") or L("Post"),
    kinds = {},
    steppers = {},
    room = room,
    isRaid = isRaid,
  }
  if isRaid then
    view.sizes = {}
    for _, value in ipairs(constants.LFG_RAID_SIZES) do
      view.sizes[#view.sizes + 1] = { value = value, text = tostring(value), active = value == size }
    end
  end
  for _, kind in ipairs(KIND_ORDER) do
    view.kinds[#view.kinds + 1] = { value = kind, text = ViewModel.GROUP_KINDS[kind], active = form.kind == kind }
  end
  for _, role in ipairs(ROLE_ORDER) do
    view.steppers[#view.steppers + 1] = {
      role = role,
      label = ViewModel.GROUP_ROLES[role],
      value = form.needs[role],
      canDec = form.needs[role] > 0,
      canInc = total < room and form.needs[role] < size - 1,
    }
  end
  local level = parseLevel(form.min)
  if level == false then
    view.minError = ViewModel.GROUP_REASONS.bad_level
  end
  local title = trimmed(form.title)
  if room <= 0 then
    view.reason = ViewModel.GROUP_REASONS.full
  elseif title == "" then
    view.reason = ViewModel.GROUP_REASONS.bad_title
  elseif total == 0 then
    view.reason = ViewModel.GROUP_REASONS.no_needs
  elseif view.minError then
    view.reason = view.minError
  elseif options.locked then
    view.reason = ViewModel.GROUP_REASONS.locked
  end
  view.canSubmit = view.reason == nil
  view.fields = {
    kind = form.kind,
    size = isRaid and size or nil,
    title = title,
    needs = { tank = form.needs.tank, heal = form.needs.heal, dps = form.needs.dps },
    -- `false` clears the level of a post that is being edited.
    minLevel = level ~= nil and level or false,
    note = trimmed(form.note),
  }
  return view
end

---------------------------------------------------------------------------------------------------------------------
-- The popup
---------------------------------------------------------------------------------------------------------------------

local BUTTON_TEXT = ns.Locale.Table(function()
  return { invite = L("Invite"), decline = L("Decline"), close = L("Close") }
end)

local function buttons(...)
  local list = {}
  for _, id in ipairs({ ... }) do
    list[#list + 1] = { id = id, text = BUTTON_TEXT[id] }
  end
  return list
end

-- What the popup shows for `status` (LfgService:Status()), or nil when there is nothing to say. A leader sees the
-- oldest applicant who is waiting; an applicant sees that the leader accepted or declined. Returns { key, title, text,
-- buttons = { { id, text } }, target (the applicant's name, for the buttons), alert (a new applicant) }. `key`
-- changes when what is said changes, so the frame is not rebuilt for the same thing.
function ViewModel.LfgPopupView(status)
  if type(status) ~= "table" then
    return nil
  end
  local post = status.post
  if post then
    for _, row in ipairs(post.applicants) do
      if row.state == "pending" then
        local role = ViewModel.GROUP_ROLES[row.role] or Escape(tostring(row.role))
        return {
          key = table.concat({ "leader", post.pid, row.name, row.role }, "|"),
          title = L("New application"),
          text = L("%s wants to go as %s."):format(Escape(row.name), role),
          buttons = buttons("invite", "decline"),
          target = row.name,
          alert = true,
        }
      end
    end
  end
  local app = status.application
  if app and app.state == "invited" then
    return {
      key = table.concat({ "applicant", app.pid, app.state }, "|"),
      title = L("Application accepted"),
      text = L("%s invited you. Accept the game invitation to join."):format(Escape(app.leader)),
      buttons = buttons("close"),
    }
  elseif app and app.state == "declined" then
    return {
      key = table.concat({ "applicant", app.pid, app.state }, "|"),
      title = L("Application declined"),
      text = L("%s declined your application."):format(Escape(app.leader)),
      buttons = buttons("close"),
    }
  end
  return nil
end

---------------------------------------------------------------------------------------------------------------------
-- The Groups icon
---------------------------------------------------------------------------------------------------------------------

local ICON_LINES = 5

-- The roles a post still needs as labels in display order, e.g. "Tank, DPS". Empty when nothing is needed.
local function neededRoleText(needs)
  local labels = {}
  for _, role in ipairs(ROLE_ORDER) do
    if ((needs or {})[role] or 0) > 0 then
      labels[#labels + 1] = ViewModel.GROUP_ROLES[role]
    end
  end
  return table.concat(labels, ", ")
end

-- The badge on the icon: hidden for zero groups, the count from one to nine, then "9+".
local function badgeCount(count)
  if count <= 0 then
    return nil
  end

  if count > 9 then
    return "9+"
  end

  return tostring(count)
end

-- Whether the player can join `pid`. A missing or failing canApply means no.
local function canJoin(canApply, pid)
  if type(canApply) ~= "function" then
    return false
  end
  local ok, result = pcall(canApply, pid)
  return ok and result and true or false
end

-- The floating icon of the Groups module. `state` = { enabled (module on and board present),
-- posts = LfgBoard:Query() result (may be nil), ownName, canApply = function(pid) -> boolean }.
-- All open groups, including the player's own post, contribute to the badge and tooltip.
-- Returns { shown, count, countText, title, lines = { { text, joinable } } (at most five), more, hint }.
function ViewModel.GroupsIconView(state)
  state = state or {}
  local posts = {}

  -- Include every valid post so the badge reflects all open guild groups.
  for _, post in ipairs(type(state.posts) == "table" and state.posts or {}) do
    if type(post) == "table" then
      posts[#posts + 1] = post
    end
  end

  local count = #posts
  local lines = {}

  for index = 1, math.min(count, ICON_LINES) do
    local post = posts[index]
    local kind = ViewModel.GroupKindText(post, ViewModel.GROUP_KINDS.other)
    local text = L("%s: %s - %s"):format(kind, Escape(tostring(post.title or "")), Escape(tostring(post.owner or "")))
    local roles = neededRoleText(post.needs)

    if roles ~= "" then
      text = text .. " (" .. roles .. ")"
    end

    -- Own posts are listed but cannot be joined by their creator.
    local ownPost = sameName(post.owner, state.ownName)
    lines[#lines + 1] = {
      text = text,
      joinable = not ownPost and canJoin(state.canApply, post.pid),
    }
  end

  local more = nil
  if count > ICON_LINES then
    more = L("and %d more"):format(count - ICON_LINES)
  end

  return {
    shown = state.enabled == true and count > 0,
    count = count,
    countText = badgeCount(count),
    title = L("Open groups (%d)"):format(count),
    lines = lines,
    more = more,
    hint = L("Click to open Groups"),
    rightClickHint = L("Right click to change the icon"),
  }
end
