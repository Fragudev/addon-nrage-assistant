local _, ns = ...

-- Groups (docs/LFG_PLAN.md 6.1): the board of the guild's groups, your own post with its applicants, your own
-- application, and the form to post or edit a group. What to show (and the reason behind a disabled button) comes from
-- ViewModel.GroupsView and ViewModel.GroupFormView; every action is a call to ns.lfgService, which checks the rules
-- again. Open to every role: the board is shared with the guild only.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

-- What the tab remembers while the addon runs: filters, page, form draft and settings panel visibility.
local state = {
  kind = "all",
  role = "all",
  page = "board",
  edit = false,
  form = nil,
  settingsOpen = false,
}

local function service()
  return ns.lfgService
end

local function viewOf()
  local lfg, board = service(), ns.lfgBoard
  if not (lfg and board) then
    return ViewModel.GroupsView({ available = false, filter = state })
  end
  local canPost, postReason = lfg:CanPost()
  local canInvite, inviteReason = lfg:CanInvite()
  return ViewModel.GroupsView({
    available = true,
    locked = lfg:IsLocked(),
    status = lfg:Status(),
    posts = board:Query({
      kind = state.kind ~= "all" and state.kind or nil,
      role = state.role ~= "all" and state.role or nil,
    }),
    filter = state,
    ownName = ns.Platform.GetIdentityKey(),
    canPost = canPost,
    postReason = postReason,
    canInvite = canInvite,
    inviteReason = inviteReason,
    canApply = function(pid)
      return lfg:CanApply(pid)
    end,
  })
end

-- Runs a service call; a refusal is told in the banner, and the tab is drawn again either way.
local function act(call, ...)
  local ok, why = call(service(), ...)
  if not ok then
    UI.Notify("warning", ViewModel.GroupReason(why))
    return false
  end
  UI.Redraw()
  return true
end

local function labelButton(parent, text, onClick, opts)
  opts = opts or {}
  return Kit.Button(parent, {
    text = text,
    variant = opts.variant,
    disabled = opts.disabled,
    tooltip = opts.tooltip,
    layout = opts.layout or { width = "auto" },
    onClick = onClick,
  })
end

---------------------------------------------------------------------------------------------------------------------
-- The form
---------------------------------------------------------------------------------------------------------------------

local function ownMembers()
  return math.max(1, ns.Platform.GetGroupSize())
end

local function openForm(edit)
  local lfg = service()
  local post = lfg and lfg:Status().post
  if edit and post then
    state.form = ViewModel.GroupFormFrom(post)
  else
    edit = false
    state.form = ViewModel.GroupFormNew(ownMembers())
  end
  state.edit, state.page = edit, "form"
  UI.Redraw()
end

local function closeForm()
  state.page, state.form = "board", nil
  UI.Redraw()
end

-- The party the form is for: the one of the own post when editing it, else the one the player is in now.
local function formOptions(locked)
  local post = state.edit and service():Status().post
  return { members = post and post.members or ownMembers(), edit = state.edit, locked = locked }
end

local function submit()
  local lfg = service()
  local view = ViewModel.GroupFormView(state.form, formOptions(lfg:IsLocked()))
  if not view.canSubmit then
    UI.Notify("warning", view.reason)
    return
  end
  local ok, why
  if state.edit then
    ok, why = lfg:Update(view.fields)
  else
    ok, why = lfg:Post(view.fields)
  end
  if not ok then
    UI.Notify("warning", ViewModel.GroupReason(why))
    return
  end
  closeForm()
end

local function stepper(grid, step, form)
  local row = Kit.Row(grid, { gap = 8, align = "center" })
  Kit.Label(row, { text = step.label, color = "dim", layout = { weight = 1 } })
  Kit.Button(row, {
    text = "-",
    disabled = not step.canDec,
    layout = { width = 30 },
    onClick = function()
      form.needs[step.role] = form.needs[step.role] - 1
      UI.Redraw()
    end,
  })
  Kit.Label(row, { text = tostring(step.value), style = "value", align = "CENTER", layout = { width = 20 } })
  Kit.Button(row, {
    text = "+",
    disabled = not step.canInc,
    layout = { width = 30 },
    onClick = function()
      form.needs[step.role] = form.needs[step.role] + 1
      UI.Redraw()
    end,
  })
