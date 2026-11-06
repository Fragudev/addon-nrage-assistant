local _, ns = ...

-- Moving to Intel from another addon (docs/PVP_INTEL_PLAN.md section 3.3). Two sources, both into the personal lists of
-- IntelService, and neither overwrites an entry that is already there:
--   * FromText(service, text, target): one name per line, or names separated by commas. A first line that is just
--     "kos" or "ignore" (a colon is fine) picks the list; `target` is the list when the text has no such line.
--   * FromSpy(service, globals): a best-effort read of the saved data of Spy when it is still loaded. The names of its
--     saved variables are NOT verified, so every access is type-checked, only names are taken (each through
--     IntelModel.CleanName), and a missing or unknown shape imports nothing and says so.
-- Both answer { added, skipped, invalid, limit } (`skipped` counts every name not added: listed already, invalid or
-- over the limit).
local IntelImport = {}

-- Text and tables are not trusted: at most this many bytes of text and this many entries of a table are read.
local TEXT_MAX = 20000
local ENTRIES_MAX = 5000

local TARGETS = { kos = true, ignore = true }

local function newReport()
  return { added = 0, skipped = 0, invalid = 0, limit = 0 }
end

-- Adds `name` to the personal list `target`, unless it is on either personal list already.
local function addOne(service, report, name, target)
  local clean = ns.IntelModel.CleanName(name)
  if not clean then
    report.skipped, report.invalid = report.skipped + 1, report.invalid + 1
    return
  end
  local key = ns.IntelModel.Key(clean)
  if service.intel.kos[key] or service.intel.ignore[key] then
    report.skipped = report.skipped + 1
    return
  end
  local entry, why
  if target == "ignore" then
    entry, why = service:AddIgnore(clean)
  else
    entry, why = service:AddKos({ name = clean })
  end
  if entry then
    report.added = report.added + 1
  else
    report.skipped = report.skipped + 1
    if why == "limit" then
      report.limit = report.limit + 1
    else
      report.invalid = report.invalid + 1
    end
  end
end

-- The names in `text` and the list a first line picked (or nil).
function IntelImport.Parse(text)
  if type(text) ~= "string" then
    return {}, nil
  end
  text = text:sub(1, TEXT_MAX)
  local names, target = {}, nil
  local first = true
  for line in (text .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
    local trimmed = line:match("^%s*(.-)%s*$")
    local header = first and trimmed:lower():match("^(%a+):?$")
    if header and TARGETS[header] then
      target = header
    else
      for piece in trimmed:gmatch("[^,;]+") do
        local name = piece:match("^%s*(.-)%s*$")
        if name ~= "" and #names < ENTRIES_MAX then
          names[#names + 1] = name
        end
      end
    end
    if trimmed ~= "" then
      first = false
    end
  end
  return names, target
end

function IntelImport.FromText(service, text, target)
  local names, picked = IntelImport.Parse(text)
  target = picked or (TARGETS[target] and target) or "kos"
  local report = newReport()
  for _, name in ipairs(names) do
    addOne(service, report, name, target)
  end
  report.target = target
  return report
end

-- The names a table of an unknown shape holds: the keys when they are strings (`{ [name] = data }`), else the values
-- that are strings (`{ "name", ... }`). A table that raises while it is read, or has nothing usable, gives {}.
local function namesOf(tbl)
  local names = {}
  if type(tbl) ~= "table" then
    return names
  end
  pcall(function()
    local seen = 0
    for key, value in pairs(tbl) do
      seen = seen + 1
      if seen > ENTRIES_MAX then
        break
      end
      if type(key) == "string" then
        names[#names + 1] = key
      elseif type(value) == "string" then
        names[#names + 1] = value
      end
    end
  end)
  table.sort(names)
  return names
end

-- The places Spy is thought to keep its lists, each as { global, field, target } (names unverified).
IntelImport.SPY_SOURCES = {
  { global = "SpyPerCharDB", field = "KOSData", target = "kos" },
  { global = "SpyPerCharDB", field = "IgnoreData", target = "ignore" },
  { global = "SpyDB", field = "kosData", target = "kos" },
}

-- `globals` is the table of globals (_G). Returns the report, or nil plus "not_found" when no source holds a table.
function IntelImport.FromSpy(service, globals)
  if type(globals) ~= "table" then
    return nil, "not_found"
  end
  local report, found = newReport(), false
  for _, source in ipairs(IntelImport.SPY_SOURCES) do
    local holder = globals[source.global]
    local list = type(holder) == "table" and rawget(holder, source.field) or nil
    if type(list) == "table" then
      found = true
      for _, name in ipairs(namesOf(list)) do
        addOne(service, report, name, source.target)
      end
    end
  end
  if not found then
    return nil, "not_found"
  end
  return report
end

ns.IntelImport = IntelImport
