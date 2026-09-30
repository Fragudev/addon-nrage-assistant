local _, ns = ...

-- Readiness checklist. Each rule resolves to one status:
--   met | missing | unknown | notApplicable | waived
-- `unknown` (no data, or a manual item nobody confirmed) never counts as met, and the score always
-- shows its denominator.
local ReadinessService = {}

-- Statuses a player may set by hand on a `confirm` rule. "unknown" clears the confirmation.
local MANUAL_STATUSES = { met = true, missing = true, waived = true, unknown = true }

local function result(rule, status, detail, source)
  return {
    ruleId = rule.id,
    label = rule.label,
    category = rule.category,
    evidenceMode = rule.evidenceMode,
    status = status,
    detail = detail,
    source = source,
  }
end

local function atLeast(rule, value, name)
  if value == nil then
    return result(rule, "unknown", "no " .. name .. " data")
  end
  local detail = ("%s %s (needs %s)"):format(name, tostring(value), tostring(rule.min))
  return result(rule, value >= rule.min and "met" or "missing", detail, "observed")
end

local function hasProfession(rule, professions)
  if professions == nil then
    return result(rule, "unknown", "no profession data")
  end
  for _, profession in ipairs(professions) do
    if profession.name:lower() == rule.profession:lower() then
      local detail = ("%s %s"):format(profession.name, tostring(profession.skill))
      if rule.min and (profession.skill or 0) < rule.min then
        return result(rule, "missing", ("%s (needs %s)"):format(detail, rule.min), "observed")
      end
      return result(rule, "met", detail, "observed")
    end
  end
  return result(rule, "missing", rule.profession .. " not learned", "observed")
end

local CHECKS = {
  level = function(rule, profile)
    return atLeast(rule, profile.level, "level")
  end,
  ilvl = function(rule, profile)
    return atLeast(rule, profile.ilvl, "item level")
  end,
  profession = function(rule, profile)
    return hasProfession(rule, profile.professions)
  end,
  field = function(rule, profile)
    local field = profile.fields and profile.fields[rule.field]
    if not field then
      return result(rule, "unknown", rule.field .. " not declared")
    end
    return result(rule, "met", field.value, field.source)
  end,
  confirm = function(rule, _, readiness)
    local state = readiness[rule.id]
    if not state or state.status == "unknown" then
      return result(rule, "unknown", "not confirmed")
    end
    return result(rule, state.status, "confirmed by player", state.source)
  end,
}

function ReadinessService.EvaluateRule(rule, profile, readiness)
  local check = CHECKS[rule.check]
  if not check then
    return result(rule, "unknown", "unsupported rule")
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

  summary.text = ("%d/%d met"):format(summary.met, summary.countable)
  if summary.unknown > 0 then
    summary.text = summary.text .. (", %d unknown"):format(summary.unknown)
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
  local lines = { ("Readiness: %s"):format(summary.text) }
  for _, outcome in ipairs(results) do
    lines[#lines + 1] = ("  [%s] %s - %s"):format(outcome.status, outcome.label, outcome.detail)
  end
  return lines
end

ns.ReadinessService = ReadinessService
