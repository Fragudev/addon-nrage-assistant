local _, ns = ...

-- The recipes the members have learned (plan 3.10). Pure logic over plain tables, no client API, so it is tested
-- without a
-- client. Recipe ids are numbers (names and icons are looked up in the client when they are shown), so what is stored
-- and
-- sent is small.
--
--   own character:  char.recipes[professionId] = { name, ids = { sorted unique ids }, at, skill, rev }
--   received:       global.recipes[memberKey][professionId] = { name, ids, rev, receivedAt }
--
-- A scan is what the profession window shows while it is open (Platform.ScanKnownRecipes). The addon keeps the last
-- scan of
-- each profession and publishes it when it changes, in chunks that fit a message (Chunks).
local RecipeService = {}

local V = ns.Validate

-- The valid recipe ids of `ids`, each once, sorted, up to the cap of a profession.
function RecipeService.Normalize(ids)
  local seen, list = {}, {}
  for _, id in ipairs(type(ids) == "table" and ids or {}) do
    if V.Int(id, 1, ns.Constants.RECIPE_ID_MAX) and not seen[id] then
      seen[id] = true
      list[#list + 1] = id
    end
  end
  table.sort(list)
  while #list > ns.Constants.RECIPES_MAX_PER_PROFESSION do
    table.remove(list)
  end
  return list
end

-- Two lists with the same ids have the same fingerprint, whatever the order they came in.
function RecipeService.Fingerprint(ids)
  return table.concat(RecipeService.Normalize(ids), ",")
end

-- Keeps a scan of the own character. `recipes` is char.recipes; `scan` = { professionId, professionName, ids } from
-- Platform.ScanKnownRecipes; `skill` the skill of the profession now (to tell later that it changed). Returns the
-- record and
-- whether the recipes are different from the last scan: only then does the revision go up, so an unchanged scan sends
-- nothing.
function RecipeService.StoreScan(recipes, scan, now, skill)
  local id = scan.professionId
  if not V.Int(id, 1, ns.Constants.RECIPE_PROFESSION_ID_MAX) then
    return nil, false
  end
  local ids = RecipeService.Normalize(scan.ids)
  local record = recipes[id]
  local changed = record == nil or RecipeService.Fingerprint(record.ids) ~= RecipeService.Fingerprint(ids)
  if not record then
    record = { rev = 0 }
    recipes[id] = record
  end
  record.name = type(scan.professionName) == "string" and scan.professionName:sub(1, 40) or tostring(id)
  record.at = now
  record.skill = skill
  if changed then
    record.ids = ids
    -- Server time keeps revisions monotonic even if the saved data is ever reset.
    record.rev = math.max((record.rev or 0) + 1, now)
  end
  return record, changed
end

-- The messages that publish a record: { prof, name, rev, updatedAt, part, parts, ids } with at most RECIPE_CHUNK ids
-- each.
function RecipeService.Chunks(professionId, record, now)
  local size = ns.Constants.RECIPE_CHUNK
  local ids = record.ids or {}
  local parts = math.max(1, math.ceil(#ids / size))
  local chunks = {}
  for part = 1, parts do
    local slice = {}
    for index = (part - 1) * size + 1, math.min(part * size, #ids) do
      slice[#slice + 1] = ids[index]
    end
    chunks[part] = {
      prof = professionId,
      name = record.name,
      rev = record.rev,
      updatedAt = now,
      part = part,
      parts = parts,
      total = #ids,
      ids = slice,
    }
  end
  return chunks
end

-- true when the skill of the profession is not what it was at the last scan, or it was never scanned: the player is
-- asked
-- to open the profession window again.
function RecipeService.NeedsScan(record, currentSkill)
  if not record then
    return true
  end
  return currentSkill ~= nil and record.skill ~= nil and currentSkill ~= record.skill
end

-- The recipes of everyone as an index: recipes[id] = { professionId, crafters = { names } } and professions[id] =
-- name. `own`
-- = { key, alias, recipes } is this character (`alias`: the other key it can have been stored under while its full
-- name was not known), `received` is global.recipes, `known(name)` says whether a member still counts (is in
-- the guild roster; nil counts everybody). A member that left is left out. A crafter is listed once per recipe, even
-- when the same recipe is in two of their professions.
function RecipeService.Index(own, received, known)
  local index = { recipes = {}, professions = {}, members = 0 }
  local function add(name, professionId, record)
    index.professions[professionId] = index.professions[professionId] or record.name
    for _, id in ipairs(record.ids or {}) do
      local entry = index.recipes[id]
      if not entry then
        entry = { professionId = professionId, crafters = {}, seen = {} }
        index.recipes[id] = entry
      end
      if not entry.seen[name] then
        entry.seen[name] = true
        entry.crafters[#entry.crafters + 1] = name
      end
    end
  end
  local names = {}
  if own and own.recipes and next(own.recipes) ~= nil then
    names[own.key] = own.recipes
  end
  for member, byProfession in pairs(received or {}) do
    local isOwn = own and (member == own.key or member == own.alias)
    if not isOwn and (not known or known(member)) then
      names[member] = byProfession
    end
  end
  local ordered = {}
  for name in pairs(names) do
    ordered[#ordered + 1] = name
  end
  table.sort(ordered)
  for _, name in ipairs(ordered) do
    index.members = index.members + 1
    local professions = {}
    for professionId in pairs(names[name]) do
      professions[#professions + 1] = professionId
    end
    table.sort(professions)
    for _, professionId in ipairs(professions) do
      add(name, professionId, names[name][professionId])
    end
  end
  return index
end

ns.RecipeService = RecipeService
