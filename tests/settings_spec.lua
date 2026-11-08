-- Account-wide settings, the language preference of the locale, and the sync state as data.
local function load(paths)
  local ns = {}
  for _, path in ipairs(paths) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

describe("Settings", function()
  local Settings

  before_each(function()
    Settings = load({ "Core/Constants", "Core/Validate", "Domain/Settings" }).Settings
  end)

  describe("Intel", function()
    it("fills every default on an empty database", function()
      local intel = Settings.Intel({ global = {} })
      assert.is_true(intel.enabled)
      assert.is_true(intel.share)
      assert.are.equal(5, intel.removeMinutes)
      assert.is_true(intel.sound)
      assert.is_false(intel.alertNew)
      assert.is_true(intel.alertKos)
      assert.is_true(intel.alertKosGuild)
      assert.is_true(intel.alertStealth)
      assert.is_true(intel.alertGuildReports)
      assert.are.equal("window", intel.warnTarget)
      assert.are.equal("none", intel.announce)
      assert.is_false(intel.inSanctuary)
      assert.is_true(intel.inBattleground)
      assert.is_true(intel.inArena)
      assert.are.equal("zone", intel.mapMode)
      assert.is_false(intel.mapFollow)
      assert.is_true(intel.worldmapPins)
      assert.is_true(intel.minimapTooltip)
      assert.is_false(intel.minimapFeed)
      assert.is_true(intel.targetButton)
      assert.are.same({}, intel.alertRaces)
      assert.are.same({}, intel.excludedZones)
      assert.are.same({ shown = true, locked = false, rows = 8 }, intel.window)
    end)

    it("keeps valid choices and returns the same table every time", function()
      local db = { global = { settings = { intel = { share = false, removeMinutes = 0, announce = "guild" } } } }
      local intel = Settings.Intel(db)
      assert.is_false(intel.share)
      assert.are.equal(0, intel.removeMinutes)
      assert.are.equal("guild", intel.announce)
      assert.are.equal(intel, Settings.Intel(db))
      assert.are.equal(intel, db.global.settings.intel)
    end)

    it("repairs damaged values instead of raising", function()
      local db = {
        global = {
          settings = {
            intel = {
              enabled = "yes",
              removeMinutes = 99,
              warnTarget = "popup",
              announce = 4,
              mapMode = {},
              alertRaces = { ORC = true, ELF = true, TROLL = "x" },
              excludedZones = { [1411] = true, [-5] = true, banana = true, [1412] = 1 },
              window = { shown = "no", locked = 3, rows = 500 },
            },
          },
        },
      }
      local intel = Settings.Intel(db)
      assert.is_true(intel.enabled)
      assert.are.equal(5, intel.removeMinutes)
      assert.are.equal("window", intel.warnTarget)
      assert.are.equal("none", intel.announce)
      assert.are.equal("zone", intel.mapMode)
      assert.are.same({ ORC = true }, intel.alertRaces)
      assert.are.same({ [1411] = true }, intel.excludedZones)
      assert.are.same({ shown = true, locked = false, rows = 8 }, intel.window)
    end)

    it("limits the Nearby delay to 0 or 1 to 15 minutes", function()
      for _, minutes in ipairs({ 0, 1, 15 }) do
        local db = { global = { settings = { intel = { removeMinutes = minutes } } } }
        assert.are.equal(minutes, Settings.Intel(db).removeMinutes)
      end
      for _, minutes in ipairs({ -1, 16, 2.5, "5" }) do
        local db = { global = { settings = { intel = { removeMinutes = minutes } } } }
        assert.are.equal(5, Settings.Intel(db).removeMinutes)
      end
    end)

    it("replaces settings or intel that are not tables", function()
      local db = { global = { settings = { intel = "broken" } } }
      assert.is_true(Settings.Intel(db).enabled)
      db.global.settings = "broken"
      assert.is_true(Settings.Intel(db).enabled)
    end)
  end)

  it("defaults to the game language and the alert sound on", function()
    local db = { global = {} }
    assert.are.equal("auto", Settings.Language(db))
    assert.is_true(Settings.BlacklistSound(db))
  end)

  it("keeps a chosen language and refuses one that does not exist", function()
    local db = { global = { settings = {} } }
    assert.is_true(Settings.SetLanguage(db, "es"))
    assert.are.equal("es", Settings.Language(db))
    assert.are.same({ false, "invalid" }, { Settings.SetLanguage(db, "klingon") })
    assert.are.equal("es", Settings.Language(db))
    assert.is_true(Settings.SetLanguage(db, "en"))
    assert.is_true(Settings.SetLanguage(db, "auto"))
    assert.are.equal("auto", Settings.Language(db))
  end)

  it("repairs a damaged value instead of raising", function()
    local db = { global = { settings = { language = 5, blacklistSound = "no" } } }
    assert.are.equal("auto", Settings.Language(db))
    assert.is_true(Settings.BlacklistSound(db))
    db.global.settings = "broken"
    assert.are.equal("auto", Settings.Language(db))
  end)

  it("saves the alert sound switch", function()
    local db = { global = {} }
    Settings.SetBlacklistSound(db, false)
    assert.is_false(Settings.BlacklistSound(db))
    assert.is_false(db.global.settings.blacklistSound)
    Settings.SetBlacklistSound(db, true)
    assert.is_true(Settings.BlacklistSound(db))
  end)
end)