end

local function drawForm(page, locked)
  local form = state.form
  local view = ViewModel.GroupFormView(form, formOptions(locked))
  Kit.PageHeader(page, { title = view.heading, description = view.description })
  local card = Kit.Card(page, { gap = 14 })

  -- The post button follows what is typed, without drawing the page again (which would take the focus away).
  local post
  local function refreshSubmit()
    local now = ViewModel.GroupFormView(form, formOptions(service():IsLocked()))
    if post then
      post.opts.tooltip = now.reason
      post:SetDisabled(not now.canSubmit)
    end
  end

  local kind = Kit.Field(card, { label = L("Type") })
  Kit.Segmented(kind, {
    items = view.kinds,
    value = form.kind,
    onChange = function(value)
      form.kind = value
    end,
  })

  local title = Kit.Field(card, { label = L("Title") })
  Kit.EditBox(title, {
    text = form.title,
    placeholder = L("Deadmines"),
    maxLetters = ns.Constants.LFG_TITLE_MAX,
    onChange = function(text)
      form.title = text
      refreshSubmit()
    end,
  })

  local grid = Kit.Grid(card, { columns = 3, gap = 12 })
  for _, step in ipairs(view.steppers) do
    stepper(grid, step, form)
  end

  local row = Kit.Row(card, { gap = 12, align = "top" })
  local level =
    Kit.Field(row, { label = L("Minimum level · optional"), error = view.minError, layout = { width = 170 } })
  Kit.EditBox(level, {
    text = form.min,
    numeric = true,
    maxLetters = 3,
    error = view.minError ~= nil,
    onChange = function(text)
      form.min = text
      refreshSubmit()
    end,
    -- The error under the box appears once the player is done typing.
    onCommit = function()
      UI.Redraw()
    end,
  })
  local note = Kit.Field(row, { label = L("Note · optional"), layout = { weight = 1 } })
  Kit.EditBox(note, {
    text = form.note,
    maxLetters = ns.Constants.LFG_NOTE_MAX,
    onChange = function(text)
      form.note = text
    end,
  })

  local buttons = Kit.Row(card, { gap = 8, align = "center" })
  Kit.Label(buttons, { text = "", layout = { weight = 1 } })
  labelButton(buttons, L("Cancel"), closeForm)
  post = labelButton(buttons, view.submitText, submit, {
    variant = "primary",
    disabled = not view.canSubmit,
    tooltip = view.reason,
  })
end

---------------------------------------------------------------------------------------------------------------------
-- The dialog of an application
---------------------------------------------------------------------------------------------------------------------

