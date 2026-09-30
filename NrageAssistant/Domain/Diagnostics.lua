local _, ns = ...

-- Self test and state report for /nrage debug selftest and /nrage debug info.
--
-- The self test is the client contract from the plan: one smoke check per API the addon uses, so a
-- client patch that renames or removes something is noticed here instead of as a Lua error in a raid.
-- `env` is the table the APIs are looked up in (the real `_G`; a fake in specs), and `addon` the
-- addon namespace for the behaviour checks. Nothing here changes any data, and nothing sends a message.
local Diagnostics = {}

-- Functions that are safe to call: read-only, no side effects. `args` are passed as they are.
local CALLED = {
  { path = "UnitGUID", args = { "player" } },
  { path = "UnitName", args = { "player" } },
  { path = "UnitClass", args = { "player" } },
  { path = "UnitLevel", args = { "player" } },
  { path = "UnitFactionGroup", args = { "player" } },
  { path = "GetNormalizedRealmName", args = {} },
  { path = "GetAverageItemLevel", args = {} },
  { path = "GetProfessions", args = {} },
  { path = "IsInGuild", args = {} },
  { path = "GetGuildInfo", args = { "player" } },
  { path = "GetNumGuildMembers", args = {} },
  { path = "GetGuildRosterInfo", args = { 1 } },
  { path = "GetServerTime", args = {} },
  { path = "GetTime", args = {} },
  { path = "GetBuildInfo", args = {} },
  { path = "date", args = { "%H:%M" } },
  { path = "time", args = {} },
  { path = "C_Club.GetGuildClubId", args = {} },
  { path = "C_ChatInfo.InChatMessagingLockdown", args = {} },
}

-- Functions that only need to exist: calling them would ask the server for something, send a message
-- or create something.
local EXISTS = {
  "GetProfessionInfo",
  "CreateFrame",
  "C_GuildInfo.GuildRoster",
  "C_ChatInfo.RegisterAddonMessagePrefix",
  "C_ChatInfo.SendAddonMessage",
  "C_Timer.After",
  "C_Timer.NewTicker",
  "C_AddOns.GetAddOnMetadata",
}

local LIBRARIES = { "AceComm-3.0", "AceGUI-3.0", "LibSerialize", "LibDeflate", "CallbackHandler-1.0" }

local function resolve(env, path)
  local value = env
  for part in path:gmatch("[^%.]+") do
    if type(value) ~= "table" then
      return nil
    end
    value = value[part]
  end
  return value
end

local function result(name, status, detail)
  return { name = name, status = status, detail = detail }
end

local function checkCalled(env, spec)
  local fn = resolve(env, spec.path)
  if type(fn) ~= "function" then
    return result(spec.path, "missing", "not available on this client")
  end
  local ok, err = pcall(fn, unpack(spec.args))
  if not ok then
    return result(spec.path, "error", tostring(err))
  end
  return result(spec.path, "ok")
end

local function checkExists(env, path)
  if type(resolve(env, path)) ~= "function" then
    return result(path, "missing", "not available on this client")
  end
  return result(path, "ok", "exists (not called)")
end

local function checkLibrary(env, name)
  local label = "library " .. name
  local libstub = env.LibStub
  if type(libstub) ~= "function" and type(libstub) ~= "table" then
    return result(label, "missing", "LibStub is not loaded")
  end
  local ok, library = pcall(libstub, name, true)
  if not ok then
    return result(label, "error", tostring(library))
  end
  if not library then
    return result(label, "missing", "not loaded")
  end
  return result(label, "ok")
end

