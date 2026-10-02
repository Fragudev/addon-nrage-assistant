-- Translation: how a language is chosen, and that the Spanish catalog matches what the code asks for.
local function load_locale()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Locale.lua"))("NrageAssistant", ns)
  return ns
end

describe("Locale", function()
  local ns

  before_each(function()
    ns = load_locale()
    ns.Locale.Register("es", { ["Open the window"] = "Abrir la ventana", ["Level %d"] = "Nivel %d" })
  end)

  it("answers in Spanish for the Spanish clients", function()
    for _, code in ipairs({ "esES", "esMX" }) do
      ns.Locale.Use(code)
      assert.are.equal("Abrir la ventana", ns.L("Open the window"), code)
      assert.are.equal("Nivel 60", ns.L("Level %d"):format(60), code)
    end
  end)

  it("answers in English for every other client language", function()
    for _, code in ipairs({ "enUS", "enGB", "deDE", "frFR", "ptBR", "koKR", "zhCN", "" }) do
      ns.Locale.Use(code)
      assert.are.equal("Open the window", ns.L("Open the window"), code)
    end
    ns.Locale.Use(nil)
    assert.are.equal("Open the window", ns.L("Open the window"))
  end)

  it("shows the English text when there is no translation", function()
    ns.Locale.Use("esES")
    assert.are.equal("Not translated yet", ns.L("Not translated yet"))
  end)

  it("takes the language of the client when none was chosen", function()
    ns.Platform = {
      GetLocale = function()
        return "esMX"
      end,
    }
    assert.are.equal("Abrir la ventana", ns.L("Open the window"))
  end)

  it("falls back to English when the client does not say its language", function()
    ns.Platform = {}
    assert.are.equal("Open the window", ns.L("Open the window"))
  end)

  it("adds to a catalog without losing what it already has", function()
    ns.Locale.Register("es", { ["Close"] = "Cerrar" })
    ns.Locale.Use("esES")
    assert.are.equal("Cerrar", ns.L("Close"))
    assert.are.equal("Abrir la ventana", ns.L("Open the window"))
  end)
end)

-- The files the TOC loads, and every text they ask for with L("...").
local function source_files()
  local files = {}
  local toc = assert(io.open("NrageAssistant/NrageAssistant.toc", "r"))
  for line in toc:lines() do
    local path = line:match("^%s*([^#%s][^%s]*%.lua)%s*$")
    if path and not path:find("^Locales") and path ~= "Core\\Locale.lua" then
      files[#files + 1] = "NrageAssistant/" .. path:gsub("\\", "/")
    end
  end
  toc:close()
  return files
end

local function asked_for()
  local keys = {}
  for _, path in ipairs(source_files()) do
    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()
    for key in text:gmatch('[^%w_]L%(%s*"([^"]*)"%s*%)') do
      keys[key] = path
    end
    -- A text with double quotes inside is written between single quotes.
    for key in text:gmatch("[^%w_]L%(%s*'([^']*)'%s*%)") do
      keys[key] = path
    end
  end
  return keys
end

local function placeholders(text)
  local found = {}
  for spec in text:gsub("%%%%", ""):gmatch("%%[%-%d%.]*[sdfgxXc]") do
    found[#found + 1] = spec
  end
  return table.concat(found, " ")
end

describe("The Spanish catalog", function()
  local ns = {}
  local catalog

  setup(function()
    assert(loadfile("NrageAssistant/Core/Locale.lua"))("NrageAssistant", ns)
    assert(loadfile("NrageAssistant/Locales/esES.lua"))("NrageAssistant", ns)
    catalog = ns.Locale.Catalogs().es
  end)

  it("translates every text the code asks for", function()
    local missing = {}
    for key, path in pairs(asked_for()) do
      if not catalog[key] then
        missing[#missing + 1] = ("%s: %s"):format(path, key)
      end
    end
    table.sort(missing)
    assert.are.same({}, missing)
  end)

  it("has no entry that nothing asks for", function()
    local asked, stale = asked_for(), {}
    for key in pairs(catalog) do
      if not asked[key] then
        stale[#stale + 1] = key
      end
    end
    table.sort(stale)
    assert.are.same({}, stale)
  end)

  it("keeps the placeholders of each text, in the same order", function()
    for english, spanish in pairs(catalog) do
      assert.are.equal(placeholders(english), placeholders(spanish), english)
    end
  end)

  it("never translates a text into nothing", function()
    for english, spanish in pairs(catalog) do
      assert.is_true(spanish:match("%S") ~= nil, english)
    end
  end)
end)
