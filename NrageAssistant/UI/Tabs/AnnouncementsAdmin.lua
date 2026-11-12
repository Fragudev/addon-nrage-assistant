local _, ns = ...

-- Announcements editor (Admin group, gm and cogm only; docs/ANNOUNCEMENTS_MODULES_PVP_PLAN.md B.6): a form to
-- publish or change an announcement (title, text, "Send popup", "Pin", expiry) and the list of the existing ones with
-- Edit, Delete (two clicks) and "Send popup again". What to show comes from ViewModel.AnnouncementFormView and
-- ViewModel.AnnouncementAdminList; every action is a call to ns.announcements, which checks the role again.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

-- What the tab remembers while the addon runs: the draft of the form.
local state = { form = nil }

local function service()
  return ns.announcements
end

local function form()
  if not state.form then
    state.form = ViewModel.AnnouncementFormNew()
  end
  return state.form
end

local function now()
  return ns.Platform.ServerTime()
end

-- The fields the service takes from the form. While editing, the expiry is sent only when the player changed it, so
-- saving a text change does not push the expiry date forward.
local function fieldsOf(current)
  local fields = {
    title = current.title,
    body = current.body,
    popup = current.popup,
    pinned = current.pinned,
  }
  if not current.editing or current.expiry ~= current.originalExpiry then
    fields.expiry = current.expiry
  end
  return fields
end

local function submit()
  local current = form()
  local ok, why
  if current.editing then
    ok, why = service():Edit(current.editing, fieldsOf(current))
  else
    ok, why = service():Publish(fieldsOf(current))
  end
  if not ok then
    UI.Notify("warning", ViewModel.AnnouncementReason(why))
    return
  end
  state.form = nil
  UI.Notify("success", current.editing and L("Announcement saved.") or L("Announcement published."))
end

local function cancel()
  state.form = nil
  UI.Redraw()
end

local function counterLabel(parent, info)
  return Kit.Label(parent, { text = info.text, style = "small", color = info.token, align = "RIGHT" })
end

local function drawForm(page, full)
  local current = form()
  local view = ViewModel.AnnouncementFormView(current, full)
  local card = Kit.Card(page, { title = view.heading, gap = 12 })

  -- The button and the counters follow what is typed, without drawing the page again (which would take the focus away).
  local publish, titleCounter, bodyCounter
  local function refresh()
    local latest = ViewModel.AnnouncementFormView(current, service():Count() >= ns.Constants.ANNOUNCE_MAX)
    if publish then
      publish.opts.tooltip = latest.reason
      publish:SetDisabled(not latest.canSubmit)
    end
    if titleCounter then
      titleCounter:SetText(latest.titleCounter.text)
      titleCounter:SetColor(latest.titleCounter.token)
    end
    if bodyCounter then
      bodyCounter:SetText(latest.bodyCounter.text)
      bodyCounter:SetColor(latest.bodyCounter.token)
    end
  end

  local title = Kit.Field(card, { label = L("Title") })
  Kit.EditBox(title, {
    text = current.title,
    maxLetters = ns.Constants.ANNOUNCE_TITLE_MAX,
    onChange = function(text)
      current.title = text
      refresh()
    end,
  })
  titleCounter = counterLabel(title, view.titleCounter)

  local body = Kit.Field(card, { label = L("Text") })
  Kit.TextArea(body, {
    text = current.body,
    height = 120,
    onChange = function(text)
      current.body = text
      refresh()
    end,
  })
  bodyCounter = counterLabel(body, view.bodyCounter)

  Kit.Switch(card, {
    label = L("Send popup"),
    description = L("Every member gets a popup when this is published."),
    checked = current.popup,
    onChange = function(checked)
      current.popup = checked
    end,
  })
  Kit.Switch(card, {
    label = L("Pin"),
    description = L("Pinned announcements are listed first."),
    checked = current.pinned,
    onChange = function(checked)
      current.pinned = checked
    end,
  })
  local expiry = Kit.Field(card, { label = L("Expiry") })
  Kit.Dropdown(expiry, {
    items = view.expiryItems,
    value = current.expiry,
    layout = { width = 220 },
    onChange = function(value)
      current.expiry = value
    end,
  })

  local buttons = Kit.Row(card, { gap = 8, align = "center" })
  Kit.Label(buttons, { text = "", layout = { weight = 1 } })
  if current.editing then
    Kit.Button(buttons, { text = L("Cancel"), layout = { width = "auto" }, onClick = cancel })
  end
  publish = Kit.Button(buttons, {
    text = view.submitText,
    variant = "primary",
    disabled = not view.canSubmit,
    tooltip = view.reason,
    layout = { width = "auto" },
    onClick = submit,
  })
