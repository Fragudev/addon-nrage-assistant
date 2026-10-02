local _, ns = ...

-- Translation of what the player reads (issue #36). The code writes the English text and asks for it through
-- L("English text"); a catalog maps that same text to another language, and a text with no translation is shown
-- as written, so a missing entry never breaks anything.
--   * Spanish when the client is Spanish (esES or esMX); English for every other client language.
--   * Catalogs live in Locales/<code>.lua and are registered with Locale.Register(language, { [english] = text }).
--   * The text is the key, so a format string keeps its placeholders (%d, %s) in the same order in every language,
--     and a test checks that. Developer output (/nrage debug ...) and text that goes over the wire stay in English.
--   * Never translate a value the code compares or sends (a status, a role, a command word); only what is shown.
local Locale = {}

local catalogs = {}
local language

-- The client language codes that have a translation, and the language they use.
local LANGUAGE_OF = { esES = "es", esMX = "es" }

function Locale.LanguageFor(code)
  return LANGUAGE_OF[code] or "en"
end

-- Adds strings to the catalog of `languageCode` ("es").
function Locale.Register(languageCode, strings)
  local catalog = catalogs[languageCode]
  if not catalog then
    catalog = {}
    catalogs[languageCode] = catalog
  end
  for english, translated in pairs(strings) do
    catalog[english] = translated
  end
end

-- Chooses the language from a client locale code ("esES"). Without a call, the client's own locale is used.
function Locale.Use(code)
  language = Locale.LanguageFor(code)
end

function Locale.Language()
  if not language then
    local code = ns.Platform and ns.Platform.GetLocale and ns.Platform.GetLocale()
    language = Locale.LanguageFor(code)
  end
  return language
end

-- The text in the active language, or the English text itself.
function Locale.Translate(text)
  local catalog = catalogs[Locale.Language()]
  return catalog and catalog[text] or text
end

-- Every language that has a catalog, for the tests.
function Locale.Catalogs()
  return catalogs
end

ns.Locale = Locale
ns.L = Locale.Translate
