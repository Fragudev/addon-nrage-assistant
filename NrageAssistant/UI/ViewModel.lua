local _, ns = ...

-- Pure presentation logic for the window: turns state into lines of text. No frames, no client API,
-- so it is unit tested. Received data is escaped again here as a second line of defence.
local ViewModel = {}

-- "|" starts colour codes, links and textures in the client's text renderer.
function ViewModel.Escape(text)
  return (tostring(text):gsub("|", "||"))
end

-- args: version, syncLines (Comm:Status()), readinessText (summary.text)
function ViewModel.Home(args)
  local lines = { ("Nrage Assistant %s"):format(args.version), "" }
  lines[#lines + 1] = "Your readiness: " .. args.readinessText
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Sync:"
  for _, line in ipairs(args.syncLines) do
    lines[#lines + 1] = "  " .. ViewModel.Escape(line)
  end
  return lines
end

local function classText(entry)
  return ("%s %s"):format(ViewModel.Escape(entry.class), ViewModel.Escape(entry.level))
end

-- Received profiles, sorted by name. Data older than ROSTER_STALE_SECONDS is labelled stale
-- instead of verified-looking; nothing received is ever shown as verified.
function ViewModel.Roster(roster, now)
  local names = {}
  for name in pairs(roster) do
    names[#names + 1] = name
  end
  table.sort(names)

  if #names == 0 then
    return { "No profiles received yet. Members appear here once they publish theirs." }
  end

  local lines = { ("%d profile(s) received:"):format(#names) }
  for _, name in ipairs(names) do
    local entry = roster[name]
    local age = now - (entry.receivedAt or 0)
    local label = age > ns.Constants.ROSTER_STALE_SECONDS and "stale" or "received"

    local text = ("%s - %s"):format(ViewModel.Escape(name), classText(entry))
    if entry.ilvl then
      text = text .. (", ilvl %s"):format(ViewModel.Escape(entry.ilvl))
    end
    local role = entry.fields and entry.fields.role
    if role then
      text = text .. (", role %s"):format(ViewModel.Escape(role))
    end
    lines[#lines + 1] = ("  %s [%s]"):format(text, label)
  end
  return lines
end

local PUBLISH_ERRORS = {
  no_consent = "profile consent is off. Use /nrage consent profile on.",
  missing_data = "class or level is unknown, nothing to share yet.",
  cooldown = "you published a moment ago, wait a little.",
  full = "the send queue is full, try again shortly.",
  too_large = "the profile is too large to send.",
  encode_failed = "the profile could not be encoded.",
}

function ViewModel.PublishError(reason)
  return PUBLISH_ERRORS[reason] or tostring(reason)
end

ViewModel.TABS = {
  { value = "home", text = "Home" },
  { value = "profile", text = "Profile" },
  { value = "ready", text = "Readiness" },
  { value = "roster", text = "Roster" },
}

function ViewModel.HelpLines()
  return {
    "/nrage               open the window",
    "/nrage help          this list",
    "/nrage version       addon version",
    "/nrage role          your guild rank, addon role and what it allows",
    "/nrage profile       show your profile (profile set <role|main|notes> <text>)",
    "/nrage ready         readiness checklist (ready set <item> <met|missing|waived|unknown>)",
    "/nrage consent       what you agree to share (consent <key> on|off)",
    "/nrage publish       preview, then 'publish confirm' to share your profile",
    "/nrage event         raid events (event new <title> | rename | status | delete)",
    "/nrage attendance    attendance for an event (attendance <n> <Name-Realm> <state>)",
    "/nrage assign        assignments for an event (assign <n> add <Name-Realm> <encounter>)",
    "/nrage export        copy all raid events, attendance and assignments as text",
    "/nrage import        paste an export to merge it into your data (RL/admin only)",
    "/nrage sync          sync state and peers (sync request: ask leaders for the latest raid data)",
  }
end

ns.ViewModel = ViewModel
