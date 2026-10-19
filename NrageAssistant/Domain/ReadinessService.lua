local _, ns = ...

-- Readiness checklist. Each rule resolves to one status:
--   met | missing | unknown | notApplicable | waived
-- `unknown` (no data, or a manual item nobody confirmed) never counts as met, and the score always
-- shows its denominator.
local ReadinessService = {}

local L = ns.L

-- How each status is written where it is shown. The code keeps comparing and storing the English words.
local STATUS_TEXT = ns.Locale.Table(function()
  return {
    met = L("met"),
    missing = L("missing"),
    unknown = L("unknown"),
    notApplicable = L("notApplicable"),
    waived = L("waived"),
  }
end)

function ReadinessService.StatusText(status)
  return STATUS_TEXT[status] or status
end

-- The labels of the starting rules (Constants.DEFAULT_RULES), which are data shared in English; they are shown
-- translated. A rule the guild wrote itself is shown as written.
local DEFAULT_LABELS = ns.Locale.Table(function()
  return {
    ["Level 60"] = L("Level 60"),
    ["Item level"] = L("Item level"),
    ["Role declared"] = L("Role declared"),
    ["Consumables ready"] = L("Consumables ready"),
    ["Enchants done"] = L("Enchants done"),
  }
end)

function ReadinessService.LabelText(label)
  return DEFAULT_LABELS[label] or label
end

-- Statuses a player may set by hand on a `confirm` rule. "unknown" clears the confirmation.
local MANUAL_STATUSES = { met = true, missing = true, waived = true, unknown = true }

local function result(rule, status, detail, source)
  return {
    ruleId = rule.id,
    label = ReadinessService.LabelText(rule.label),
    category = rule.category,
    evidenceMode = rule.evidenceMode,
    status = status,
    detail = detail,
    source = source,
  }
end

local function atLeast(rule, value, name, noData)
  if value == nil then
    return result(rule, "unknown", noData)
  end
  local detail = L("%s %s (needs %s)"):format(name, tostring(value), tostring(rule.min))
  return result(rule, value >= rule.min and "met" or "missing", detail, "observed")
end

local function hasProfession(rule, professions)
  if professions == nil then
    return result(rule, "unknown", L("no profession data"))
  end
  for _, profession in ipairs(professions) do
    if profession.name:lower() == rule.profession:lower() then
      local detail = ("%s %s"):format(profession.name, tostring(profession.skill))
      if rule.min and (profession.skill or 0) < rule.min then
        return result(rule, "missing", L("%s (needs %s)"):format(detail, rule.min), "observed")
      end
      return result(rule, "met", detail, "observed")
    end
  end
  return result(rule, "missing", L("%s not learned"):format(rule.profession), "observed")
end

-- Required slots are enchanted. Rule: { check = "enchants", slots = { 16, 5, ... } }.
local function hasEnchants(rule, enchants)
  if enchants == nil then
    return result(rule, "unknown", L("no enchant data"))
  end
  local missing, unknown = {}, 0
  for _, slot in ipairs(rule.slots or {}) do
    local enchantId = enchants[slot]
    if enchantId == nil then
      unknown = unknown + 1
    elseif enchantId == 0 then
      missing[#missing + 1] = tostring(slot)
    end
  end
  if #missing > 0 then
    return result(rule, "missing", L("not enchanted: slot %s"):format(table.concat(missing, ", ")), "observed")
  end
  if unknown > 0 then
    return result(rule, "unknown", L("%d slot(s) unreadable or empty"):format(unknown))
  end
  return result(rule, "met", L("all required slots enchanted"), "observed")
end

-- One of the listed buffs is active. Rule: { check = "buff", spellIds = { ... } } and/or names = { ... }.
local function hasBuff(rule, buffs)
  if buffs == nil then
    return result(rule, "unknown", L("no buff data"))
  end
  local wantedIds, wantedNames = {}, {}
  for _, id in ipairs(rule.spellIds or {}) do
    wantedIds[id] = true
  end
  for _, name in ipairs(rule.names or {}) do
    wantedNames[name:lower()] = true
  end
  for _, buff in ipairs(buffs) do
    if wantedIds[buff.spellId] or wantedNames[buff.name:lower()] then
      return result(rule, "met", buff.name, "observed")
    end
  end
  return result(rule, "missing", L("no matching buff active"), "observed")
end

local CHECKS = {
  enchants = function(rule, profile)
    return hasEnchants(rule, profile.enchants)
  end,
  buff = function(rule, profile)
    return hasBuff(rule, profile.buffs)
  end,
  level = function(rule, profile)
    return atLeast(rule, profile.level, L("level"), L("no level data"))
  end,
  ilvl = function(rule, profile)
    return atLeast(rule, profile.ilvl, L("item level"), L("no item level data"))
  end,
  profession = function(rule, profile)
    return hasProfession(rule, profile.professions)
  end,
  field = function(rule, profile)
    local field = profile.fields and profile.fields[rule.field]
    if not field then
      return result(rule, "unknown", L("%s not declared"):format(rule.field))
    end
    return result(rule, "met", field.value, field.source)
  end,
  confirm = function(rule, _, readiness)
    local state = readiness[rule.id]
    if not state or state.status == "unknown" then
      return result(rule, "unknown", L("not confirmed"))
    end
    return result(rule, state.status, L("confirmed by player"), state.source)
  end,
}

function ReadinessService.EvaluateRule(rule, profile, readiness)
  local check = CHECKS[rule.check]
  if not check then
    return result(rule, "unknown", L("unsupported rule"))
  end
  return check(rule, profile or {}, readiness or {})
end

-- Returns the per-rule results and a summary { met, countable, unknown, text }.
-- notApplicable and waived rules are shown but leave the denominator.
function ReadinessService.Evaluate(rules, profile, readiness)
  local results = {}
  local summary = { met = 0, countable = 0, unknown = 0 }

  for _, rule in ipairs(rules) do
    local outcome = ReadinessService.EvaluateRule(rule, profile, readiness)
    results[#results + 1] = outcome
    if outcome.status ~= "notApplicable" and outcome.status ~= "waived" then
      summary.countable = summary.countable + 1
    end
    if outcome.status == "met" then
      summary.met = summary.met + 1
    elseif outcome.status == "unknown" then
      summary.unknown = summary.unknown + 1
    end
  end

  summary.text = L("%d/%d met"):format(summary.met, summary.countable)
  if summary.unknown > 0 then
    summary.text = summary.text .. L(", %d unknown"):format(summary.unknown)
  end
  return results, summary
end

-- Returns true, or false plus "unknown_rule" | "not_manual" | "invalid_status".
function ReadinessService.SetManual(platform, rules, readiness, ruleId, status)
  local target
  for _, rule in ipairs(rules) do
    if rule.id == ruleId then
      target = rule
      break
    end
  end
  if not target then
    return false, "unknown_rule"
  end
  if target.check ~= "confirm" then
    return false, "not_manual"
  end
  if not MANUAL_STATUSES[status] then
    return false, "invalid_status"
  end

  if status == "unknown" then
    readiness[ruleId] = nil
  else
    readiness[ruleId] = { status = status, source = "declared", at = platform.ServerTime() }
  end
  return true
end

function ReadinessService.Describe(results, summary)
  local lines = { L("Readiness: %s"):format(summary.text) }
  for _, outcome in ipairs(results) do
    lines[#lines + 1] = ("  [%s] %s - %s"):format(
      ReadinessService.StatusText(outcome.status),
      outcome.label,
      outcome.detail
    )
  end
  return lines
end

ns.ReadinessService = ReadinessService
