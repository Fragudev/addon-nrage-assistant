local _, ns = ...

-- The slash commands of Intel (`/nrage intel ...`, alias `/nrage spy`; docs/PVP_INTEL_PLAN.md section 3.3). Each method
-- returns the lines to show, so the whole thing is testable without a client. The window and the settings are the
-- interface of the next phase: show, hide, config and stats call hooks of `ns.UI` that may not exist yet, and say so.
--
-- deps = { service, detector, publisher, sync, alerts, directory (all optional but service, alerts),
--          platform (GetIdentityKey, ServerTime, EnemyNameplatesEnabled, ...), settings = function() -> Settings.Intel,
--          guildKos = the guild list, tombstones, comm = function() -> Comm or nil, onChange = function() (optional),
--          ui = function() -> ns.UI, events = function() -> { [event] = registered },
--          zone = function() -> context, allowed, reason, season = function() -> the running PvP season or nil,
--          zoneName = function(map) -> text or nil, globals = function() -> _G,
--          toggleMinimap = function() -> true when the button is hidden now }
local IntelCommands = {}
IntelCommands.__index = IntelCommands

local L = ns.L
local Failure = ns.Validate.Failure

function IntelCommands.New(deps)
  return setmetatable({ deps = deps }, IntelCommands)
end

local ERRORS = ns.Locale.Table(function()
  return {
    bad_name = L("that is not a valid name."),
    bad_category = L("the category must be one of: gank, camp, corpse, objective, insult, other."),
    long_reason = L("the reason is too long (up to 100 characters)."),
    bad_reason = L("the reason cannot contain | or control characters."),
    limit = L("that list is full."),
    not_found = L("that player is not on the list."),
    forbidden = L("you are not allowed to do that."),
    not_author = L("that player is on the guild list already; only who added them, the GM or the CoGM can change it."),
    no_group = L("you are not in a group for that."),
    send_failed = L("the message could not be sent."),
    bad_channel = L("unknown channel."),
  }
end)

local function fail(reason)
  return Failure(ERRORS[reason] or tostring(reason))
end

