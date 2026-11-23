local function load_professions()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Locale.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Locales/esES.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Domain/Professions.lua"))("NrageAssistant", ns)
  return ns.Professions, ns.Locale
end

describe("Professions", function()
  local Professions, Locale = load_professions()

  after_each(function()
    Locale.Use("enUS")
  end)

  it("knows a profession by its English or Spanish name, in any case and with or without accents", function()
    assert.are.equal("cooking", Professions.Key("Cooking"))
    assert.are.equal("cooking", Professions.Key("cocina"))
    assert.are.equal("blacksmithing", Professions.Key("Herrería"))
    assert.are.equal("blacksmithing", Professions.Key("HERRERIA"))
    assert.are.equal("firstaid", Professions.Key("Primeros auxilios"))
    assert.are.equal("skinning", Professions.Key("  Desuello "))
    assert.is_nil(Professions.Key("Basket weaving"))
    assert.is_nil(Professions.Key(nil))
  end)

  it("knows a profession by its skill line id", function()
    assert.are.equal("cooking", Professions.KeyForId(185))
    assert.are.equal("alchemy", Professions.KeyForId(171))
    assert.is_nil(Professions.KeyForId(99999))
  end)

  it("names a profession in the language of the addon, whatever language it came in", function()
    Locale.Use("enUS")
    assert.are.equal("Cooking", Professions.Name("Cocina"))
    assert.are.equal("Cooking", Professions.NameForId(185, "Cocina"))
    Locale.Use("esES")
    assert.are.equal("Cocina", Professions.Name("Cooking"))
    assert.are.equal("Herrería", Professions.NameForId(164, "Blacksmithing"))
    -- A name or id it does not know is shown as it came.
    assert.are.equal("Basket weaving", Professions.Name("Basket weaving"))
    assert.are.equal("Cestería", Professions.NameForId(99999, "Cestería"))
  end)

  it("says whether two names are the same profession across languages", function()
    assert.is_true(Professions.Same("Cocina", "Cooking"))
    assert.is_true(Professions.Same("cooking", "COOKING"))
    assert.is_false(Professions.Same("Cocina", "Fishing"))
    assert.is_true(Professions.Same("Basket weaving", "basket weaving"))
    assert.is_false(Professions.Same("Basket weaving", nil))
  end)

  it("lists the professions in the language of the addon", function()
    Locale.Use("esES")
    local names = Professions.List()
    assert.are.equal(12, #names)
    assert.are.equal("Alquimia", names[1])
    assert.are.equal("Primeros auxilios", names[12])
    Locale.Use("enUS")
    assert.are.equal("Alchemy", Professions.List()[1])
  end)

  it("has a Spanish translation for every English name in the catalog", function()
    Locale.Use("esES")
    for _, entry in ipairs(Professions.ENTRIES) do
      assert.are.equal(entry.es, Locale.Translate(entry.en))
    end
  end)

  describe("names from the client", function()
    local function with_platform(platform)
      local space = {}
      assert(loadfile("NrageAssistant/Core/Locale.lua"))("NrageAssistant", space)
      assert(loadfile("NrageAssistant/Locales/esES.lua"))("NrageAssistant", space)
      space.Platform = platform
      assert(loadfile("NrageAssistant/Domain/Professions.lua"))("NrageAssistant", space)
      return space.Professions, space.Locale
    end

    it("uses the name the client gives when the addon shows the language of the client", function()
      local professions, locale = with_platform({
        GetLocale = function()
          return "esES"
        end,
        GetSpellName = function(id)
          return id == 3908 and "Sastrería del cliente" or nil
        end,
      })
      locale.Use("esES")
      assert.are.equal("Sastrería del cliente", professions.Name("Tailoring"))
      assert.are.equal("Sastrería del cliente", professions.NameForId(197, "x"))
      assert.are.equal("Sastrería del cliente", professions.List()[9])
      -- The client gave no name for Alchemy: the catalog names it.
      assert.are.equal("Alquimia", professions.Name("Alchemy"))
    end)

    it("keeps to the catalog when the addon is in another language than the client", function()
      local professions, locale = with_platform({
        GetLocale = function()
          return "esES"
        end,
        GetSpellName = function()
          return "Del cliente"
        end,
      })
      locale.Use("enUS")
      assert.are.equal("Tailoring", professions.Name("Sastrería"))
    end)

    it("keeps to the catalog without the API, and the corrected names stand", function()
      local professions, locale = with_platform(nil)
      locale.Use("esES")
      assert.are.equal("Sastrería", professions.Name("Tailoring"))
      assert.are.equal("tailoring", professions.Key("Sastrería"))
      assert.is_nil(professions.Key("Costura"))
      assert.are.equal("Desuello", professions.Name("Skinning"))
    end)
  end)
end)
