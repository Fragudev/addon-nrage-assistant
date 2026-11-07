local _, ns = ...

-- Who in the guild runs the addon, and which version: what the Installed check tab (Admin, gm and cogm) lists.
--   db.global.installs = { [name] = { version = string or nil, incompatible = true or nil, seenAt = server time } }
-- A record is written for every member heard from: a HELLO carries the version, any other valid message only says the
-- addon is there, and a message on another protocol version marks the record incompatible. The table is saved, so an
-- offline member keeps the last version seen. It is bounded: when it is full, the member heard from longest ago goes.
local InstallDirectory = {}

local function count(installs)
  local total = 0
  for _ in pairs(installs) do
    total = total + 1
  end
  return total
end

local function evictOldest(installs)
  local oldestName, oldestAt
  for name, record in pairs(installs) do
    local at = type(record) == "table" and type(record.seenAt) == "number" and record.seenAt or 0
    if not oldestAt or at < oldestAt or (at == oldestAt and name < oldestName) then
      oldestName, oldestAt = name, at
    end
  end
  if oldestName then
    installs[oldestName] = nil
  end
end

-- Notes that `name` was heard from at `now`. info: { version = string } for a HELLO, { incompatible = true } for a
-- message on another protocol version, {} for any other message (the version seen before is kept). `max` (optional)
-- defaults to Constants.INSTALLS_MAX_ENTRIES. Returns false when nothing could be written.
function InstallDirectory.Note(installs, name, info, now, max)
  if type(installs) ~= "table" or type(name) ~= "string" or name == "" or type(now) ~= "number" then
    return false
  end
  info = info or {}
  local record = installs[name]
  if type(record) ~= "table" then
    max = max or ns.Constants.INSTALLS_MAX_ENTRIES
    while count(installs) >= max and next(installs) ~= nil do
      evictOldest(installs)
    end
    record = {}
    installs[name] = record
  end
  if type(info.version) == "string" and info.version ~= "" then
    record.version = info.version
    record.incompatible = nil
  elseif info.incompatible then
    record.incompatible = true
  end
  record.seenAt = now
  return true
end

-- The numbers of a version ("1.10.2" -> { 1, 10, 2 }), or nil when it has none ("dev", an unpackaged build).
local function parts(version)
  if type(version) ~= "string" then
    return nil
  end
  local list = {}
  for number in version:gmatch("%d+") do
    list[#list + 1] = tonumber(number)
  end
  return #list > 0 and list or nil
end

-- -1, 0 or 1 as `a` is older than, the same as or newer than `b`, compared number by number ("1.10" is newer than
-- "1.9", a missing number counts as 0). nil when either has no number to compare.
function InstallDirectory.CompareVersions(a, b)
  local left, right = parts(a), parts(b)
  if not left or not right then
    return nil
  end
  for index = 1, math.max(#left, #right) do
    local x, y = left[index] or 0, right[index] or 0
    if x ~= y then
      return x < y and -1 or 1
    end
  end
  return 0
end

-- The newest version among the records and `ownVersion` (optional), or nil when none can be compared.
function InstallDirectory.Newest(installs, ownVersion)
  local newest = parts(ownVersion) and ownVersion or nil
  for _, record in pairs(installs or {}) do
    local version = type(record) == "table" and not record.incompatible and record.version or nil
    if parts(version) and (not newest or InstallDirectory.CompareVersions(version, newest) == 1) then
      newest = version
    end
  end
  return newest
end

-- What a member's record says, against the newest version seen:
--   "current"      the newest version (or newer)        "outdated"   an older version
--   "installed"    the addon is there, the version is not known (presence only, or a build with no number)
--   "incompatible" it speaks another protocol version
--   "missing"      no record and online now: a member with the addon announces itself when it logs in
--   "unseen"       no record and offline: never heard from
function InstallDirectory.Status(record, newest, online)
  if type(record) ~= "table" then
    return online and "missing" or "unseen"
  end
  if record.incompatible then
    return "incompatible"
  end
  local comparison = newest and InstallDirectory.CompareVersions(record.version, newest)
  if comparison == nil then
    return "installed"
  end
  return comparison < 0 and "outdated" or "current"
end

ns.InstallDirectory = InstallDirectory
