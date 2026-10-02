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
  if sub == "set" and ns.comm then
    ns.PublishService.PublishIfChanged(ns.comm, ns.character, ns.Platform)
  end
  say("profile:")
  for _, line in ipairs(ns.ProfileService.Describe(profile)) do
    print("  " .. line)
  end
end

local function ReadyCommand(rest)
  if not ns.active or not ns.character then
    say("readiness is unavailable while the addon is disabled.")
    return
  end

  local rules = ns.ReadinessRules.Current()
  local readiness = ns.character.readiness
  local sub, ruleId, status = rest:match("^(%S*)%s*(%S*)%s*(%S*)")
  if sub == "rules" then
    if ruleId == "default" then
      -- Admin only: puts the starting checklist back as the guild's rules.
      local ok, reason = ns.comm:SetReadinessRules(ns.Constants.DEFAULT_RULES)
      say(ok and "the guild rules were reset to the starting checklist." or ("could not set the rules: " .. reason))
      return
    end
    for _, line in ipairs(ns.ReadinessRules.Describe(ns.db.global.readinessRules)) do
      print(line)
    end
    return
  end
  if sub == "set" then
    local ok, reason = ns.ReadinessService.SetManual(ns.Platform, rules, readiness, ruleId, status)
    if not ok then
      say(ns.ViewModel.READY_SET_ERRORS[reason])
      return
    end
  end

  ns.ProfileService.Refresh(ns.Platform, ns.character.profile)
  local results, summary = ns.ReadinessService.Evaluate(rules, ns.character.profile, readiness)
  for _, line in ipairs(ns.ReadinessService.Describe(results, summary)) do
    print(line)
  end
end

local function PublishCommand(rest)
  if not ns.active or not ns.character or not ns.comm then
    say("publishing is unavailable while the addon is disabled.")
    return
  end

  local character = ns.character
  ns.ProfileService.Refresh(ns.Platform, character.profile)
  if rest == "now" then
    local ok, reason = ns.PublishService.Publish(ns.comm, character, ns.Platform)
    say(ok and "profile published to the guild." or ("not published: " .. ns.ViewModel.PublishError(reason)))
    return
  end

  for _, line in ipairs(ns.PublishService.Describe(character.profile)) do
    print(line)
  end
  say("Your profile is shared automatically after login and whenever it changes.")
  say("/nrage publish now sends it at once.")
  say("Addon messages are not private: any guild member with the addon can read them.")
end

local function SyncCommand(rest)
  if not ns.active or not ns.comm then
    say("sync is unavailable while the addon is disabled.")
    return
  end
  if rest == "request" then
    say(ns.ViewModel.SyncRequestResult(ns.comm:RequestSync()))
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
  print(
    ("  UnitName gives '%s'; found in the roster by GUID as '%s'"):format(
      tostring(ns.Platform.GetPlayerName()),
      tostring(roster.ownName)
    )
  )
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
    print(
      ("  '%s' -> '%s' -> %s"):format(
        entry.raw,
        entry.name,
        known and ("found, rank '" .. tostring(known.rankName) .. "'") or "NOT found"
      )
    )
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
    onChange = ns.UI.LootChanged,
  })
  for _, line in ipairs(loot:Loot(rest)) do
    print(line)
  end
end

local function MinimapCommand(rest)
  if not ns.active or not ns.db then
    say("the minimap button is unavailable while the addon is disabled.")
    return
  end
  say(ns.MinimapButton.Command(ns.db, rest:match("^(%S*)")))
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

local PVP_RESET_ERRORS = {
  forbidden = "only an admin can reset PvP counters.",
  stale = "that member was already reset (or a later reset is known).",
  limit = "too many resets are remembered.",
  bad_target = "that is not a valid member name.",
}

-- /nrage pvp reset <name>: zeroes the PvP counters of a guild member on every client (admin only).
local function PvPCommand(rest)
  if not ns.active or not ns.comm then
    say("PvP commands are unavailable while the addon is disabled.")
    return
  end
  local sub, name = rest:match("^(%S*)%s*(.-)$")
  if sub ~= "reset" or name == "" then
    say("usage: /nrage pvp reset <name>  (admin only; names with spaces are fine)")
    return
  end
  name = ns.Platform.NormalizeName(name)
  if not (ns.guildRoster and ns.guildRoster:Lookup(name)) then
    say(("'%s' is not in the guild roster."):format(name))
    return
  end
  local ok, rev, sent = ns.comm:ResetPvP(name)
  if not ok then
    say("not reset: " .. (PVP_RESET_ERRORS[rev] or tostring(rev)))
    return
  end
  say(("PvP counters of %s reset (revision %d)%s."):format(name, rev, sent and ", told to the guild" or ", NOT sent"))
end

local function BlacklistCommand(rest)
  if not ns.active or not ns.comm then
    say("the blacklist is unavailable while the addon is disabled.")
    return
  end
  local blacklist = ns.BlacklistCommands.New({
    blacklist = ns.db.global.blacklist,
    tombstones = ns.db.global.sync.tombstones,
    platform = ns.Platform,
    comm = ns.comm,
    onChange = ns.BlacklistChanged,
  })
  for _, line in ipairs(blacklist:Blacklist(rest)) do
    print(line)
  end
end

local COMMANDS = {
  help = HelpCommand,
  blacklist = BlacklistCommand,
  pvp = PvPCommand,
  report = ReportCommand,
  template = TemplateCommand,
  minimap = MinimapCommand,
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
  publish = PublishCommand,
  debug = function(rest)
    local sub, action = rest:match("^(%S*)%s*(%S*)")
    if sub == "identity" then
      PrintIdentity()
    elseif sub == "lockdown" then
      ns.Probe.Handle(action)
    elseif sub == "pvp" then
      ns.PvPProbe.Handle(action)
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
      say("usage: /nrage debug identity | roster | senders | selftest | info | lockdown <action> | pvp <action>")
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
