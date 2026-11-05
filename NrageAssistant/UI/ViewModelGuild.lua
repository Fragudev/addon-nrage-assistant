local _, ns = ...

-- Structured rows for the PvP, Blacklist and Rules tabs (plan 3.6, 3.7 and 3.9), and the guild-wide helpers they share.
local ViewModel = ns.ViewModel
local L = ns.L
local Escape = ViewModel.Escape

-- ---------------------------------------------------------------------------------------------------------------
-- PvP

ViewModel.PVP_PERIOD_CHOICES = ns.Locale.Table(function()
  return {
    { value = "total", text = L("Total") },
    { value = "today", text = L("Today") },
  }
end)

-- "Not available" in a cell the client cannot fill.
local function unavailable()
  return { value = L("Not available"), color = "muted" }
end

-- The two stat grids of "My stats". options = { day, honorAvailable, blowsAvailable, ranks }. Each grid holds the
-- honourable kills (open world, battleground, total), the killing blows and the PvP rank; a figure the client cannot
-- provide shows "Not available" in the muted color. Returns { today = { stats }, total = { stats }, rank = rank info }.
function ViewModel.PvPStatGrids(stats, options)
  local totals = ns.PvPService.Totals(stats)
  local today = ns.PvPService.Today(stats, options.day)
  local rank = ns.PvPService.RankFor(totals.honor.total, options.ranks or ns.Constants.PVP_RANKS)

  local function rankStat()
    local text = rank.name and Escape(rank.name) or L("none yet")
    if rank.next then
      text = text .. " (" .. L("%d to %s"):format(rank.next.remaining, Escape(rank.next.name)) .. ")"
    end
    return { caption = L("Rank"), value = text }
  end

  local function grid(honor, blows)
    local list = {}
    local function add(caption, value, available)
      local stat = { caption = caption }
      if available then
        stat.value = tostring(value)
      else
        local muted = unavailable()
        stat.value, stat.color = muted.value, muted.color
      end
      list[#list + 1] = stat
    end
    add(L("Open world"), honor.world, options.honorAvailable)
    add(L("Battleground"), honor.bg, options.honorAvailable)
    add(L("Honourable kills"), honor.total, options.honorAvailable)
    add(L("Killing blows"), blows.total, options.blowsAvailable)
    list[#list + 1] = rankStat()
    return list
  end

  return {
    today = grid(today.honor, today.blows),
    total = grid(totals.honor, totals.blows),
    rank = rank,
  }
end

-- The ranking as table rows: the rows of ViewModel.PvPRanking with their position in the current order (the top three
-- colored gold, silver and bronze), filtered by a search on the name, and cut at `limit`. Returns { rows, shown,
-- total }
-- where `total` counts the rows that passed the search.
function ViewModel.RankingTable(rows, options)
  local needle = (options.search or ""):lower()
  local result = {}
  for position, row in ipairs(rows) do
    if needle == "" or row.name:lower():find(needle, 1, true) then
      result[#result + 1] = {
        position = position,
        positionToken = ns.Kit.Theme.PositionToken(position),
        name = row.label,
        rank = row.rank,
        world = tostring(row.world),
        bg = tostring(row.bg),
        total = tostring(row.total),
        blows = row.blows and tostring(row.blows) or "-",
        updated = row.updated,
        mine = row.mine,
        member = row.name,
      }
    end
  end
  local total = #result
  while #result > (options.limit or total) do
    table.remove(result)
  end
  return { rows = result, shown = #result, total = total }
end

-- The recent kills as rows: { time, text, place, blow }. `options` = { available, formatTime }. `text` is "killers ->
-- victim", escaped. Returns { rows, notice } where `notice` is "unavailable" when the client cannot read a victim name,
-- "empty" when there are no kills yet, or nil.
function ViewModel.FeedRows(entries, options)
  local rows = {}
  for _, entry in ipairs(entries) do
    local names = {}
    for index, killer in ipairs(entry.killers) do
      names[index] = Escape(killer)
    end
    rows[#rows + 1] = {
      time = options.formatTime and options.formatTime(entry.time) or "--:--",
      text = ("%s \226\134\146 %s"):format(table.concat(names, ", "), Escape(entry.victim)),
      place = entry.where == "bg" and L("battleground") or L("open world"),
      blow = entry.blow == true,
    }
  end
  local notice
  if not options.available then
    notice = "unavailable"
  elseif #rows == 0 then
    notice = "empty"
  end
  return { rows = rows, notice = notice }
end

-- ---------------------------------------------------------------------------------------------------------------
-- Blacklist

-- The keys of the listed players that are in the current group: a set key -> true. `members` = the group names.
function ViewModel.BlacklistGroupKeys(entries, members)
  local keys = {}
  for _, match in ipairs(ns.BlacklistService.Match(entries, members)) do
    keys[match.key] = true
  end
  return keys
end

-- The table of the Blacklist tab. options = { role, actor, search, groupKeys = set of keys in the group, formatDate }.
-- Rows are sorted with the players in the group first, then by name; a search matches the name or the reason. Each row
-- says whether the pencil (edit the reason: the member who added it, or the guild master) and the trash (remove: the
-- guild master) are offered. Text is escaped; `rawReason` is the plain reason for the edit box.
function ViewModel.BlacklistTable(entries, options)
  local needle = (options.search or ""):lower()
  local rows = {}
  for _, entry in ipairs(ns.BlacklistService.List(entries)) do
    local reason = entry.reason or ""
    local keep = needle == ""
      or (entry.name:lower():find(needle, 1, true) ~= nil)
      or (reason:lower():find(needle, 1, true) ~= nil)
    if keep then
      rows[#rows + 1] = {
        key = entry.key,
        name = Escape(entry.name),
        reason = Escape(reason ~= "" and reason or "-"),
        rawReason = reason,
        addedBy = Escape(entry.addedBy or "-"),
        added = type(entry.addedAt) == "number" and options.formatDate and options.formatDate(entry.addedAt) or "-",
        inGroup = options.groupKeys ~= nil and options.groupKeys[entry.key] == true,
        canEdit = ns.BlacklistService.CanEdit(entry, options.actor, options.role),
        canRemove = ns.PermissionService.Can(options.role, "blacklist_remove"),
        sortName = entry.name:lower(),
      }
    end
  end
  table.sort(rows, function(a, b)
    if a.inGroup ~= b.inGroup then
      return a.inGroup
    end
    if a.sortName ~= b.sortName then
      return a.sortName < b.sortName
    end
    return a.key < b.key
  end)
  return rows
end

-- The live counter under the reason box: "37 / 100", warning near the limit.
function ViewModel.ReasonCounter(text, max)
  local used = #(text or "")
  return {
    text = ("%d / %d"):format(used, max),
    token = used >= max * 0.9 and "warning" or "muted",
    over = used > max,
  }
end

-- ---------------------------------------------------------------------------------------------------------------
-- Rules

-- A rule measured by the game is automatic, one the player confirms is manual.
function ViewModel.IsAutomaticRule(rule)
  return rule.check ~= "field" and rule.check ~= "confirm"
end

-- The list of the Rules tab: { id, kindText, name, summary, automatic, badge = { text, color } }.
function ViewModel.RuleRows(rules)
  local rows = {}
  for _, rule in ipairs(rules) do
    local automatic = ViewModel.IsAutomaticRule(rule)
    rows[#rows + 1] = {
      id = rule.id,
      kindText = Escape(ViewModel.RULE_CHECK_TEXT[rule.check] or rule.check),
      name = Escape(ns.ReadinessService.LabelText(rule.label)),
      summary = Escape(ViewModel.RuleSummary(rule)),
      automatic = automatic,
      badge = {
        text = automatic and L("Automatic") or L("Manual"),
        color = automatic and "info" or "warning",
        fixed = true,
      },
      rule = rule,
    }
  end
  return rows
end

-- A copy of `rules` where the rule called `id` is `rule`, in the same place with the same id (so the confirmations
-- members already gave stay attached). Returns the list, or nil plus "unknown_rule".
function ViewModel.ReplaceRule(rules, id, rule)
  local list, found = {}, false
  for index, existing in ipairs(rules) do
    if existing.id == id then
      local copy = {}
      for key, value in pairs(rule) do
        copy[key] = value
      end
      copy.id = id
      list[index] = copy
      found = true
    else
      list[index] = existing
    end
  end
  if not found then
    return nil, "unknown_rule"
  end
  return list
end

-- The slots an admin can ask to be enchanted, in slot order: { key, slot, text }.
function ViewModel.EnchantSlotChoices()
  local list = {}
  for key, slot in pairs(ViewModel.ENCHANT_SLOTS) do
    list[#list + 1] = { key = key, slot = slot }
  end
  table.sort(list, function(a, b)
    return a.slot < b.slot
  end)
  for _, entry in ipairs(list) do
    entry.text = ViewModel.ENCHANT_SLOT_TEXT[entry.key] or entry.key
  end
  return list
end

ViewModel.ENCHANT_SLOT_TEXT = ns.Locale.Table(function()
  return {
    head = L("Head"),
    shoulders = L("Shoulders"),
    chest = L("Chest"),
    wrist = L("Wrist"),
    hands = L("Hands"),
    legs = L("Legs"),
    feet = L("Feet"),
    back = L("Back"),
    mainhand = L("Main hand"),
    offhand = L("Off hand"),
    ranged = L("Ranged"),
  }
end)

-- The declared profile fields a "field" rule can check, as dropdown items.
ViewModel.FIELD_TEXT = ns.Locale.Table(function()
  return {
    role = L("Main spec"),
    role2 = L("Second spec"),
    main = L("Main character"),
    notes = L("Notes"),
  }
end)

function ViewModel.FieldChoices()
  local keys = {}
  for key in pairs(ns.Constants.MANUAL_FIELDS) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local items = {}
  for _, key in ipairs(keys) do
    items[#items + 1] = { value = key, text = ViewModel.FIELD_TEXT[key] or key }
  end
  return items
end

-- The kinds of rule as dropdown items, in the order of RULE_CHECKS.
function ViewModel.RuleKindChoices()
  local items = {}
  for _, check in ipairs(ViewModel.RULE_CHECKS) do
    items[#items + 1] = { value = check, text = ViewModel.RULE_CHECK_TEXT[check] }
  end
  return items
end

-- The fields of the add or edit form for a rule (the inverse of RuleFromFields), so editing starts from what is
-- there: { label, min, slots = set of slot numbers, buffs = "a, b, 123", profession, field }.
function ViewModel.RuleFields(rule)
  local fields = { label = rule.label, min = rule.min and tostring(rule.min) or "" }
  fields.slots = {}
  for _, slot in ipairs(rule.slots or {}) do
    fields.slots[slot] = true
  end
  local buffs = {}
  for _, id in ipairs(rule.spellIds or {}) do
    buffs[#buffs + 1] = tostring(id)
  end
  for _, name in ipairs(rule.names or {}) do
    buffs[#buffs + 1] = name
  end
  fields.buffs = table.concat(buffs, ", ")
  fields.profession = rule.profession or ""
  fields.field = rule.field or "role"
  return fields
end

-- Builds a rule from the structured controls of the form: { label, min (text), slots (set of slot numbers), buffs
-- (text),
-- profession (text), field }. It turns them into the `details` text RuleFromInput reads, so there is one validation
-- path.
-- `id` keeps the id of the rule being edited. Returns the clean rule, or nil plus a reason from RULE_ERRORS.
function ViewModel.RuleFromFields(check, fields, rules, id)
  local details = ""
  if check == "level" or check == "ilvl" then
    details = tostring(fields.min or "")
  elseif check == "enchants" then
    local slots = {}
    for slot in pairs(fields.slots or {}) do
      slots[#slots + 1] = slot
    end
    table.sort(slots)
    for index, slot in ipairs(slots) do
      slots[index] = tostring(slot)
    end
    details = table.concat(slots, ",")
  elseif check == "buff" then
    details = fields.buffs or ""
  elseif check == "profession" then
    local name = (fields.profession or ""):match("^%s*(.-)%s*$")
    local min = (fields.min or ""):match("^%s*(.-)%s*$")
    if name == "" and min ~= "" then
      return nil, "bad_details"
    end
    details = min ~= "" and (name .. " " .. min) or name
  elseif check == "field" then
    details = fields.field or ""
  end
  local others = rules
  if id then
    others = {}
    for _, rule in ipairs(rules) do
      if rule.id ~= id then
        others[#others + 1] = rule
      end
    end
  end
  local rule, reason = ViewModel.RuleFromInput(check, fields.label or "", details, others)
  if not rule then
    return nil, reason
  end
  if id then
    rule.id = id
  end
  return rule
end

-- Which control an error belongs under: the name, or the details of the kind.
function ViewModel.RuleErrorField(reason)
  if reason == "bad_label" or reason == "bad_id" or reason == "duplicate_id" then
    return "label"
  end
  return "details"
end