local function declaredRoles()
  local fields = ns.character and ns.character.profile and ns.character.profile.fields or {}
  local roles = {}
  for _, key in ipairs({ "role", "role2" }) do
    local wire = fields[key] and ns.LfgModel.WireRole(fields[key].value)
    if wire then
      roles[#roles + 1] = wire
    end
  end
  return roles
end

local function openApply(row)
  local role = ViewModel.GroupDefaultRole(row.needs, declaredRoles())
  local note = ""
  Kit.Modal.Open({
    title = L("Join the group"),
    width = 360,
    build = function(stack)
      Kit.Label(stack, { text = row.title, style = "value", wrap = true })
      Kit.Label(stack, { text = L("Leader: %s"):format(row.leader), color = "dim" })
      local roleField = Kit.Field(stack, { label = L("You go as") })
      Kit.Segmented(roleField, {
        items = ViewModel.GroupApplyRoles(row.needs),
        value = role,
        onChange = function(value)
          role = value
        end,
      })
      local noteField = Kit.Field(stack, { label = L("Note · optional") })
      Kit.EditBox(noteField, {
        text = "",
        maxLetters = ns.Constants.LFG_NOTE_MAX,
        onChange = function(text)
          note = text
        end,
      })
      local buttons = Kit.Row(stack, { gap = 8, align = "center" })
      Kit.Label(buttons, { text = "", layout = { weight = 1 } })
      labelButton(buttons, L("Cancel"), Kit.Modal.Close)
      labelButton(buttons, L("Send"), function()
        Kit.CommitEdit()
        Kit.Modal.Close()
        act(service().Apply, row.pid, role, note)
      end, { variant = "primary" })
    end,
  })
end

---------------------------------------------------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------------------------------------------------

-- Draws the floating Groups icon preferences using the same controls as the rest of the addon.
-- The visibility preference is shared with the icon's right-click panel and slash commands.
local function drawSettings(page)
  local card = Kit.Card(page, {
    title = L("Groups icon"),
    gap = 10,
  })

  Kit.Switch(card, {
    label = L("Always show the Groups icon"),
    description = L("Keep the Groups icon visible even when no groups are open."),
    checked = ns.GroupsIcon.AlwaysShow(),
    onChange = function(enabled)
      ns.GroupsIcon.SetAlwaysShow(enabled)
      UI.Redraw()
    end,
  })
end

---------------------------------------------------------------------------------------------------------------------
-- The board
---------------------------------------------------------------------------------------------------------------------

local function chips(parent, list)
  local row = Kit.Row(parent, { gap = 6, align = "center", layout = { width = "auto" } })
  for _, text in ipairs(list) do
    Kit.Badge(row, { text = text, color = "info", layout = { width = "auto" } })
  end
  return row
end

local function seats(parent, data, label)
  return Kit.Seats(parent, { seats = data, tooltip = label, layout = { width = "auto" } })
end

local function ownCard(page, own)
  local card = Kit.Card(page, { title = own.header, highlight = true, gap = 10 })
  local head = Kit.Row(card, { gap = 14, align = "center" })
  Kit.Label(head, { text = own.title, style = "value", layout = { weight = 1 } })
  chips(head, own.chips)
  seats(head, own.seats, own.membersLabel)
  labelButton(head, L("Edit"), function()
    openForm(true)
  end, { disabled = not own.editEnabled })
  labelButton(head, L("Close group"), function()
    act(service().Close)
  end, { disabled = not own.closeEnabled })

  if own.waiting then
    Kit.Label(card, { text = L("Posted. Applications will show up here."), style = "small", color = "dim" })
    return
  end
  Kit.Divider(card, {})
  for _, applicant in ipairs(own.applicants) do
    local row = Kit.Row(card, { gap = 12, align = "center" })
    Kit.Label(row, { text = applicant.name, layout = { width = 120 } })
    Kit.Label(row, { text = applicant.roleLabel, color = "info", layout = { width = 50 } })
    Kit.Label(row, { text = applicant.note, color = "dim", layout = { weight = 1 } })
    if applicant.stateText then
      Kit.Label(row, { text = applicant.stateText, color = "warning", layout = { width = "auto" } })
    end
    if applicant.canInvite then
      labelButton(row, L("Invite"), function()
        act(service().Invite, applicant.key)
      end, { variant = "primary", disabled = not applicant.inviteEnabled, tooltip = applicant.inviteReason })
    end
    if applicant.pending or applicant.retry then
      labelButton(row, L("Decline"), function()
        act(service().Decline, applicant.key)
      end, { disabled = not applicant.declineEnabled })
    end
  end
end

local function closedCard(page, closed)
  local card = Kit.Card(page, { title = closed.title, gap = 10 })
  local row = Kit.Row(card, { gap = 12, align = "center" })
  Kit.Label(row, { text = closed.text, style = "value", color = "warning", layout = { weight = 1 } })
  labelButton(row, L("Remove"), function()
    act(service().Dismiss)
  end)
end

local function applicationCard(page, app)
  local card = Kit.Card(page, { highlight = true, gap = 8 })
  local row = Kit.Row(card, { gap = 12, align = "center" })
  Kit.Icon(row, { icon = "diamond", color = app.status, size = 12, layout = { width = 12 } })
  local text = Kit.Stack(row, { gap = 2, layout = { weight = 1 } })
  Kit.Label(text, { text = app.title, style = "smallMedium" })
  Kit.Label(text, { text = app.detail, style = "small", color = "dim" })
  labelButton(row, app.actionText, function()
    if app.action == "withdraw" then
      if service():Withdraw() then
        service():Dismiss()
      else
        UI.Notify("warning", ViewModel.GroupReason("locked"))
      end
      UI.Redraw()
    else
      act(service().Dismiss)
    end
  end, { disabled = not app.enabled })
end

local function filters(page, view)
  local bar = Kit.Row(page, { gap = 16, align = "center" })
  local function segmented(items, current, key)
    local list = {}
    for _, item in ipairs(items) do
      list[#list + 1] = { value = item.value, text = item.text }
    end
    Kit.Segmented(bar, {
      items = list,
      value = current,
      layout = { width = "auto" },
      onChange = function(value)
        state[key] = value
        UI.Redraw()
      end,
    })
  end
  segmented(view.kindFilters, state.kind, "kind")
  segmented(view.roleFilters, state.role, "role")
end

local function postCard(page, post)
  local card = Kit.Card(page, { gap = 6 })
  local row = Kit.Row(card, { gap = 14, align = "center" })
  local info = Kit.Stack(row, { gap = 3, layout = { weight = 1 } })
  local head = Kit.Row(info, { gap = 8, align = "center" })
  Kit.Label(head, { text = post.title, style = "value", layout = { weight = 1 } })
  Kit.Label(head, { text = post.kindLabel, style = "small", color = "muted", layout = { width = "auto" } })
  Kit.Label(info, { text = post.line, style = "small", color = "dim" })
  chips(row, post.chips)
  seats(row, post.seats, post.membersLabel)
  local action = Kit.Stack(row, { gap = 2, layout = { width = 130 } })
  labelButton(action, post.cta, function()
    openApply(post)
  end, { disabled = not post.enabled, layout = {} })
  if post.reason then
    Kit.Label(action, { text = post.reason, style = "tiny", color = "muted", align = "RIGHT", wrap = true })
  end
end

local function drawBoard(page, view)
  local head = Kit.Row(page, { gap = 12, align = "center" })

  Kit.PageHeader(head, {
    title = L("Groups"),
    description = L("Put together dungeons and quests with guild members."),
    layout = { weight = 1 },
  })

  -- Toggle the settings card without leaving the Groups board.
  Kit.Button(head, {
    text = state.settingsOpen and L("Hide settings") or L("Settings"),
    layout = { width = "auto" },
    onClick = function()
      state.settingsOpen = not state.settingsOpen
      UI.Redraw()
    end,
  })

  labelButton(head, L("New group"), function()
    openForm(false)
  end, {
    variant = "primary",
    disabled = not view.newGroup.enabled,
    tooltip = view.newGroup.reason,
  })

  -- Keep the icon settings above the board content, like PvP Intel.
  if state.settingsOpen then
    drawSettings(page)
  end

  if view.own then
    ownCard(page, view.own)
  elseif view.closed then
    closedCard(page, view.closed)
  end
  if view.application then
    applicationCard(page, view.application)
  end
  filters(page, view)
  for _, post in ipairs(view.rows) do
    postCard(page, post)
  end
  if view.empty then
    Kit.EmptyState(page, { icon = "users", title = view.empty })
  end
  Kit.Label(page, { text = L("Only members who use the addon appear."), style = "small", color = "muted" })
end

UI.Register("groups", function(page)
  -- Visiting the Groups tab acknowledges pending icon notifications.
  if ns.GroupsIcon then
    ns.GroupsIcon.AcknowledgeGlow()
  end

  local view = viewOf()
  if view.locked then
    Kit.Banner(page, { kind = "warning", text = L("Encounter in progress: nothing is sent until it ends.") })
  end
  if not view.available then
    Kit.PageHeader(page, {
      title = L("Groups"),
      description = L("Put together dungeons and quests with guild members."),
    })
    Kit.EmptyState(page, { icon = "users", title = view.empty })
    return
  end
  if state.page == "form" and state.form then
    drawForm(page, view.locked)
    return
  end
  drawBoard(page, view)
end)