end

local function edit(announcement)
  state.form = ViewModel.AnnouncementFormFrom(announcement, now())
  UI.Redraw()
end

local function drawRow(card, row, announcement)
  local line = Kit.Row(card, { gap = 8, align = "center" })
  Kit.Label(line, { text = row.title, style = "value", wrap = true, layout = { weight = 1 } })
  if row.pinned then
    Kit.Badge(line, { text = L("Pinned"), color = "accent" })
  end
  if row.expired then
    Kit.Badge(line, { text = L("Expired"), color = "warning" })
  elseif not row.popup then
    Kit.Badge(line, { text = L("No popup"), color = "muted" })
  end
  Kit.Label(card, {
    text = L("%s - %s"):format(row.author, row.age),
    style = "small",
    color = "muted",
  })
  if row.expires and not row.expired then
    Kit.Label(card, { text = row.expires, style = "small", color = "dim" })
  end

  local actions = Kit.Row(card, { gap = 8, align = "center" })
  Kit.Button(actions, {
    text = L("Edit"),
    layout = { width = "auto" },
    onClick = function()
      edit(announcement)
    end,
  })
  Kit.Button(actions, {
    text = L("Send popup again"),
    tooltip = L("Members who closed the popup see it once more."),
    layout = { width = "auto" },
    onClick = function()
      local ok, why = service():ResendPopup(row.id)
      if ok then
        UI.Notify("success", L("The popup was sent again."))
      else
        UI.Notify("warning", ViewModel.AnnouncementReason(why))
      end
    end,
  })
  local key = "announcement:" .. row.id
  if UI.IsArmed(key) then
    Kit.Button(actions, {
      text = L("Click again to delete"),
      variant = "danger",
      layout = { width = "auto" },
      onClick = function()
        UI.Disarm()
        local ok, why = service():Delete(row.id)
        if ok then
          if state.form and state.form.editing == row.id then
            state.form = nil
          end
          UI.Notify("success", L("Announcement deleted."))
        else
          UI.Notify("warning", ViewModel.AnnouncementReason(why))
        end
      end,
    })
  else
    Kit.Button(actions, {
      text = L("Delete"),
      variant = "danger",
      layout = { width = "auto" },
      onClick = function()
        UI.Arm(key)
      end,
    })
  end
end

UI.Register("announceadmin", function(page)
  Kit.PageHeader(page, {
    title = L("Notice board"),
    description = L("Publish news for the whole guild. Only the guild master and the co-guild master can."),
  })
  local lines = service()
  if not lines then
    Kit.EmptyState(page, {
      icon = "send",
      title = L("Announcements are not available"),
      hint = L("They start with the addon. Try /reload."),
    })
    return
  end
  local list = ViewModel.AnnouncementAdminList(lines:List(true), now())
  drawForm(page, list.full)

  local card = Kit.Card(page, { title = L("Published: %s"):format(list.counter), gap = 10 })
  if #list.rows == 0 then
    Kit.Label(card, { text = L("No announcements yet"), color = "muted" })
    return
  end
  for _, row in ipairs(list.rows) do
    drawRow(card, row, lines:Get(row.id))
  end
end)
