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
    say(ok and "profile published to the guild." or ("not published: " .. ns.ViewModel.PublishError(reason)))
    return
  end

  ns.ProfileService.Refresh(ns.Platform, character.profile)
  for _, line in ipairs(ns.PublishService.Describe(character.profile, character.consent)) do
    print(line)
  end
  say("Addon messages are not private: any guild member with the addon can read them.")
  say("Type /nrage publish confirm to send.")
end

local SYNC_REQUEST_ERRORS = {
  cooldown = "you asked a moment ago, wait a little.",
  full = "the send queue is full, try again shortly.",
}

local function SyncCommand(rest)
  if not ns.active or not ns.comm then
    say("sync is unavailable while the addon is disabled.")
    return
  end
  if rest == "request" then
    local ok, reason = ns.comm:RequestSync()
    say(ok and "asked the guild for the latest raid data; leaders answer by whisper."
      or ("not requested: " .. (SYNC_REQUEST_ERRORS[reason] or tostring(reason))))
    return
  end
  for _, line in ipairs(ns.comm:Status()) do
    print(line)
  end
end

local function RoleCommand()
  if not ns.active then
    say("roles are unavailable while the addon is disabled.")
    return
  end
  local rank = ns.Platform.GetOwnGuildRank()
  local role = ns.PermissionService.OwnRole(ns.Platform)
  local identityKey = ns.Platform.GetIdentityKey()
  say(("%s - guild rank: %s -> addon role: %s"):format(identityKey, tostring(rank), tostring(role)))
  if role == "admin" and ns.PermissionService.IsBetaAdmin(identityKey) then
    print("  beta admin exception: active (temporary, tracked in issue #25)")
  end
  for _, action in ipairs({ "manage_events", "record_attendance", "manage_assignments", "moderate" }) do
    print(("  %s: %s"):format(action, ns.PermissionService.Can(role, action) and "allowed" or "not allowed"))
  end
end

local function PrintRoster()
  local roster = ns.guildRoster
  if not roster then
    say("guild roster not started (addon disabled).")
    return
  end
  local identityKey = ns.Platform.GetIdentityKey()
  say(("guild roster: %d members, ready=%s"):format(roster:Count(), tostring(roster:IsReady())))
  print(("  own key '%s': %s"):format(identityKey, roster:Lookup(identityKey) and "found" or "NOT found"))
  print(("  UnitName gives '%s'; found in the roster by GUID as '%s'"):format(
    tostring(ns.Platform.GetPlayerName()), tostring(roster.ownName)))
  local shown = 0
  for name, entry in pairs(roster.entries) do
    print(("  e.g. '%s' rank '%s'"):format(name, tostring(entry.rankName)))
    shown = shown + 1
    if shown >= 3 then
      break
    end
  end
end

-- The last addon messages received, as the client delivered the sender, and whether the roster knows them.
local function PrintSenders()
  if not ns.comm then
    say("no sync yet (addon disabled).")
    return
  end
  local recent = ns.comm.recentSenders
  if #recent == 0 then
    say("no addon messages received yet. Ask another member with the addon to log in or run /nrage sync request.")
    return
  end
  say(("last %d sender(s), raw -> read as -> roster:"):format(#recent))
  for _, entry in ipairs(recent) do
    local known = ns.guildRoster and ns.guildRoster:Lookup(entry.name)
    print(("  '%s' -> '%s' -> %s"):format(entry.raw, entry.name,
      known and ("found, rank '" .. tostring(known.rankName) .. "'") or "NOT found"))
  end
end

local function HelpCommand()
  say("commands:")
  for _, line in ipairs(ns.ViewModel.HelpLines()) do
    print("  " .. line)
  end
end

local function TransferCommand(mode)
  return function()
    if not ns.active or not ns.character then
      say("export and import are unavailable while the addon is disabled.")
      return
    end
    ns.UI.ShowTransfer(mode)
  end
end

-- Builds the raid command handler for `method` (Event, Attendance or Assign).
local function RaidCommand(method)
  return function(rest)
    if not ns.active or not ns.comm then
      say("raid commands are unavailable while the addon is disabled.")
      return
    end
    local raid = ns.RaidCommands.New({
      events = ns.db.global.events,
      tombstones = ns.db.global.sync.tombstones,
      platform = ns.Platform,
      comm = ns.comm,
    })
    for _, line in ipairs(raid[method](raid, rest)) do
      print(line)
    end
  end
end

local function LootCommand(rest)
  if not ns.active or not ns.comm then
    say("loot commands are unavailable while the addon is disabled.")
    return
  end
  local loot = ns.LootCommands.New({
    events = ns.db.global.events,
    platform = ns.Platform,
    comm = ns.comm,
  })
  for _, line in ipairs(loot:Loot(rest)) do
    print(line)
  end
end

local function TemplateCommand(rest)
  if not ns.active or not ns.comm then
    say("templates are unavailable while the addon is disabled.")
    return
  end
  local templates = ns.TemplateCommands.New({
    events = ns.db.global.events,
    templates = ns.db.global.templates,
    platform = ns.Platform,
    comm = ns.comm,
  })
  for _, line in ipairs(templates:Template(rest)) do
    print(line)
  end
end

local function ReportCommand(rest)
  if not ns.active or not ns.db then
    say("reports are unavailable while the addon is disabled.")
    return
  end
  local reports = ns.ReportCommands.New({ events = ns.db.global.events })
  for _, line in ipairs(reports:Report(rest)) do
    print(line)
  end
end

local COMMANDS = {
  help = HelpCommand,
  report = ReportCommand,
  template = TemplateCommand,
  loot = LootCommand,
  export = TransferCommand("export"),
  import = TransferCommand("import"),
  event = RaidCommand("Event"),
  attendance = RaidCommand("Attendance"),
  assign = RaidCommand("Assign"),
  version = function()
    say(("version %s"):format(ns.GetVersion()))
  end,
  role = RoleCommand,
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
    elseif sub == "roster" then
      PrintRoster()
    elseif sub == "senders" then
      PrintSenders()
    elseif sub == "selftest" then
      local results, summary = ns.Diagnostics.SelfTest(_G, ns)
      for _, line in ipairs(ns.Diagnostics.DescribeSelfTest(results, summary)) do
        print(line)
      end
    elseif sub == "info" then
      for _, line in ipairs(ns.Diagnostics.Info(ns)) do
        print(line)
      end
    else
      say("usage: /nrage debug identity | roster | senders | selftest | info | lockdown <action>")
    end
  end,
}

SLASH_NRAGE1 = "/nrage"
SlashCmdList.NRAGE = function(msg)
  local command, rest = msg:match("^(%S*)%s*(.-)$")
  local handler = COMMANDS[command]
  if handler then
    handler(rest)
  elseif command == "" then
    if ns.active then
      ns.UI.Toggle()
    else
      say(("version %s (addon disabled, see the notice shown at login)"):format(ns.GetVersion()))
    end
  else
    say(("unknown command '%s'. Type /nrage help."):format(command))
  end
end
