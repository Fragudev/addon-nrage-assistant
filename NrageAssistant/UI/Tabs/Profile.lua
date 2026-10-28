local _, ns = ...

-- Profile (plan 3.2): the identity line, the two specs, the professions (primary and secondary), the remaining
-- declared details and what is shared with the guild. There is no Save and no Publish button: a dropdown saves when it
-- changes, a text box when it loses the focus with a changed text, and every save is published by itself. The identity
-- and specs cards are shared with Home (UI/Cards.lua).
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

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
      UI.SaveDeclared("main", value)
    end,
  })
  local notes = Kit.Field(row, { label = L("Notes (these stay on this computer)"), layout = { weight = 1 } })
  Kit.EditBox(notes, {
    text = declared.notes and declared.notes.value or "",
    maxLetters = ns.Constants.MAX_FIELD_LENGTH,
    onCommit = function(value)
      UI.SaveDeclared("notes", value)
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
  UI.IdentityCard(page, profile)
  UI.SpecsCard(page, declared)
  professionsCard(page, profile)
  detailsCard(page, declared)
  sharedCard(page, character)
end)
