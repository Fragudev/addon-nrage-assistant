local _, ns = ...

-- Alerts and announcements of Intel (docs/PVP_INTEL_PLAN.md section 3.3). It receives every enemy the detector reads
-- and decides whether the player is told. Nothing here touches the client: delivery is injected.
--
--   * Decide(result, details) picks at most one alert, in this order: "kos" (a Kill On Sight player), "kosGuild" (the
--     guild of a Kill On Sight player), "stealth" (an enemy that cast a stealth ability), "race" (a race the player
--     chose) and "new" (an enemy that was not nearby). A kind that is switched off does not match. An ignored enemy
--     never alerts.
--   * The same enemy and kind alert again only after Constants.INTEL_REALERT_SECONDS.
--   * Delivery: the warning goes to the movable window, to the error area at the top of the screen, or nowhere
--     (settings.warnTarget); the sound follows settings.sound.
--   * Announcements go to the player (self), the party, the raid or the guild, at most once per enemy per
--     Constants.INTEL_ANNOUNCE_SECONDS. Automatic ones that reach a chat channel are also capped globally at
--     Constants.INTEL_ANNOUNCE_MAX_PER_MINUTE per 60 s (the player-only scope and AnnounceNow are not counted).
--     Local Defense only through AnnounceNow, from a click or a typed command.
--
-- deps = { settings = function() -> Settings.Intel, service = IntelService, now = function() -> monotonic seconds,
--          mapId = function() -> the own map id or nil,
--          window = function(text, alert) -> boolean (shows the movable warning; false when there is none),
--          errorText = function(text), playSound = function(kind),
--          say = function(text) (a line for the player only), send = function(channel, text) -> boolean,
--          groupChannel = function() -> "INSTANCE_CHAT" | "RAID" | "PARTY" | nil }
local IntelAlerts = {}
IntelAlerts.__index = IntelAlerts

local L = ns.L

-- The Kill On Sight guilds are looked up from the records at most this often (seconds).
local GUILD_SET_SECONDS = 5
-- The tables of cooldowns are cleaned when they hold more than this many entries.
local COOLDOWN_MAX = 500
-- Length of the sliding window of the global announcement cap (seconds).
local ANNOUNCE_WINDOW_SECONDS = 60

IntelAlerts.KINDS = { "kos", "kosGuild", "stealth", "race", "new" }

function IntelAlerts.New(deps)
  return setmetatable({
    deps = deps,
    alerted = {},
    announced = {},
    sentAt = {},
    guildSet = nil,
    guildSetAt = nil,
    fired = 0,
    announcedCount = 0,
    drops = {},
  }, IntelAlerts)
end

local function drop(self, reason)
  self.drops[reason] = (self.drops[reason] or 0) + 1
  return nil, reason
end

local function call(fn, ...)
  local ok, value = pcall(fn, ...)
  return ok and value or nil
end

