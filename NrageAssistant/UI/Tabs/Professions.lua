local _, ns = ...

-- Professions (plan 3.10): the recipes every member with the addon has learned, shared by themselves, and a search that
-- finds who can craft one. The online crafters come first; "Ask" opens the chat box with a whisper typed in, which the
-- player sends (the addon never whispers by itself). Your own recipes are read when you open a profession window.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

local state = {
  search = "",
  professionId = false,
  onlineOnly = false,
}

-- The names the client gives to recipe ids, kept for the session: the client is asked once per recipe, and only for
-- the ones
-- shown or searched.
local names = {}

local function recipeInfo(id)
  local info = names[id]
  if info == nil then
    info = ns.Platform.GetRecipeInfo(id) or false
    names[id] = info
  end
  return info or nil
end

local function nameOf(id)
  local info = recipeInfo(id)
  return info and info.name or nil
end

local function onlineOf(name)
  local entry = ns.guildRoster and ns.guildRoster:Lookup(name)
  if entry then
    return entry.online
  end
  return nil
end

local function currentIndex()
  local known
  if ns.guildRoster and ns.guildRoster.entries and next(ns.guildRoster.entries) ~= nil then
    known = function(name)
      return ns.guildRoster.entries[name] ~= nil
    end
  end
  return ns.RecipeService.Index(
    { key = ns.Platform.GetIdentityKey(), recipes = ns.character.recipes },
    ns.db.global.recipes,
    known
  )
end

-- ---------------------------------------------------------------------------------------------------------------
-- My professions

local function myProfessions(page)
  local card = Kit.Card(page, { title = L("My professions"), gap = 8 })
  local rows =
    ViewModel.MyProfessionRows(ns.character.profile.professions, ns.character.recipes, ns.Platform.ServerTime())
  if #rows == 0 then
    Kit.Label(card, { text = L("Professions: unknown"), color = "muted" })
  end
  for _, row in ipairs(rows) do
    local line = Kit.Row(card, { gap = 10, align = "center" })
    Kit.Label(line, { text = row.name, layout = { weight = 2 } })
    Kit.Label(line, { text = row.skillText, color = "dim", layout = { width = 70 } })
    Kit.Label(line, { text = row.scanText, style = "small", color = "muted", layout = { weight = 2 } })
    Kit.Badge(line, {
      text = row.needsScan and L("Open it once") or L("Shared"),
      color = row.needsScan and "warning" or "success",
      layout = { width = "auto" },
    })
  end
  if ns.Platform.RecipeScanAvailable() then
    Kit.Label(card, {
      text = L("Open this profession's window so the guild sees your latest recipes."),
      style = "small",
      color = "muted",
      wrap = true,
    })
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The results

local function askButton(row, recipe, crafter)
  local info = recipeInfo(recipe.recipeId)
  local line = Kit.Row(row, { gap = 6, align = "center" })
  Kit.Icon(line, {
    icon = "dot",
    size = 14,
    color = crafter.online == true and "success" or "muted",
    layout = { width = 14 },
  })
  if ns.Platform.CanPrefillChat() then
    Kit.Button(line, {
      text = L("Ask %s"):format(crafter.label),
      icon = "send",
      disabled = crafter.online == false,
      layout = { width = "auto" },
      onClick = function()
        local thing = info and (info.link or info.name) or recipe.plainName
        ns.Platform.PrefillChat(ViewModel.AskText(crafter.name, thing))
      end,
    })
  else
    Kit.Label(line, {
      text = crafter.label,
      color = crafter.online == true and "text" or "muted",
      layout = { width = "auto" },
    })
  end
end

local function drawResults(region, index)
  local data = ViewModel.RecipeResults({
    index = index,
    search = state.search,
    professionId = state.professionId,
    onlineOnly = state.onlineOnly,
    online = onlineOf,
    nameOf = nameOf,
  })
  if index.members == 0 then
    Kit.EmptyState(region, {
      icon = "book",
      title = L("No recipes shared yet"),
      hint = L("Open your professions once so the guild can see your recipes."),
    })
    return
  end
  if #data.rows == 0 then
    Kit.EmptyState(
      region,
      { icon = "search", title = L("No recipe matches"), hint = L("Try another name or profession.") }
    )
    return
  end
  local card = Kit.Card(region, { gap = 12, pad = { 18, 12, 18, 12 } })
  for position, recipe in ipairs(data.rows) do
    local info = recipeInfo(recipe.recipeId)
    local row = Kit.Row(card, { gap = 12, align = "center", layout = { gap = position == 1 and 0 or 12 } })
    Kit.ItemLabel(row, {
      text = recipe.name,
      icon = info and info.icon or nil,
      link = info and info.link or nil,
      size = 24,
      layout = { weight = 2 },
    })
    Kit.Label(row, { text = recipe.professionName, color = "dim", style = "small", layout = { width = 110 } })
    local crafters = Kit.Row(row, { gap = 12, align = "center", layout = { weight = 3 } })
    for _, crafter in ipairs(recipe.crafters) do
      askButton(crafters, recipe, crafter)
    end
    if recipe.more > 0 then
      Kit.Label(
        crafters,
        { text = L("+%d more"):format(recipe.more), style = "small", color = "muted", layout = { width = 60 } }
      )
    end
  end
  if data.shown < data.total then
    Kit.Label(region, {
      text = L("Showing %d of %d recipes. Search to narrow the list."):format(data.shown, data.total),
      style = "small",
      color = "muted",
      layout = { gap = 10 },
    })
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The tab

UI.Register("professions", function(page)
  Kit.PageHeader(page, {
    title = L("Professions"),
    description = L("Who in the guild can craft a recipe. Members share their recipes by themselves."),
  })
  if not ns.Platform.RecipeScanAvailable() then
    Kit.Banner(page, {
      kind = "warning",
      text = L("Reading your own recipes is not available on this client. You can still see what others share."),
    })
  end
  myProfessions(page)

  local index = currentIndex()
  local region
  local bar = Kit.Row(page, { gap = 10, align = "center" })
  Kit.EditBox(bar, {
    text = state.search,
    placeholder = L("Search a recipe"),
    layout = { weight = 1 },
    onChange = function(text, userInput)
      if userInput and region then
        state.search = text
        region:Clear()
        drawResults(region, index)
        UI.Relayout()
      end
    end,
  })
  Kit.Dropdown(bar, {
    items = ViewModel.ProfessionChoices(index),
    value = state.professionId,
    layout = { width = 220 },
    onChange = function(value)
      state.professionId = value
      UI.Redraw()
    end,
  })
  Kit.Chip(bar, {
    text = L("Connected only"),
    active = state.onlineOnly,
    color = "success",
    layout = { width = "auto" },
    onToggle = function(active)
      state.onlineOnly = active
      UI.Redraw()
    end,
  })
  region = Kit.Stack(page, { gap = 12 })
  drawResults(region, index)
end)
