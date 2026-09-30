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

local PUBLISH_ERRORS = {
  no_consent = "profile consent is off. Use /nrage consent profile on.",
  missing_data = "class or level is unknown, nothing to share yet.",
  cooldown = "you published a moment ago, wait a little.",
  full = "the send queue is full, try again shortly.",
  too_large = "the profile is too large to send.",
  encode_failed = "the profile could not be encoded.",
}

local function ConsentCommand(rest)
  if not ns.active or not ns.character then
    say("consent is unavailable while the addon is disabled.")
    return
  end

  local consent = ns.character.consent
  local key, value = rest:match("^(%S*)%s*(%S*)")
  if key ~= "" then
    if value ~= "on" and value ~= "off" then
      say("usage: /nrage consent <profile|gear|professions|notes> <on|off>")
      return
    end
    if not ns.PublishService.SetConsent(consent, key, value == "on") then
      say("unknown item. Allowed: profile, gear, professions, notes.")
      return
    end
  end

  say("sharing consent:")
  for _, name in ipairs(ns.PublishService.CONSENT_KEYS) do
    print(("  %s: %s"):format(name, consent[name] and "on" or "off"))
  end
end

local function PublishCommand(rest)
  if not ns.active or not ns.character or not ns.comm then
    say("publishing is unavailable while the addon is disabled.")
    return
  end

  local character = ns.character
  if rest == "confirm" then
    ns.ProfileService.Refresh(ns.Platform, character.profile)
    local ok, reason = ns.PublishService.Publish(ns.comm, character, ns.Platform)
    say(ok and "profile published to the guild." or ("not published: " .. (PUBLISH_ERRORS[reason] or reason)))
    return
  end

  ns.ProfileService.Refresh(ns.Platform, character.profile)
  for _, line in ipairs(ns.PublishService.Describe(character.profile, character.consent)) do
    print(line)
  end
  say("Addon messages are not private: any guild member with the addon can read them.")
  say("Type /nrage publish confirm to send.")
end

local function SyncCommand()
  if not ns.active or not ns.comm then
    say("sync is unavailable while the addon is disabled.")
    return
  end
  for _, line in ipairs(ns.comm:Status()) do
    print(line)
  end
end

local COMMANDS = {
  profile = ProfileCommand,
  ready = ReadyCommand,
  sync = SyncCommand,
  consent = ConsentCommand,
  publish = PublishCommand,
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
