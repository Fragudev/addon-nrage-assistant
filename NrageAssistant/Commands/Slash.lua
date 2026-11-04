local _, ns = ...

local L = ns.L

local PREFIX = "|cffff0019Nrage Assistant|r"

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
    say("no addon messages received yet. Ask another member with the addon to log in.")
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

-- The interim PvP season commands (PvPSeasonCommands): they print what the service answers.
local function PvPCommand(rest)
  if not (ns.active and ns.pvpSeasonCommands) then
    say(L("version %s (addon disabled, see the notice shown at login)"):format(ns.GetVersion()))
    return
  end
  for _, line in ipairs(ns.pvpSeasonCommands:Run(rest)) do
    print(line)
  end
end

local COMMANDS = {
  help = HelpCommand,
  pvp = PvPCommand,
  debug = function(rest)
    local sub, action = rest:match("^(%S*)%s*(%S*)")
    if sub == "identity" then
      PrintIdentity()
    elseif sub == "lockdown" then
      ns.Probe.Handle(action)
    elseif sub == "pvp" then
      ns.PvPProbe.Handle(action)
    elseif sub == "layer" then
      ns.LayerProbe.Handle(action)
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
    elseif sub == "sync" then
      -- Troubleshooting only: sync is automatic, so the window has no button for this.
      if ns.comm then
        say(ns.ViewModel.SyncRequestResult(ns.comm:RequestSync()))
      else
        say("no sync yet (addon disabled).")
      end
    elseif sub == "publish" then
      -- Troubleshooting only: the profile is published by itself whenever it changes.
      if ns.comm and ns.character then
        local ok, reason = ns.PublishService.Publish(ns.comm, ns.character, ns.Platform)
        say(ok and "profile published." or ("not published: " .. ns.ViewModel.PublishError(reason)))
      else
        say("no sync yet (addon disabled).")
      end
    else
      say(
        "usage: /nrage debug identity | roster | senders | selftest | info | sync | publish | lockdown <action>"
          .. " | pvp <action> | layer <action>"
      )
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
      say(L("version %s (addon disabled, see the notice shown at login)"):format(ns.GetVersion()))
    end
  else
    say(L("unknown command '%s'. Type /nrage help."):format(command))
  end
end
