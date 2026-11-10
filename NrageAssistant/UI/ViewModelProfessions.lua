local _, ns = ...

-- Rows for the Professions tab (plan 3.10): who in the guild can craft a recipe, found by name, with the online
-- crafters
-- first, and the own professions with when each was last scanned.
local ViewModel = ns.ViewModel
local L = ns.L
local Escape = ViewModel.Escape

-- The professions that have shared recipes, as dropdown items: "All professions" first (value false), then by name.
function ViewModel.ProfessionChoices(index)
  local items = {}
  for id, name in pairs(index.professions) do
    -- Named here, in the language of the addon: the name in the index is the one the first crafter's client sent.
    items[#items + 1] = { value = id, text = Escape(ns.Professions.NameForId(id, name or tostring(id))) }
  end
  table.sort(items, function(a, b)
    if a.text ~= b.text then
      return a.text < b.text
    end
    return a.value < b.value
  end)
  table.insert(items, 1, { value = false, text = L("All professions") })
  return items
end

-- "Recipe 1234" for a recipe the client cannot name.
local function fallbackName(id)
  return L("Recipe %d"):format(id)
end

-- The crafters of a recipe, online ones first (then by name). `online(name)` is true, false or nil (unknown).
local function crafterRows(names, online, onlineOnly)
  local rows = {}
  for _, name in ipairs(names) do
    local state = online(name)
    if not onlineOnly or state == true then
      rows[#rows + 1] = { name = name, label = Escape(name), online = state }
    end
  end
  table.sort(rows, function(a, b)
    local left, right = a.online == true and 0 or 1, b.online == true and 0 or 1
    if left ~= right then
      return left < right
    end
    return a.name < b.name
  end)
  return rows
end

-- The recipes that match, for the table. args = {
--   index          RecipeService.Index
--   search         part of the recipe name as the client writes it (or its id), case-insensitive
--   professionId   only that profession, or nil/false for all
--   onlineOnly     hide the crafters that are not online (and the recipes with none left)
--   online(name)   true | false | nil
--   nameOf(id)     the name of a recipe from the client, or nil; resolved only for what is shown or searched
--   limit          how many recipes to return (default Constants.RECIPE_RESULTS_MAX)
-- }
-- Returns { rows, shown, total }; each row = { recipeId, name, professionId, professionName, crafters = { { name,
-- label, online } } }.
-- With no search the recipes come in id order and only the ones shown are named; with a search every candidate is
-- named and
-- the matches come sorted by name.
function ViewModel.RecipeResults(args)
  local needle = (args.search or ""):lower():match("^%s*(.-)%s*$")
  local limit = args.limit or ns.Constants.RECIPE_RESULTS_MAX
  local ids = {}
  for id, entry in pairs(args.index.recipes) do
    if not args.professionId or entry.professionId == args.professionId then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)

  local function build(id, name)
    local entry = args.index.recipes[id]
    local crafters = crafterRows(entry.crafters, args.online, args.onlineOnly)
    if #crafters == 0 then
      return nil
    end
    return {
      recipeId = id,
      name = Escape(name or args.nameOf(id) or fallbackName(id)),
      plainName = name or args.nameOf(id) or fallbackName(id),
      professionId = entry.professionId,
      professionName = Escape(
        ns.Professions.NameForId(
          entry.professionId,
          args.index.professions[entry.professionId] or tostring(entry.professionId)
        )
      ),
      crafters = crafters,
    }
  end

  local rows = {}
  if needle == "" then
    local total = 0
    for _, id in ipairs(ids) do
      local row = nil
      if #rows < limit then
        row = build(id)
      elseif #crafterRows(args.index.recipes[id].crafters, args.online, args.onlineOnly) > 0 then
        row = true
      end
      if row then
        total = total + 1
        if row ~= true then
          rows[#rows + 1] = row
        end
      end
    end
    return { rows = rows, shown = #rows, total = total }
  end

  for _, id in ipairs(ids) do
    local name = args.nameOf(id) or fallbackName(id)
    if name:lower():find(needle, 1, true) or tostring(id):find(needle, 1, true) then
      local row = build(id, name)
      if row then
        rows[#rows + 1] = row
      end
    end
  end
  table.sort(rows, function(a, b)
    local left, right = a.plainName:lower(), b.plainName:lower()
    if left ~= right then
      return left < right
    end
    return a.recipeId < b.recipeId
  end)
  local total = #rows
  while #rows > limit do
    table.remove(rows)
  end
  return { rows = rows, shown = #rows, total = total }
end

-- The crafters of a recipe that can be asked, as dropdown items: the online ones, and the ones whose state is unknown
-- because the roster has not arrived yet.
function ViewModel.CrafterChoices(crafters)
  local items = {}
  for _, crafter in ipairs(crafters) do
    if crafter.online ~= false then
      items[#items + 1] = { value = crafter.name, text = crafter.label }
    end
  end
  return items
end

-- Who can craft a recipe when nobody is online, for a tooltip: the first names, then how many are left.
function ViewModel.OfflineCraftersText(crafters)
  local labels = {}
  for position = 1, math.min(#crafters, ns.Constants.RECIPE_OFFLINE_NAMES_MAX) do
    labels[position] = crafters[position].label
  end
  local text = table.concat(labels, ", ")
  local rest = #crafters - #labels
  if rest > 0 then
    text = text .. " " .. L("and %d more"):format(rest)
  end
  return text
end

-- The text the crafter dropdown puts in the chat box: a whisper the player sends with Enter. `thing` is the item link
-- of the recipe when the client gives one, else its name.
function ViewModel.AskText(crafter, thing)
  return ("/w %s %s"):format(crafter, L("Could you craft me %s?"):format(thing))
end

-- The own professions with the last scan of each: { name, skill, scanText, needsScan, count }. `recipes` is
-- char.recipes (by profession id); a profession is matched by name, as the client writes it in both.
function ViewModel.MyProfessionRows(professions, recipes, now)
  local byName = {}
  for _, record in pairs(recipes or {}) do
    byName[record.name or ""] = record
  end
  local rows = {}
  for _, profession in ipairs(professions or {}) do
    local record = byName[profession.name]
    local needs = ns.RecipeService.NeedsScan(record, profession.skill)
    local scan
    if record and record.at then
      scan = L("Scanned %s"):format(ViewModel.AgeText(math.max(0, now - record.at)))
    else
      scan = L("Never scanned")
    end
    rows[#rows + 1] = {
      name = Escape(profession.name),
      icon = ViewModel.ProfessionIcon(profession),
      skill = profession.skill,
      skillText = profession.max and ("%d/%d"):format(profession.skill, profession.max) or tostring(profession.skill),
      scanText = scan,
      needsScan = needs,
      count = record and record.ids and #record.ids or 0,
      secondary = profession.secondary == true,
    }
  end
  return rows
end