-- "Name (Mage, level 60) <Guild>", from a name, a class token, a level and a guild that were already read as plain
-- text. A class or a level that is not known is left out.
local function describe(info)
  local text = info.name
  local parts = {}
  local className = ns.IntelModel.ClassName(info.class)
  if className then
    parts[#parts + 1] = className
  end
  if type(info.level) == "number" and info.level > 0 then
    parts[#parts + 1] = L("level %d"):format(info.level) .. (info.levelEstimated and "?" or "")
  end
  if #parts > 0 then
    text = text .. " (" .. table.concat(parts, ", ") .. ")"
  end
  local guild = ns.IntelModel.Plain(info.guild)
  if guild then
    text = text .. " <" .. guild .. ">"
  end
  return text
end

local function textFor(kind, info)
  local who = describe(info)
  if kind == "kos" then
    return L("Kill on Sight: %s"):format(who)
  elseif kind == "kosGuild" then
    return L("Guild of a Kill on Sight player: %s"):format(who)
  elseif kind == "stealth" then
    return L("%s used a stealth ability"):format(who)
  elseif kind == "race" then
    return L("Watched race nearby: %s"):format(who)
  end
  return L("Enemy player nearby: %s"):format(who)
end

-- The Kill On Sight guilds, looked up again when the last look is older than GUILD_SET_SECONDS.
local function kosGuilds(self)
  local now = self.deps.now()
  if not self.guildSet or now - self.guildSetAt >= GUILD_SET_SECONDS then
    self.guildSet, self.guildSetAt = self.deps.service:KosGuilds(), now
  end
  return self.guildSet
end

-- The alert an enemy read now calls for, without delivering it: { kind, key, name, class, text, sound, announce } where
-- `class` is the class token when it is a known class (the window tints its name), `sound` is the kind when sounds
-- are on and `announce` the channel of the automatic announcement, or nil. `result` is what IntelService:OnSeen
-- returned and `details` what the reader gave. Nil when nothing applies.
function IntelAlerts:Decide(result, details)
  if type(result) ~= "table" or type(details) ~= "table" or result.ignored then
    return nil
  end
  local settings = self.deps.settings()
  local kind
  if result.kos and settings.alertKos then
    kind = "kos"
  elseif settings.alertKosGuild and type(details.guild) == "string" and kosGuilds(self)[details.guild:lower()] then
    kind = "kosGuild"
  elseif settings.alertStealth and details.stealth == true then
    kind = "stealth"
  elseif details.race and settings.alertRaces[details.race] then
    kind = "race"
  elseif result.isNew and settings.alertNew then
    kind = "new"
  end
  if not kind then
    return nil
  end
  local info = {
    name = result.record.name,
    class = details.class,
    level = details.level,
    levelEstimated = details.levelEstimated,
    guild = details.guild,
  }
  return {
    kind = kind,
    key = result.key,
    name = info.name,
    class = ns.IntelModel.ClassName(details.class) and details.class or nil,
    text = textFor(kind, info),
    sound = settings.sound and kind or nil,
    announce = settings.announce ~= "none" and settings.announce or nil,
  }
end

-- Is this (kind, key) still inside its cooldown? Marks it as alerted when not.
local function cooling(self, kind, key)
  local now = self.deps.now()
  local id = kind .. ":" .. key
  local last = self.alerted[id]
  if last and now - last < ns.Constants.INTEL_REALERT_SECONDS then
    return true
  end
  local count = 0
  for _ in pairs(self.alerted) do
    count = count + 1
  end
  if count >= COOLDOWN_MAX then
    for old, at in pairs(self.alerted) do
      if now - at >= ns.Constants.INTEL_REALERT_SECONDS then
        self.alerted[old] = nil
      end
    end
  end
  self.alerted[id] = now
  return false
end

-- Shows the warning and plays the sound of an alert.
function IntelAlerts:Deliver(alert)
  local deps = self.deps
  local target = deps.settings().warnTarget
  if target == "window" then
    if not (deps.window and call(deps.window, alert.text, alert)) and deps.errorText then
      pcall(deps.errorText, alert.text)
    end
  elseif target == "error" and deps.errorText then
    pcall(deps.errorText, alert.text)
  end
  if alert.sound and deps.playSound then
    pcall(deps.playSound, alert.sound)
  end
  self.fired = self.fired + 1
end

-- The channel an automatic announcement to `scope` ("self", "party", "raid" or "guild") goes out on, or nil plus
-- "no_group" / "bad_channel".
function IntelAlerts:ChannelFor(scope)
  local group = call(self.deps.groupChannel)
  if scope == "self" then
    return "SELF"
  elseif scope == "guild" then
    return "GUILD"
  elseif scope == "localdefense" then
    return "LOCALDEFENSE"
  elseif scope == "party" then
    if group == "INSTANCE_CHAT" then
      return group
    elseif group then
      return "PARTY"
    end
    return nil, "no_group"
  elseif scope == "raid" then
    if group == "INSTANCE_CHAT" or group == "RAID" then
      return group
    end
    return nil, "no_group"
  end
  return nil, "bad_channel"
end

-- Says where an enemy is, on `scope`. Returns true, or false plus "no_group" | "bad_channel" | "send_failed".
local function announceTo(self, info, scope)
  local channel, why = self:ChannelFor(scope)
  if not channel then
    return false, why
  end
  local text = textFor("new", info)
  if channel == "SELF" then
    if self.deps.say then
      pcall(self.deps.say, text)
    end
    return true
  end
  if not call(self.deps.send, channel, text) then
    return false, "send_failed"
  end
  return true
end

-- The automatic announcement of an enemy, at most once per Constants.INTEL_ANNOUNCE_SECONDS.
local function autoAnnounce(self, key, info)
  local scope = self.deps.settings().announce
  if scope == "none" then
    return false
  end
  local now = self.deps.now()
  local last = self.announced[key]
  if last and now - last < ns.Constants.INTEL_ANNOUNCE_SECONDS then
    return false
  end
  -- Only sends to chat count toward the cap; "self" is a local print.
  local toChat = self:ChannelFor(scope) ~= "SELF"
  if toChat then
    local kept = {}
    for _, at in ipairs(self.sentAt) do
      if now - at < ANNOUNCE_WINDOW_SECONDS then
        kept[#kept + 1] = at
      end
    end
    self.sentAt = kept
    if #kept >= ns.Constants.INTEL_ANNOUNCE_MAX_PER_MINUTE then
      -- Not marked as announced, so the enemy can still be announced once the window frees up.
      drop(self, "announce_rate")
      return false
    end
  end
  if not announceTo(self, info, scope) then
    return false
  end
  if toChat then
    self.sentAt[#self.sentAt + 1] = now
  end
  local count = 0
  for _ in pairs(self.announced) do
    count = count + 1
  end
  if count >= COOLDOWN_MAX then
    for old, at in pairs(self.announced) do
      if now - at >= ns.Constants.INTEL_ANNOUNCE_SECONDS then
        self.announced[old] = nil
      end
    end
  end
  self.announced[key] = now
  self.announcedCount = self.announcedCount + 1
  return true
end

-- An enemy was read (the detector's onContact). Delivers the alert it calls for, unless the same kind alerted this
-- enemy lately, and announces a new or alerting enemy. Returns the alert that was delivered, or nil.
function IntelAlerts:OnContact(result, details)
  if type(result) ~= "table" or result.ignored or type(details) ~= "table" then
    return nil
  end
  local alert = self:Decide(result, details)
  local delivered
  if alert and not cooling(self, alert.kind, alert.key) then
    self:Deliver(alert)
    delivered = alert
  elseif alert then
    drop(self, "cooldown")
  end
  if delivered or result.isNew then
    autoAnnounce(self, result.key, {
      name = result.record.name,
      class = details.class,
      level = details.level,
      levelEstimated = details.levelEstimated,
      guild = details.guild,
    })
  end
  return delivered
end

-- A guildmate saw an enemy (an entry of IntelDirectory): when it is a Kill On Sight player on the own map, it alerts as
-- "kos", naming the reporter. Returns the alert, or nil.
function IntelAlerts:OnReport(entry)
  local deps = self.deps
  local settings = deps.settings()
  if not settings.alertGuildReports or type(entry) ~= "table" then
    return nil
  end
  local key = entry.key or ns.IntelModel.Key(entry.name)
  if not key or deps.service:IsIgnored(key) or not deps.service:IsKos(key) then
    return nil
  end
  local map = call(deps.mapId)
  if not map or entry.map ~= map then
    return nil
  end
  local name = ns.IntelModel.CleanName(entry.name)
  if not name or cooling(self, "kos", key) then
    return nil
  end
  local source = ns.IntelModel.Plain(entry.source) or "?"
  local alert = {
    kind = "kos",
    key = key,
    name = name,
    class = ns.IntelModel.ClassName(entry.class) and entry.class or nil,
    text = L("%s reports Kill on Sight: %s"):format(
      source,
      describe({ name = name, class = entry.class, level = entry.level })
    ),
    sound = settings.sound and "kos" or nil,
  }
  self:Deliver(alert)
  return alert
end

-- Tells `channel` ("self", "party", "raid", "guild" or "localdefense") where the enemy `name` is, now. Meant for a
-- click or a typed command: Local Defense needs a hardware event, so only this path may use it. Returns true, or false
-- plus "bad_name" | "no_group" | "bad_channel" | "send_failed".
function IntelAlerts:AnnounceNow(name, channel)
  local clean = ns.IntelModel.CleanName(name)
  if not clean then
    return false, "bad_name"
  end
  local record = self.deps.service:Player(clean)
  local info = { name = clean }
  if record then
    info.class, info.level, info.levelEstimated, info.guild =
      record.class, record.level, record.levelEstimated, record.guild
  end
  return announceTo(self, info, channel)
end

-- A fake alert for /nrage intel test: delivered with its warning and sound, never announced and never sent.
function IntelAlerts:Test()
  local settings = self.deps.settings()
  local alert = {
    kind = "kos",
    key = "test",
    name = "Test",
    text = L("Kill on Sight: %s"):format("Test (" .. L("level %d"):format(60) .. ")"),
    sound = settings.sound and "kos" or nil,
  }
  self:Deliver(alert)
  return alert
end

ns.IntelAlerts = IntelAlerts
