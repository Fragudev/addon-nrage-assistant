local _, ns = ...

-- Profile (plan 3.2): the identity line, the two specs, the professions (primary and secondary), the remaining
-- declared details and what is shared with the guild. There is no Save and no Publish button: a dropdown saves when it
-- changes, a text box when it loses the focus with a changed text, and every save is published by itself.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

-- Saves one declared field, publishes it (the change is picked up by the automatic publication too) and says so.
local function save(key, value)
  local character = ns.character
  local ok, reason = ns.ProfileService.SetField(ns.Platform, character.profile, key, value)
  if ok then
    if ns.comm then
      ns.PublishService.PublishIfChanged(ns.comm, character, ns.Platform)
    end
    UI.Notify("success", L("Saved."))
  else
    UI.Notify("danger", L("Not saved: ") .. (ViewModel.PROFILE_SET_ERRORS[reason] or tostring(reason)))
  end
end

local function specItems(optional)
  local items = {}
  if optional then
    items[1] = { value = "", text = L("None") }
  end
  for _, role in ipairs(ns.ProfileService.ROLES) do
    items[#items + 1] = { value = role, text = role }
  end
  return items
end

local function identityCard(page, profile)
  local card = Kit.Card(page, {})
  local stats = ViewModel.IdentityStats(profile, ns.Platform.GetIdentityKey())
  for _, stat in ipairs(stats) do
    if stat.color == "class" then
      stat.color = Kit.Theme.ClassColor(stat.classToken)
    end
  end
  Kit.StatGrid(card, { columns = 4, stats = stats })
end

local function specsCard(page, declared)
  local card = Kit.Card(page, { title = L("Your declared details") })
  local row = Kit.Row(card, { gap = 16 })
  -- A legacy free text role that is not an allowed one stays unselected until the player picks one.
  local field = Kit.Field(row, { label = L("Main spec"), layout = { weight = 1 } })
  Kit.Dropdown(field, {
    items = specItems(false),
    value = ns.ProfileService.NormalizeRole(declared.role and declared.role.value),
    placeholder = L("Pick a spec"),
    onChange = function(value)
      save("role", value)
    end,
  })
  local second = Kit.Field(row, { label = L("Second spec"), layout = { weight = 1 } })
  Kit.Dropdown(second, {
    items = specItems(true),
    value = ns.ProfileService.NormalizeRole(declared.role2 and declared.role2.value) or "",
    placeholder = L("None"),
    onChange = function(value)
      save("role2", value)
    end,
  })
end

local function professionBlock(card, caption, list)
  if #list == 0 then
    return
  end
  Kit.Label(card, { text = caption, style = "small", color = "muted" })
  local stats = {}
  for _, profession in ipairs(list) do
    stats[#stats + 1] = { caption = profession.name, value = profession.text, icon = profession.icon }
  end
  Kit.StatGrid(card, { columns = math.min(#stats, 4), stats = stats })
end

local function professionsCard(page, profile)
  local card = Kit.Card(page, { title = L("Professions") })
  local groups = ViewModel.ProfessionGroups(profile.professions)
  if #groups.primary == 0 and #groups.secondary == 0 then
    Kit.Label(card, { text = L("Professions: unknown"), color = "muted" })
  end
  professionBlock(card, L("Primary"), groups.primary)
  professionBlock(card, L("Secondary"), groups.secondary)
  Kit.Button(card, {
    text = L("See recipes"),
    variant = "ghost",
    icon = "chevron",
    layout = { width = "auto" },
    onClick = function()
      UI.OpenTab("professions")
    end,
  })
end

local function detailsCard(page, declared)
  local card = Kit.Card(page, {})
  local row = Kit.Row(card, { gap = 16 })
  local main = Kit.Field(row, { label = L("Main character"), layout = { weight = 1 } })
  Kit.EditBox(main, {
    text = declared.main and declared.main.value or "",
    maxLetters = ns.Constants.MAX_FIELD_LENGTH,
    onCommit = function(value)
      save("main", value)
    end,
  })
  local notes = Kit.Field(row, { label = L("Notes (these stay on this computer)"), layout = { weight = 1 } })
  Kit.EditBox(notes, {
    text = declared.notes and declared.notes.value or "",
    maxLetters = ns.Constants.MAX_FIELD_LENGTH,
    onCommit = function(value)
      save("notes", value)
    end,
  })
end

local function sharedCard(page, character)
  local card = Kit.Card(page, { title = L("Shared with the guild"), gap = 8 })
  for _, line in ipairs(ns.PublishService.Describe(character.profile)) do
    Kit.Label(card, { text = ViewModel.Escape(line), color = "dim", wrap = true })
  end
  Kit.Label(card, {
    text = L("Shared automatically")
      .. " \194\183 "
      .. ViewModel.LastPublished(character.publish.at, ns.Platform.ServerTime()),
    style = "small",
    color = "muted",
    layout = { gap = 12 },
  })
  Kit.Label(card, {
    text = L("Addon messages are not private: any guild member with the addon can read them."),
    style = "small",
    color = "muted",
    wrap = true,
  })
end

UI.Register("profile", function(page)
  local character = ns.character
  local profile = character.profile
  local declared = profile.fields or {}
  Kit.PageHeader(page, {
    title = L("Profile"),
    description = L("What the guild knows about your character. Changes are shared by themselves."),
  })
  identityCard(page, profile)
  specsCard(page, declared)
  professionsCard(page, profile)
  detailsCard(page, declared)
  sharedCard(page, character)
end)
