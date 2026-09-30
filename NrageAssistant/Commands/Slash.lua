local _, ns = ...

local PREFIX = "|cff33ff99Nrage Assistant|r"

local function say(text)
  print(PREFIX .. " " .. text)
end

local function PrintIdentity()
  local P = ns.Platform
  say("identity (phase 0 measurement):")
  print("  build: " .. tostring(select(4, GetBuildInfo())))
  print("  realm: " .. tostring(P.GetRealmName()))
  print("  guild: " .. tostring(P.GetGuildName()))
  print("  clubId: " .. tostring(P.GetGuildClubId()))
  print("  faction: " .. tostring(P.GetFaction()))
  print("  lockdown: " .. tostring(P.IsChatMessagingLockedDown()))
end

local SET_ERRORS = {
  unknown_field = "unknown field. Allowed: role, main, notes.",
  too_long = "value is too long.",
  invalid_value = "invalid value.",
}

local function ProfileCommand(rest)
  if not ns.active or not ns.character then
    say("the profile is unavailable while the addon is disabled.")
    return
  end

  local profile = ns.character.profile
  local sub, key, value = rest:match("^(%S*)%s*(%S*)%s*(.-)$")
  if sub == "set" then
    local ok, reason = ns.ProfileService.SetField(ns.Platform, profile, key, value)
    if not ok then
      say(SET_ERRORS[reason])
      return
    end
  end

  ns.ProfileService.Refresh(ns.Platform, profile)
  say("profile:")
  for _, line in ipairs(ns.ProfileService.Describe(profile)) do
    print("  " .. line)
  end
end

local READY_SET_ERRORS = {
  unknown_rule = "unknown item.",
  not_manual = "that item is measured automatically and cannot be set by hand.",
  invalid_status = "status must be met, missing, waived or unknown.",
}

local function ReadyCommand(rest)
  if not ns.active or not ns.character then
    say("readiness is unavailable while the addon is disabled.")
    return
  end

  local rules = ns.Constants.DEFAULT_RULES
  local readiness = ns.character.readiness
  local sub, ruleId, status = rest:match("^(%S*)%s*(%S*)%s*(%S*)")
  if sub == "set" then
    local ok, reason = ns.ReadinessService.SetManual(ns.Platform, rules, readiness, ruleId, status)
    if not ok then
      say(READY_SET_ERRORS[reason])
      return
    end
  end

  ns.ProfileService.Refresh(ns.Platform, ns.character.profile)
  local results, summary = ns.ReadinessService.Evaluate(rules, ns.character.profile, readiness)
  for _, line in ipairs(ns.ReadinessService.Describe(results, summary)) do
    print(line)
  end
end

local COMMANDS = {
  profile = ProfileCommand,
  ready = ReadyCommand,
  debug = function(rest)
    local sub, action = rest:match("^(%S*)%s*(%S*)")
    if sub == "identity" then
      PrintIdentity()
    elseif sub == "lockdown" then
      ns.Probe.Handle(action)
    else
      say("usage: /nrage debug identity | lockdown <action>")
    end
  end,
}

SLASH_NRAGE1 = "/nrage"
SlashCmdList.NRAGE = function(msg)
  local command, rest = msg:match("^(%S*)%s*(.-)$")
  local handler = COMMANDS[command]
  if handler then
    handler(rest)
    return
  end
  say(("version %s"):format(ns.GetVersion()))
end
