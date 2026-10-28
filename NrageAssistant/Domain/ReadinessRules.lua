local _, ns = ...

-- The readiness rules of each roster, edited by gm, cogm and the rl of that roster and shared like the other guild
-- data. `db.global.readinessRulesByRoster[rosterId]` holds { rev, updatedAt, updatedBy, rules }; a roster without a
-- record uses the starting checklist (Constants.DEFAULT_RULES). The old guild-wide `db.global.readinessRules` is only
-- read by the migration that copies it into every roster.
--
-- A rule is plain data and is validated whole, both when an admin sets it and when one arrives from the guild:
--   id (unique, short), label, check, plus what the check needs:
--     field       field = a manual profile field (Constants.MANUAL_FIELDS)
--     confirm     nothing; the player confirms it by hand
--     level|ilvl  min = 1..999
--     profession  profession = name, min = 0..1000 (optional)
--     enchants    slots = equipment slots 1..18
--     buff        spellIds and/or names, one of them has to be active
-- `category` is optional text; `evidenceMode` is worked out from the check (manual for field and confirm, observed
-- for the rest), never taken from the input.
local ReadinessRules = {}

local L = ns.L

local isInt, isText = ns.Validate.Int, ns.Validate.Text

local MAX_ID, MAX_LABEL, MAX_CATEGORY, MAX_NAME = 32, 60, 20, 60
local MAX_LIST = 20

local MANUAL_CHECKS = { field = true, confirm = true }

local function intList(list, low, high)
  if type(list) ~= "table" or #list == 0 or #list > MAX_LIST then
    return nil
  end
  local clean = {}
  for index, value in ipairs(list) do
    if not isInt(value, low, high) then
      return nil
    end
    clean[index] = value
  end
  return clean
end

local function textList(list)
  if type(list) ~= "table" or #list == 0 or #list > MAX_LIST then
    return nil
  end
  local clean = {}
  for index, value in ipairs(list) do
    if not isText(value, MAX_NAME) then
      return nil
    end
    clean[index] = value
  end
  return clean
end

-- What each check needs; each returns the check's own fields, or nil when the rule is unusable.
local DETAILS = {
  field = function(rule)
    if type(rule.field) ~= "string" or not ns.Constants.MANUAL_FIELDS[rule.field] then
      return nil
    end
    return { field = rule.field }
  end,
  confirm = function()
    return {}
  end,
  level = function(rule)
    return isInt(rule.min, 1, 999) and { min = rule.min } or nil
  end,
  ilvl = function(rule)
    return isInt(rule.min, 1, 999) and { min = rule.min } or nil
  end,
  profession = function(rule)
    if not isText(rule.profession, MAX_NAME) then
      return nil
    end
    if rule.min ~= nil and not isInt(rule.min, 0, 1000) then
      return nil
    end
    return { profession = rule.profession, min = rule.min }
  end,
  enchants = function(rule)
    local slots = intList(rule.slots, 1, 18)
    return slots and { slots = slots } or nil
  end,
  buff = function(rule)
    local details = {}
    if rule.spellIds ~= nil then
      details.spellIds = intList(rule.spellIds, 1, 9999999)
      if not details.spellIds then
        return nil
      end
    end
    if rule.names ~= nil then
      details.names = textList(rule.names)
      if not details.names then
        return nil
      end
    end
    if not (details.spellIds or details.names) then
      return nil
    end
    return details
  end,
}

-- One clean rule, or nil plus "bad_id" | "bad_label" | "bad_category" | "bad_check" | "bad_details".
function ReadinessRules.ValidateRule(rule)
  if type(rule) ~= "table" then
    return nil, "bad_check"
  end
  if not (isText(rule.id, MAX_ID) and rule.id:find("^[%w_]+$")) then
    return nil, "bad_id"
  end
  if not isText(rule.label, MAX_LABEL) then
    return nil, "bad_label"
  end
  if rule.category ~= nil and not isText(rule.category, MAX_CATEGORY) then
    return nil, "bad_category"
  end
  local details = type(rule.check) == "string" and DETAILS[rule.check]
  if not details then
    return nil, "bad_check"
  end
  local extra = details(rule)
  if not extra then
    return nil, "bad_details"
  end
  local clean = {
    id = rule.id,
    label = rule.label,
    category = rule.category,
    check = rule.check,
    evidenceMode = MANUAL_CHECKS[rule.check] and "manual" or "observed",
  }
  for key, value in pairs(extra) do
    clean[key] = value
  end
  return clean
end

-- A clean list of rules, or nil plus a reason ("empty" | "too_many" | "duplicate_id" | a ValidateRule reason).
function ReadinessRules.Validate(rules)
  if type(rules) ~= "table" or #rules == 0 then
    return nil, "empty"
  end
  if #rules > ns.Constants.READINESS_RULES_MAX then
    return nil, "too_many"
  end
  local clean, seen = {}, {}
  for index, rule in ipairs(rules) do
    local one, reason = ReadinessRules.ValidateRule(rule)
    if not one then
      return nil, reason
    end
    if seen[one.id] then
      return nil, "duplicate_id"
    end
    seen[one.id] = true
    clean[index] = one
  end
  return clean
end

-- The rules in force: the guild's, or the starting checklist while none were set.
function ReadinessRules.Active(record)
  if type(record) == "table" and type(record.rules) == "table" and #record.rules > 0 then
    return record.rules
  end
  return ns.Constants.DEFAULT_RULES
end

-- The record of a roster in this client's saved data, or nil.
function ReadinessRules.Record(rosterId)
  local byRoster = ns.db and ns.db.global.readinessRulesByRoster
  return rosterId ~= nil and byRoster and byRoster[rosterId] or nil
end

-- The rules of a roster in this client's saved data: its own, or the starting checklist while it has none. Without a
-- roster there is nothing to measure against: an empty list.
function ReadinessRules.Current(rosterId)
  if rosterId == nil then
    return {}
  end
  return ReadinessRules.Active(ReadinessRules.Record(rosterId))
end

-- One line per rule, for the command that shows them.
function ReadinessRules.Describe(record)
  local rules = ReadinessRules.Active(record)
  local custom = rules ~= ns.Constants.DEFAULT_RULES
  local lines = {
    custom and L("Roster rules, revision %d:"):format(record.rev or 0)
      or L("Starting rules (none set for this roster):"),
  }
  for _, rule in ipairs(rules) do
    lines[#lines + 1] = ("  %s - %s [%s]"):format(rule.id, rule.label, rule.check)
  end
  return lines
end

ns.ReadinessRules = ReadinessRules