-- Behaviour checks: does the addon's own machinery work on this client?
local function behaviourChecks(addon)
  local checks = {}

  checks[#checks + 1] = function()
    local ok, err = pcall(function()
      local codec = addon.Codec.Default()
      local text = assert(codec:Encode({ t = "HELLO", p = { version = "selftest" } }))
      local decoded = assert(codec:Decode(text))
      assert(decoded.p.version == "selftest", "round trip changed the message")
    end)
    return ok and result("codec round trip", "ok") or result("codec round trip", "error", tostring(err))
  end

  checks[#checks + 1] = function()
    local identityKey = addon.Platform.GetIdentityKey()
    if type(identityKey) ~= "string" or not identityKey:find("^[^%-]+%-.+$") then
      return result("identity key", "warn", ("unexpected format: %s"):format(tostring(identityKey)))
    end
    return result("identity key", "ok", identityKey)
  end

  checks[#checks + 1] = function()
    local roster = addon.guildRoster
    if not roster or not roster:IsReady() then
      return result("guild roster", "warn", "not loaded yet")
    end
    if not roster:Lookup(addon.Platform.GetIdentityKey()) then
      return result(
        "guild roster",
        "warn",
        ("%d members, but the own name '%s' was not found (matched by GUID: %s): name formats may differ"):format(
          roster:Count(),
          tostring(addon.Platform.GetIdentityKey()),
          tostring(roster.ownName)
        )
      )
    end
    return result("guild roster", "ok", ("%d members, own key found"):format(roster:Count()))
  end

  checks[#checks + 1] = function()
    local db = addon.db
    if not db or not db.global then
      return result("saved data", "error", "no database loaded")
    end
    if db.global.schemaVersion ~= addon.Constants.SCHEMA_VERSION then
      return result(
        "saved data",
        "error",
        ("schema %s, expected %s"):format(tostring(db.global.schemaVersion), addon.Constants.SCHEMA_VERSION)
      )
    end
    return result("saved data", "ok", ("schema %d"):format(db.global.schemaVersion))
  end

  return checks
end

-- Returns the list of results and a summary { ok, warn, missing, error }.
function Diagnostics.SelfTest(env, addon)
  local results = {}
  for _, spec in ipairs(CALLED) do
    results[#results + 1] = checkCalled(env, spec)
  end
  for _, path in ipairs(EXISTS) do
    results[#results + 1] = checkExists(env, path)
  end
  for _, name in ipairs(LIBRARIES) do
    results[#results + 1] = checkLibrary(env, name)
  end
  for _, check in ipairs(behaviourChecks(addon)) do
    local ok, outcome = pcall(check)
    results[#results + 1] = ok and outcome or result("behaviour check", "error", tostring(outcome))
  end

  local summary = { ok = 0, warn = 0, missing = 0, error = 0 }
  for _, entry in ipairs(results) do
    summary[entry.status] = (summary[entry.status] or 0) + 1
  end
  return results, summary
end

-- The checks that failed outright (missing or erroring). Warnings are left out on purpose: at login they
-- are usually just data that has not arrived yet (the guild roster), and flagging those would cry wolf.
function Diagnostics.Failures(results)
  local failures = {}
  for _, entry in ipairs(results) do
    if entry.status == "missing" or entry.status == "error" then
      failures[#failures + 1] = entry
    end
  end
  return failures
end

-- Everything that is not simply "ok" is listed; the total says how many were fine.
function Diagnostics.DescribeSelfTest(results, summary)
  local lines = {
    ("self test: %d ok, %d warning(s), %d missing, %d error(s)"):format(
      summary.ok,
      summary.warn,
      summary.missing,
      summary.error
    ),
  }
  for _, entry in ipairs(results) do
    if entry.status ~= "ok" then
      lines[#lines + 1] = ("  [%s] %s - %s"):format(entry.status, entry.name, entry.detail or "")
    end
  end
  return lines
end

local function countKeys(tbl)
  local count = 0
  for _ in pairs(tbl or {}) do
    count = count + 1
  end
  return count
end

-- Rough size of a table in entries, bounded so a huge SavedVariables cannot stall the client.
local function countEntries(tbl, budget)
  local total = 0
  local function walk(value)
    for _, child in pairs(value) do
      total = total + 1
      if total >= budget then
        return
      end
      if type(child) == "table" then
        walk(child)
        if total >= budget then
          return
        end
      end
    end
  end
  walk(tbl)
  return total, total >= budget
end

local SIZE_BUDGET = 200000

-- State report for /nrage debug info: what is loaded, how much data there is, and the roles in play.
function Diagnostics.Info(addon)
  local lines = {}
  local function add(text)
    lines[#lines + 1] = text
  end

  add(
    ("version: %s, schema: %s, active: %s"):format(
      addon.GetVersion(),
      tostring(addon.db and addon.db.global.schemaVersion),
      tostring(addon.active == true)
    )
  )
  add(("build: %s"):format(tostring(addon.Platform.GetBuildNumber())))

  if addon.db then
    local global = addon.db.global
    add(
      ("data: %d event(s), %d received profile(s), %d tombstone(s), %d character(s)"):format(
        countKeys(global.events),
        countKeys(global.roster),
        countKeys(global.sync.tombstones),
        countKeys(addon.db.chars)
      )
    )
    local entries, truncated = countEntries(addon.db, SIZE_BUDGET)
    add(("saved data size: about %d%s entries"):format(entries, truncated and "+" or ""))
  end

  if addon.PermissionService and addon.Platform then
    add(("own role: %s"):format(tostring(addon.PermissionService.OwnRole(addon.Platform))))
  end
  if addon.comm then
    for _, line in ipairs(addon.comm:Status()) do
      add("sync: " .. line)
    end
  end
  return lines
end

ns.Diagnostics = Diagnostics