describe("Locale tables and preference", function()
  local ns

  before_each(function()
    ns = load({ "Core/Locale" })
    ns.Locale.Register("es", { ["Open"] = "Abrir", ["Close"] = "Cerrar" })
  end)

  it("fills a table now and again after every language change, keeping the same table", function()
    local words = ns.Locale.Table(function()
      return { open = ns.L("Open"), list = { ns.L("Close") } }
    end)
    assert.are.equal("Open", words.open)
    ns.Locale.Use("esES")
    assert.are.equal("Abrir", words.open)
    assert.are.equal("Cerrar", words.list[1])
    ns.Locale.UsePreference("en", "esES")
    assert.are.equal("Open", words.open)
    ns.Locale.UsePreference("auto", "esMX")
    assert.are.equal("Abrir", words.open)
  end)

  it("drops the keys a new build no longer has", function()
    local flag = true
    local words = ns.Locale.Table(function()
      return flag and { a = 1, b = 2 } or { a = 1 }
    end)
    assert.are.equal(2, words.b)
    flag = false
    ns.Locale.Use("enUS")
    assert.is_nil(words.b)
  end)

  it("takes the language from the preference, and from the client for auto or nonsense", function()
    assert.are.equal("es", ns.Locale.UsePreference("es", "enUS"))
    assert.are.equal("en", ns.Locale.UsePreference("en", "esES"))
    assert.are.equal("es", ns.Locale.UsePreference("auto", "esES"))
    assert.are.equal("en", ns.Locale.UsePreference("auto", "frFR"))
    assert.are.equal("es", ns.Locale.UsePreference("klingon", "esMX"))
    assert.are.same({ "auto", "es", "en" }, ns.Locale.PREFERENCES)
  end)
end)

describe("Comm:StatusInfo", function()
  it("reports the queue, the last snapshot and the peers as data", function()
    local ns = load({ "Core/Constants", "Core/Locale", "Sync/Comm" })
    local comm = ns.Comm.New({
      platform = {},
      queue = {
        IsPaused = function()
          return true
        end,
        Pending = function()
          return 4
        end,
      },
      roster = {},
      events = {},
      tombstones = {},
      snapshotInbox = {},
      ledgerInbox = {},
      now = function()
        return 0
      end,
    })
    comm.peers = {
      ["Ann-Realm"] = { version = "1" },
      ["Old-Realm"] = { incompatible = true },
      ["Bob-Realm"] = { version = "1" },
      ["Aged-Realm"] = { incompatible = true },
    }
    comm.lastSnapshot = { from = "Ann-Realm", applied = 3, total = 5, at = 10 }
    local info = comm:StatusInfo()
    assert.is_true(info.paused)
    assert.are.equal(4, info.queued)
    assert.are.equal(2, info.peers)
    assert.are.same({ "Aged-Realm", "Old-Realm" }, info.incompatible)
    assert.are.equal(3, info.snapshot.applied)
  end)
end)