local function words(text)
  local list = {}
  for word in text:gmatch("%S+") do
    list[#list + 1] = word
  end
  return list
end

local function join(list, from)
  return table.concat(list, " ", from)
end

function IntelCommands.Usage()
  return {
    L("/nrage intel show | hide | config | stats [season]  the window, the settings and the report"),
    L("/nrage intel kos [guild] <name> [category] [reason]  Kill on Sight (gank camp corpse objective insult other)"),
    L("/nrage intel kos [guild] remove <name> | kos list  remove or list"),
    L("/nrage intel ignore <name> | ignore remove <name> | ignore list  the Ignore list"),
    L("/nrage intel clear | reset  forget who is nearby, or everything met (reset asks for 'reset confirm')"),
    L("/nrage intel import spy | import [kos|ignore] <names>  bring in a list"),
    L("/nrage intel test | minimap | debug  an alert test, the minimap button and diagnostics"),
  }
end

-- Calls the hook `name` of the interface when it exists; says so when it does not.
function IntelCommands:Hook(name, label, ...)
  local ui = self.deps.ui and self.deps.ui()
  local hook = type(ui) == "table" and ui[name] or nil
  if type(hook) ~= "function" then
    return { L("the Intel %s is not available in this version yet."):format(label) }
  end
  local ok, err = pcall(hook, ...)
  if not ok then
    return Failure(L("the Intel %s failed: %s"):format(label, tostring(err)))
  end
  return {}
end

function IntelCommands:Changed()
  if self.deps.onChange then
    pcall(self.deps.onChange)
  end
end

-- Adds a note when a change was saved here but not queued for the guild.
local function sentNote(ok, reason)
  if ok then
    return nil
  end
  return L("saved here, but not sent to the guild (%s)."):format(tostring(reason))
end

-- The category and reason typed after a name: `args` is the list of words, `from` the position of the first one.
-- The first word is the category when it is one, and the rest is the reason. Returns category (nil when none was
-- typed), reason (nil when none was typed).
local function categoryAndReason(args, from)
  local first = args[from]
  if first and ns.IntelModel.CategoryValid(first:lower()) then
    local reason = join(args, from + 1)
    return first:lower(), reason ~= "" and reason or nil
  end
  local reason = first and join(args, from) or nil
  return nil, reason
end

function IntelCommands:KosList(scope)
  local list = self.deps.service:KosList(scope)
  if #list == 0 then
    if scope == "guild" then
      return { L("the guild Kill on Sight list is empty.") }
    end
    return { L("your Kill on Sight list is empty.") }
  end
  local lines = {
    (scope == "guild" and L("guild Kill on Sight (%d):") or L("your Kill on Sight (%d):")):format(#list),
  }
  for _, entry in ipairs(list) do
    local reason = entry.reason and (": " .. ns.IntelModel.Plain(entry.reason, ns.Constants.INTEL_REASON_MAX)) or ""
    lines[#lines + 1] = ("  %s [%s]%s"):format(ns.IntelModel.Plain(entry.name) or "?", tostring(entry.category), reason)
  end
  return lines
end

-- Adds `name` to the personal Kill on Sight list, or changes the category and reason of the one that is there. Returns
-- the lines to show.
function IntelCommands:KosAdd(name, category, reason)
  local service = self.deps.service
  local listed = service.intel.kos[ns.IntelModel.Key(name) or ""]
  local entry, key = service:AddKos({ name = name, category = category, reason = reason })
  if not entry then
    return fail(key)
  end
  self:Changed()
  return {
    (listed and L("changed %s on your Kill on Sight list.") or L("added %s to your Kill on Sight list.")):format(
      ns.IntelModel.Plain(entry.name)
    ),
  }
end

-- Takes `name` off the personal Kill on Sight list. Returns the lines to show.
function IntelCommands:KosRemove(name)
  local key = ns.IntelModel.Key(name or "")
  if not key or not self.deps.service:RemoveKos(key) then
    return fail("not_found")
  end
  self:Changed()
  return { L("removed %s from your Kill on Sight list."):format(ns.IntelModel.Plain(name)) }
end

function IntelCommands:Kos(args)
  local sub = args[1] and args[1]:lower()
  if sub == "guild" then
    return self:GuildKos(args)
  end
  if sub == nil or sub == "list" then
    return self:KosList("personal")
  end
  if sub == "remove" or sub == "del" then
    return self:KosRemove(args[2])
  end
  local category, reason = categoryAndReason(args, 2)
  return self:KosAdd(args[1], category, reason)
end

function IntelCommands:GuildContext()
  local platform = self.deps.platform
  return {
    guildKos = self.deps.guildKos,
    tombstones = self.deps.tombstones,
    role = ns.PermissionService.OwnRole(platform),
    actor = platform.GetIdentityKey(),
    now = platform.ServerTime,
  }
end

-- Takes `name` off the guild Kill on Sight list and tells the guild. Returns the lines to show.
function IntelCommands:GuildRemove(name)
  local entry, key = ns.GuildKosService.Find(self.deps.guildKos, name or "")
  if not entry then
    return fail("not_found")
  end
  local ok, reason = ns.GuildKosService.Remove(self:GuildContext(), key)
  if not ok then
    return fail(reason)
  end
  self:Changed()
  local comm = self.deps.comm and self.deps.comm()
  local sent, why = false, "no connection"
  if comm then
    sent, why = comm:SendGuildKosDelete(key)
  end
  return {
    L("removed %s from the guild Kill on Sight list."):format(ns.IntelModel.Plain(entry.name)),
    sentNote(sent, why),
  }
end

-- Adds `name` to the guild Kill on Sight list, or changes the category and reason of the one that is there. Without a
-- category or reason, a player of the personal list goes up with the ones he has (the promotion of the interface and
-- of `kos guild <name>`). Returns the lines to show.
function IntelCommands:GuildAdd(name, category, reason)
  if not category and not reason then
    local _, personal = self.deps.service:IsKos(name)
    if personal and self.deps.service.intel.kos[ns.IntelModel.Key(name) or ""] then
      category, reason = personal.category, personal.reason
    end
  end
  local entry, key, updated =
    ns.GuildKosService.Add(self:GuildContext(), { name = name, category = category, reason = reason })
  if not entry then
    return fail(key)
  end
  self:Changed()
  local comm = self.deps.comm and self.deps.comm()
  local sent, why = false, "no connection"
  if comm then
    sent, why = comm:SendGuildKosUpsert(key, entry)
  end
  local template = updated and L("changed %s on the guild Kill on Sight list.")
    or L("added %s to the guild Kill on Sight list.")
  return {
    template:format(ns.IntelModel.Plain(entry.name)),
    sentNote(sent, why),
  }
end

-- `args` = { "guild", ... }.
function IntelCommands:GuildKos(args)
  local sub = args[2] and args[2]:lower()
  if sub == nil or sub == "list" then
    return self:KosList("guild")
  end
  if sub == "remove" or sub == "del" then
    return self:GuildRemove(args[3])
  end
  local category, reason = categoryAndReason(args, 3)
  return self:GuildAdd(args[2], category, reason)
end

-- Puts `name` on the Ignore list. Returns the lines to show.
function IntelCommands:IgnoreAdd(name)
  local entry, key = self.deps.service:AddIgnore(name)
  if not entry then
    return fail(key)
  end
  self:Changed()
  return { L("ignoring %s: no alerts, not listed nearby, nothing shared."):format(ns.IntelModel.Plain(entry.name)) }
end

-- Takes `name` off the Ignore list. Returns the lines to show.
function IntelCommands:IgnoreRemove(name)
  local key = ns.IntelModel.Key(name or "")
  if not key or not self.deps.service:RemoveIgnore(key) then
    return fail("not_found")
  end
  self:Changed()
  return { L("%s is not ignored any more."):format(ns.IntelModel.Plain(name)) }
end

function IntelCommands:Ignore(args)
  local service = self.deps.service
  local sub = args[1] and args[1]:lower()
  if sub == nil or sub == "list" then
    local list = service:IgnoreList()
    if #list == 0 then
      return { L("your Ignore list is empty.") }
    end
    local names = {}
    for _, entry in ipairs(list) do
      names[#names + 1] = ns.IntelModel.Plain(entry.name) or "?"
    end
    return { L("ignored (%d): %s"):format(#list, table.concat(names, ", ")) }
  end
  if sub == "remove" or sub == "del" then
    return self:IgnoreRemove(args[2])
  end
  return self:IgnoreAdd(args[1])
end

function IntelCommands:Stats(args)
  local deps = self.deps
  local zoneName = deps.zoneName
  if args[1] and args[1]:lower() == "season" then
    local season = deps.season and deps.season()
    if not season then
      return { L("no PvP season is running.") }
    end
    local report = ns.IntelReport.Season(deps.service, season)
    return report and ns.IntelReport.Lines(report, zoneName) or { L("no PvP season is running.") }
  end
  local lines = ns.IntelReport.Lines(ns.IntelReport.Session(deps.service), zoneName)
  local counts = deps.service:Counts()
  lines[#lines + 1] = L("Saved: %d players met, %d on your Kill on Sight list, %d ignored."):format(
    counts.players,
    counts.kos,
    counts.ignore
  )
  for _, line in ipairs(self:Hook("IntelStats", L("statistics"))) do
    lines[#lines + 1] = line
  end
  return lines
end

function IntelCommands:Reset(args)
  if not (args[1] and args[1]:lower() == "confirm") then
    return {
      L("This forgets every enemy player met, their wins and losses, and the contact counts."),
      L("Your Kill on Sight and Ignore lists stay. Type '/nrage intel reset confirm' to go on."),
    }
  end
  self.deps.service:Reset()
  self:Clear()
  self:Changed()
  return { L("Intel records cleared.") }
end

-- Forgets who is nearby, including the sightings the guild shared.
function IntelCommands:Clear()
  local deps = self.deps
  deps.service:ClearNearby()
  if deps.directory then
    for _, entry in ipairs(deps.directory:List()) do
      deps.directory:Remove(entry.key)
    end
  end
end

-- Reports an import: the lines to show.
function IntelCommands:ImportReport(report)
  self:Changed()
  return {
    L("imported %d, skipped %d (already listed, not valid, or over the limit)."):format(report.added, report.skipped),
  }
end

-- Brings in the names of `text` (one per line or separated by commas) to the personal list `target` ("kos" or
-- "ignore"). Returns the lines to show.
function IntelCommands:ImportText(text, target)
  return self:ImportReport(ns.IntelImport.FromText(self.deps.service, text, target))
end

-- Brings in the lists of Spy when it is loaded. Returns the lines to show.
function IntelCommands:ImportSpy()
  local report = ns.IntelImport.FromSpy(self.deps.service, self.deps.globals and self.deps.globals() or {})
  if not report then
    return { L("Spy's saved lists were not found. Spy has to be loaded for this, and its data may use other names.") }
  end
  return self:ImportReport(report)
end

function IntelCommands:Import(args, rest)
  local first = args[1] and args[1]:lower()
  if first == "spy" then
    return self:ImportSpy()
  elseif first == nil then
    return { L("usage: /nrage intel import spy | import [kos|ignore] <names separated by commas>") }
  elseif first == "kos" or first == "ignore" then
    return self:ImportText(rest:match("^%S+%s*(.*)$"), first)
  end
  return self:ImportText(rest, "kos")
end

local function countsText(map)
  local keys = {}
  for key, count in pairs(map or {}) do
    keys[#keys + 1] = ("%s=%d"):format(tostring(key), count)
  end
  table.sort(keys)
  return #keys > 0 and table.concat(keys, ", ") or "none"
end

-- Diagnostics in English (not translated, like the other /nrage debug output).
function IntelCommands:Debug()
  local deps = self.deps
  local nameplates = deps.platform.EnemyNameplatesEnabled and deps.platform.EnemyNameplatesEnabled()
  local events, names = deps.events and deps.events() or {}, {}
  for event in pairs(events) do
    names[#names + 1] = event
  end
  table.sort(names)
  for index, event in ipairs(names) do
    names[index] = event .. "=" .. (events[event] and "registered" or "REFUSED")
  end
  local context, allowed, why
  if deps.zone then
    context, allowed, why = deps.zone()
  end
  context = context or {}
  local detector, publisher, sync, alerts = deps.detector, deps.publisher, deps.sync, deps.alerts
  local counts = deps.service:Counts()
  return {
    "intel debug:",
    "  enemy nameplates: " .. (nameplates == nil and "unknown" or nameplates and "on" or "OFF"),
    "  events: " .. (#names > 0 and table.concat(names, ", ") or "none"),
    ("  zone: instance=%s pvpType=%s map=%s detection=%s%s"):format(
      tostring(context.instance),
      tostring(context.pvpType),
      tostring(context.mapId),
      allowed and "allowed" or "refused",
      allowed and "" or (" (" .. tostring(why) .. ")")
    ),
    ("  detections this session: %d new, %d re-reads"):format(
      detector and detector.contacts or 0,
      detector and detector.reads or 0
    ),
    ("  sightings: %d sent, %d received"):format(publisher and publisher.sent or 0, sync and sync.received or 0),
    "  drops detector: " .. countsText(detector and detector.drops),
    "  drops publisher: " .. countsText(publisher and publisher.drops),
    "  drops receiver: " .. countsText(sync and sync.drops),
    "  drops alerts: " .. countsText(alerts and alerts.drops),
    "  alerts delivered: " .. tostring(alerts and alerts.fired or 0) .. ", announced: " .. tostring(
      alerts and alerts.announcedCount or 0
    ),
    "  loss sources: " .. countsText(detector and detector.lossSources),
    ("  records: %d players, %d kos, %d ignore, %d zones, %d guild kos, %d nearby"):format(
      counts.players,
      counts.kos,
      counts.ignore,
      counts.zones,
      counts.guildKos,
      counts.nearby
    ),
  }
end

-- Runs `text`, what follows `/nrage intel`. Returns the lines to show.
function IntelCommands:Run(text)
  local rest = text or ""
  local args = words(rest)
  local action = args[1] and args[1]:lower() or ""
  table.remove(args, 1)
  local afterAction = rest:match("^%s*%S+%s*(.-)%s*$") or ""

  if action == "" or action == "help" then
    return IntelCommands.Usage()
  elseif action == "show" then
    return self:Hook("IntelShow", L("window"))
  elseif action == "hide" then
    return self:Hook("IntelHide", L("window"))
  elseif action == "config" then
    return self:Hook("IntelConfig", L("settings"))
  elseif action == "stats" then
    return self:Stats(args)
  elseif action == "clear" then
    self:Clear()
    self:Changed()
    return { L("Nobody is listed as nearby now.") }
  elseif action == "reset" then
    return self:Reset(args)
  elseif action == "kos" then
    return self:Kos(args)
  elseif action == "ignore" then
    return self:Ignore(args)
  elseif action == "test" then
    self.deps.alerts:Test()
    return { L("Test alert shown. Nothing was shared.") }
  elseif action == "minimap" then
    if self.deps.toggleMinimap and self.deps.toggleMinimap() then
      return { L("The minimap button is hidden. Type the command again to show it.") }
    end
    return { L("The minimap button is shown.") }
  elseif action == "import" then
    return self:Import(args, afterAction)
  elseif action == "debug" then
    return self:Debug()
  end
  local lines = { L("unknown Intel command '%s'."):format(action:sub(1, 30)) }
  for _, line in ipairs(IntelCommands.Usage()) do
    lines[#lines + 1] = line
  end
  return lines
end

ns.IntelCommands = IntelCommands
