local function load_diagnostics()
  local ns = {}
  assert(loadfile("NrageAssistant/Domain/Diagnostics.lua"))("NrageAssistant", ns)
  return ns.Diagnostics
end

local Diagnostics = load_diagnostics()

-- The client contract the addon relies on. If Diagnostics starts checking something new, this list
-- has to grow with it, which keeps the two honest.
local CALLED = {
  "UnitGUID",
  "UnitName",
  "UnitClass",
  "UnitLevel",
  "UnitFactionGroup",
  "GetNormalizedRealmName",
  "GetAverageItemLevel",
  "GetProfessions",
  "IsInGuild",
  "GetGuildInfo",
  "GetNumGuildMembers",
  "GetGuildRosterInfo",
  "GetServerTime",
  "GetTime",
  "GetBuildInfo",
  "date",
  "time",
  "C_Club.GetGuildClubId",
  "C_ChatInfo.InChatMessagingLockdown",
}
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

local function set(env, path, value)
  local parts = {}
  for part in path:gmatch("[^%.]+") do
    parts[#parts + 1] = part
  end
  local target = env
  for i = 1, #parts - 1 do
    target[parts[i]] = target[parts[i]] or {}
    target = target[parts[i]]
  end
  target[parts[#parts]] = value
end

local function full_env()
  local env = { calls = {} }
  for _, path in ipairs(CALLED) do
    set(env, path, function()
      env.calls[path] = true
    end)
  end
  for _, path in ipairs(EXISTS) do
    set(env, path, function()
      env.calls[path] = true
    end)
  end
  env.LibStub = function(name)
    for _, library in ipairs(LIBRARIES) do
      if library == name then
        return {}
      end
    end
    return nil
  end
  return env
end

local function full_addon()
  return {
    Constants = { SCHEMA_VERSION = 2 },
    Codec = {
      Default = function()
        return {
          Encode = function(_, message)
            return message
          end,
          Decode = function(_, text)
            return text
          end,
        }
      end,
    },
    Platform = {
      GetIdentityKey = function()
        return "Nrager-ClassicBetaPvP"
      end,
    },
    guildRoster = {
      IsReady = function()
        return true
      end,
      Lookup = function()
        return { rankName = "Member" }
      end,
      Count = function()
        return 42
      end,
    },
    db = { global = { schemaVersion = 2 } },
  }
end

local function find(results, name)
  for _, entry in ipairs(results) do
    if entry.name == name then
      return entry
    end
  end
end

describe("Diagnostics.SelfTest", function()
  it("passes everything on a client that has what the addon needs", function()
    local results, summary = Diagnostics.SelfTest(full_env(), full_addon())
    assert.are.equal(#CALLED + #EXISTS + #LIBRARIES + 4, #results)
    assert.are.equal(#results, summary.ok)
    assert.are.equal(0, summary.warn + summary.missing + summary.error)
  end)

  it("calls the read-only functions and only checks that the others exist", function()
    local env = full_env()
    Diagnostics.SelfTest(env, full_addon())
    for _, path in ipairs(CALLED) do
      assert.is_true(env.calls[path], path)
    end
    for _, path in ipairs(EXISTS) do
      assert.is_nil(env.calls[path], path)
    end
  end)

  it("reports a missing API by name", function()
    local env = full_env()
    env.GetProfessions = nil
    env.C_ChatInfo.InChatMessagingLockdown = nil
    env.C_Timer = nil
    local results, summary = Diagnostics.SelfTest(env, full_addon())
    assert.are.equal("missing", find(results, "GetProfessions").status)
    assert.are.equal("missing", find(results, "C_ChatInfo.InChatMessagingLockdown").status)
    assert.are.equal("missing", find(results, "C_Timer.After").status)
    assert.are.equal("missing", find(results, "C_Timer.NewTicker").status)
    assert.are.equal(4, summary.missing)
  end)

  it("reports an API that raises, with its message, and carries on", function()
    local env = full_env()
    env.UnitGUID = function()
      error("boom")
    end
    local results, summary = Diagnostics.SelfTest(env, full_addon())
    local entry = find(results, "UnitGUID")
    assert.are.equal("error", entry.status)
    assert.is_truthy(entry.detail:find("boom", 1, true))
    assert.are.equal(1, summary.error)
    assert.are.equal("ok", find(results, "UnitName").status)
  end)

  it("reports missing libraries, a missing LibStub and a LibStub that raises", function()
    local env = full_env()
    env.LibStub = function(name)
      if name == "LibDeflate" then
        return nil
      end
      if name == "AceGUI-3.0" then
        error("bad lib")
      end
      return {}
    end
    local results = Diagnostics.SelfTest(env, full_addon())
    assert.are.equal("missing", find(results, "library LibDeflate").status)
    assert.are.equal("error", find(results, "library AceGUI-3.0").status)
    assert.are.equal("ok", find(results, "library LibSerialize").status)

    env.LibStub = nil
    results = Diagnostics.SelfTest(env, full_addon())
    assert.are.equal("missing", find(results, "library LibSerialize").status)
    assert.is_truthy(find(results, "library LibSerialize").detail:find("LibStub", 1, true))
  end)
end)

describe("Diagnostics behaviour checks", function()
  local function run(mutate)
    local addon = full_addon()
    mutate(addon)
    return Diagnostics.SelfTest(full_env(), addon)
  end

  it("accepts the roster's name without a realm, with spaces, and Name-Realm", function()
    for _, key in ipairs({ "Yonemon Gg", "Nrager", "Nrager-Realm", "Yonemon Gg-Realm" }) do
      local results = run(function(addon)
        addon.Platform.GetIdentityKey = function()
          return key
        end
      end)
      assert.are.equal("ok", find(results, "identity key").status, key)
    end
  end)

  it("warns about an identity key built from missing values", function()
    for _, key in ipairs({ "nil-nil", "Nrager-nil", "nil", "", "   ", 42 }) do
      local results = run(function(addon)
        addon.Platform.GetIdentityKey = function()
          return key
        end
      end)
      assert.are.equal("warn", find(results, "identity key").status, tostring(key))
    end
  end)

  it("warns when the guild roster is not ready or does not know the own key", function()
    local results = run(function(addon)
      addon.guildRoster = nil
    end)
    assert.are.equal("warn", find(results, "guild roster").status)

    results = run(function(addon)
      addon.guildRoster.Lookup = function()
        return nil
      end
    end)
    local entry = find(results, "guild roster")
    assert.are.equal("warn", entry.status)
    assert.is_truthy(entry.detail:find("was not found", 1, true))
    assert.is_truthy(entry.detail:find("matched by GUID", 1, true))
  end)

  it("flags missing or outdated saved data as an error", function()
    assert.are.equal(
      "error",
      find(
        run(function(addon)
          addon.db = nil
        end),
        "saved data"
      ).status
    )
    assert.are.equal(
      "error",
      find(
        run(function(addon)
          addon.db.global.schemaVersion = 1
        end),
        "saved data"
      ).status
    )
  end)

  it("flags a codec that does not round trip", function()
    local results = run(function(addon)
      addon.Codec.Default = function()
        return {
          Encode = function()
            return "x"
          end,
          Decode = function()
            return { p = { version = "other" } }
          end,
        }
      end
    end)
    assert.are.equal("error", find(results, "codec round trip").status)
  end)

  it("survives a behaviour check that raises", function()
    local results, summary = run(function(addon)
      addon.Platform.GetIdentityKey = function()
        error("kaput")
      end
    end)
    assert.is_true(summary.error >= 1)
    assert.is_truthy(#results > 0)
  end)
end)

describe("Diagnostics.DescribeSelfTest", function()
  it("shows the totals and only what is not fine", function()
    local env = full_env()
    env.GetProfessions = nil
    local addon = full_addon()
    addon.guildRoster = nil
    local results, summary = Diagnostics.SelfTest(env, addon)
    local lines = Diagnostics.DescribeSelfTest(results, summary)
    assert.are.equal(3, #lines)
    assert.is_truthy(lines[1]:find("1 warning(s), 1 missing, 0 error(s)", 1, true))
    assert.is_truthy(table.concat(lines, "\n"):find("[missing] GetProfessions", 1, true))
    assert.is_truthy(table.concat(lines, "\n"):find("[warn] guild roster", 1, true))
  end)

  it("is a single line when everything is fine", function()
    local results, summary = Diagnostics.SelfTest(full_env(), full_addon())
    assert.are.equal(1, #Diagnostics.DescribeSelfTest(results, summary))
  end)
end)

describe("Diagnostics.Info", function()
  local function addon_with_data()
    return {
      GetVersion = function()
        return "0.4.0"
      end,
      active = true,
      db = {
        global = {
          schemaVersion = 2,
          events = { a = {}, b = {} },
          roster = { ["Ann-Realm"] = {} },
          sync = { tombstones = { t1 = {}, t2 = {}, t3 = {} } },
        },
        chars = { ["Me-Realm"] = { profile = {} } },
      },
      Platform = {
        GetBuildNumber = function()
          return 16001
        end,
        GetOwnGuildRank = function()
          return "RL"
        end,
        GetIdentityKey = function()
          return "Me-Realm"
        end,
      },
      PermissionService = {
        OwnRole = function()
          return "rl"
        end,
      },
      comm = {
        Status = function()
          return { "sync ready", "queued messages: 0" }
        end,
      },
    }
  end

  it("reports version, build, data volume, role and sync state", function()
    local text = table.concat(Diagnostics.Info(addon_with_data()), "\n")
    assert.is_truthy(text:find("version: 0.4.0, schema: 2, active: true", 1, true))
    assert.is_truthy(text:find("build: 16001", 1, true))
    assert.is_truthy(text:find("data: 2 event(s), 1 received profile(s), 3 tombstone(s), 1 character(s)", 1, true))
    assert.is_truthy(text:find("saved data size: about", 1, true))
    assert.is_truthy(text:find("own role: rl", 1, true))
    assert.is_truthy(text:find("sync: sync ready", 1, true))
    assert.is_truthy(text:find("sync: queued messages: 0", 1, true))
  end)

  it("still works before the database or the sync exist", function()
    local addon = addon_with_data()
    addon.db, addon.comm, addon.active = nil, nil, nil
    local text = table.concat(Diagnostics.Info(addon), "\n")
    assert.is_truthy(text:find("version: 0.4.0, schema: nil, active: false", 1, true))
    assert.is_nil(text:find("data:", 1, true))
    assert.is_nil(text:find("sync:", 1, true))
  end)
end)

describe("Diagnostics.Failures", function()
  it("keeps only the checks that are missing or erroring, in order", function()
    local failures = Diagnostics.Failures({
      { name = "a", status = "ok" },
      { name = "b", status = "missing", detail = "not available on this client" },
      { name = "c", status = "warn", detail = "roster not ready" },
      { name = "d", status = "error", detail = "boom" },
    })
    assert.are.equal(2, #failures)
    assert.are.equal("b", failures[1].name)
    assert.are.equal("d", failures[2].name)
  end)

  it("finds nothing when everything works, and flags a missing client function", function()
    assert.are.same({}, Diagnostics.Failures((Diagnostics.SelfTest(full_env(), full_addon()))))

    local env = full_env()
    env.UnitGUID = nil
    local failures = Diagnostics.Failures((Diagnostics.SelfTest(env, full_addon())))
    assert.are.equal(1, #failures)
    assert.are.equal("UnitGUID", failures[1].name)
  end)
end)
