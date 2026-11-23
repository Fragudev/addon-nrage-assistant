local _, ns = ...

-- The professions, known by their English and Spanish names and by the skill line id the client gives them. Names
-- come in the language of whoever wrote them: the client of each player names its own professions, and a rule keeps
-- the name an admin picked in the language of the addon. This catalog lets the code compare them across languages
-- and show them in the language of the addon. A name it does not know is compared and shown as it came.
local Professions = {}

local L = ns.L

-- In the order of the Rules picker. `id` is the base skill line id (C_TradeSkillUI.GetBaseProfessionInfo). `spell`
-- is the profession's own spell, whose name the client gives in its language (none for Herbalism: its spell is
-- "Herb Gathering"; the catalog names it).
Professions.ENTRIES = {
  { key = "alchemy", en = "Alchemy", es = "Alquimia", id = 171, spell = 2259 },
  { key = "blacksmithing", en = "Blacksmithing", es = "Herrería", id = 164, spell = 2018 },
  { key = "enchanting", en = "Enchanting", es = "Encantamiento", id = 333, spell = 7411 },
  { key = "engineering", en = "Engineering", es = "Ingeniería", id = 202, spell = 4036 },
  { key = "herbalism", en = "Herbalism", es = "Herboristería", id = 182 },
  { key = "leatherworking", en = "Leatherworking", es = "Peletería", id = 165, spell = 2108 },
  { key = "mining", en = "Mining", es = "Minería", id = 186, spell = 2575 },
  { key = "skinning", en = "Skinning", es = "Desuello", id = 393, spell = 8613 },
  { key = "tailoring", en = "Tailoring", es = "Sastrería", id = 197, spell = 3908 },
  { key = "cooking", en = "Cooking", es = "Cocina", id = 185, spell = 2550 },
  { key = "fishing", en = "Fishing", es = "Pesca", id = 356, spell = 7620 },
  { key = "firstaid", en = "First Aid", es = "Primeros auxilios", id = 129, spell = 3273 },
}

-- The accented vowels of Spanish (UTF-8), lower and upper case, and the plain vowel each stands for.
local ACCENTS = {
  ["\195\161"] = "a",
  ["\195\169"] = "e",
  ["\195\173"] = "i",
  ["\195\179"] = "o",
  ["\195\186"] = "u",
  ["\195\129"] = "a",
  ["\195\137"] = "e",
  ["\195\141"] = "i",
  ["\195\147"] = "o",
  ["\195\154"] = "u",
}

-- A name trimmed, without accents and in lower case: "  Herrería " -> "herreria".
local function normalize(name)
  if type(name) ~= "string" then
    return nil
  end
  local plain = name:match("^%s*(.-)%s*$"):gsub("\195[\129-\191]", function(char)
    return ACCENTS[char] or char
  end)
  return plain:lower()
end

-- The English names through L, written out so the locale check sees every one of them.
local NAMES = ns.Locale.Table(function()
  return {
    alchemy = L("Alchemy"),
    blacksmithing = L("Blacksmithing"),
    enchanting = L("Enchanting"),
    engineering = L("Engineering"),
    herbalism = L("Herbalism"),
    leatherworking = L("Leatherworking"),
    mining = L("Mining"),
    skinning = L("Skinning"),
    tailoring = L("Tailoring"),
    cooking = L("Cooking"),
    fishing = L("Fishing"),
    firstaid = L("First Aid"),
  }
end)

-- The name the client itself gives a profession, when the addon shows the language of the client (a name in another
-- language is not the client's to give); nil when there is no such name, and the catalog names it then.
local function clientName(entry)
  local platform = ns.Platform
  if not entry.spell or not platform or not platform.GetSpellName or not platform.GetLocale then
    return nil
  end
  if ns.Locale.Language() ~= ns.Locale.LanguageFor(platform.GetLocale()) then
    return nil
  end
  return platform.GetSpellName(entry.spell)
end

local function displayName(entry)
  return clientName(entry) or NAMES[entry.key]
end

local byName, byId = {}, {}
for _, entry in ipairs(Professions.ENTRIES) do
  byName[normalize(entry.en)] = entry
  byName[normalize(entry.es)] = entry
  byId[entry.id] = entry
end

-- The key ("cooking") of a profession name in English or Spanish, or nil when it is not in the catalog.
function Professions.Key(name)
  local entry = byName[normalize(name) or ""]
  return entry and entry.key or nil
end

-- The key of a skill line id, or nil.
function Professions.KeyForId(id)
  local entry = byId[id]
  return entry and entry.key or nil
end

-- A profession name in the language of the addon; a name not in the catalog comes back as it is.
function Professions.Name(name)
  local entry = byName[normalize(name) or ""]
  return entry and displayName(entry) or name
end

-- The name of a skill line id in the language of the addon, or `fallback` (the name that came with it).
function Professions.NameForId(id, fallback)
  local entry = byId[id]
  return entry and displayName(entry) or fallback
end

-- Whether two names are the same profession: by the catalog, else by the plain names.
function Professions.Same(a, b)
  local left, right = normalize(a), normalize(b)
  if not left or not right then
    return false
  end
  local first, second = byName[left], byName[right]
  if first or second then
    return first == second
  end
  return left == right
end

-- The names of every profession in the catalog, in the language of the addon.
function Professions.List()
  local names = {}
  for index, entry in ipairs(Professions.ENTRIES) do
    names[index] = displayName(entry)
  end
  return names
end

ns.Professions = Professions
