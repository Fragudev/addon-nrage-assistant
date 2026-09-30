local _, ns = ...

-- Text import/export of raid data, to share it outside the addon channel (Discord, a file...).
-- The text is "NRAGE1:" followed by LibSerialize -> LibDeflate -> print encoding of a list of the same
-- messages the sync uses (EVENT_UPSERT, ATTENDANCE_UPSERT, ASSIGN_UPSERT, DELETE). Import therefore
-- reuses their validation, role check and conflict rules: pasted text is hostile input like any other.
-- `libs` = { serialize = LibSerialize, deflate = LibDeflate }.
local Transfer = {}

local HEADER = "NRAGE1:"

local function sortedKeys(tbl)
  local keys = {}
  for key in pairs(tbl) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

-- Every live record and every tombstone, in a deterministic order (events first, deletes last).
function Transfer.BuildItems(events, tombstones)
  local items = {}
  local function add(messageType, payload)
    items[#items + 1] = { t = messageType, p = payload }
  end

  for _, eventId in ipairs(sortedKeys(events)) do
    local event = events[eventId]
    add("EVENT_UPSERT", ns.EventSync.EventPayload(event))
    for _, key in ipairs(sortedKeys(event.attendance)) do
      add("ATTENDANCE_UPSERT", ns.EventSync.AttendancePayload(eventId, key, event.attendance[key]))
    end
    for _, assignmentId in ipairs(sortedKeys(event.assignments)) do
      add("ASSIGN_UPSERT", ns.EventSync.AssignPayload(eventId, event.assignments[assignmentId]))
    end
  end

  for _, key in ipairs(sortedKeys(tombstones)) do
    local eventId = key:match("^E:([^:]+)$")
    if eventId then
      add("DELETE", { kind = "event", eventId = eventId, rev = tombstones[key].rev })
    else
      local owner, assignmentId = key:match("^A:([^:]+):([^:]+)$")
      if owner then
        add("DELETE", {
          kind = "assignment", eventId = owner, assignmentId = assignmentId, rev = tombstones[key].rev,
        })
      end
    end
  end
  return items
end

-- Returns the text, or nil plus "encode_failed".
function Transfer.Export(libs, events, tombstones)
  local ok, encoded = pcall(function()
    local serialized = libs.serialize:Serialize({ items = Transfer.BuildItems(events, tombstones) })
    return libs.deflate:EncodeForPrint(libs.deflate:CompressDeflate(serialized))
  end)
  if not ok or type(encoded) ~= "string" then
    return nil, "encode_failed"
  end
  return HEADER .. encoded
end

-- Returns the decoded list of { t, p } items, or nil plus
-- "not_string" | "bad_header" | "too_large" | "bad_encoding" | "bad_compression" | "bad_payload".
function Transfer.Decode(libs, text)
  local constants = ns.Constants
  if type(text) ~= "string" then
    return nil, "not_string"
  end
  text = text:match("^%s*(.-)%s*$")
  if text:sub(1, #HEADER) ~= HEADER then
    return nil, "bad_header"
  end
  if #text > constants.IMPORT_MAX_ENCODED_BYTES then
    return nil, "too_large"
  end

  local ok, decoded = pcall(libs.deflate.DecodeForPrint, libs.deflate, text:sub(#HEADER + 1))
  if not ok or type(decoded) ~= "string" then
    return nil, "bad_encoding"
  end

  local decompressed
  ok, decompressed = pcall(libs.deflate.DecompressDeflate, libs.deflate, decoded)
  if not ok or type(decompressed) ~= "string" then
    return nil, "bad_compression"
  end
  if #decompressed > constants.IMPORT_MAX_DECOMPRESSED_BYTES then
    return nil, "too_large"
  end

  local success, value
  ok, success, value = pcall(libs.serialize.Deserialize, libs.serialize, decompressed)
  if not ok or not success or type(value) ~= "table" or type(value.items) ~= "table" then
    return nil, "bad_payload"
  end
  if #value.items > constants.IMPORT_MAX_ITEMS then
    return nil, "too_large"
  end
  return value.items
end

-- Applies pasted text. `ctx` = { events, tombstones, now } as for EventSync; `role` is the importer's
-- own role: importing needs the same right as creating events.
-- Returns { total, applied, skipped = { [reason] = count } }, or nil plus a Decode reason or "forbidden".
function Transfer.Import(libs, text, ctx, role)
  if not ns.PermissionService.Can(role, "manage_events") then
    return nil, "forbidden"
  end
  local items, reason = Transfer.Decode(libs, text)
  if not items then
    return nil, reason
  end

  local summary = { total = #items, applied = 0, skipped = {} }
  local function skip(why)
    summary.skipped[why] = (summary.skipped[why] or 0) + 1
  end

  for _, item in ipairs(items) do
    if type(item) ~= "table" or type(item.t) ~= "string" or not ns.EventSync.IsRaidMessage(item.t) then
      skip("unsupported")
    else
      local message, invalid = ns.Protocol.Validate(ns.Protocol.Build(item.t, item.p, "import"))
      if not message then
        skip(invalid)
      else
        local ok, why = ns.EventSync.Apply(ctx, message, "import", role)
        if ok then
          summary.applied = summary.applied + 1
        else
          skip(why)
        end
      end
    end
  end
  return summary
end

-- One line describing an import summary.
function Transfer.Describe(summary)
  local parts = {}
  for _, why in ipairs(sortedKeys(summary.skipped)) do
    parts[#parts + 1] = ("%s: %d"):format(why, summary.skipped[why])
  end
  local text = ("imported %d of %d record(s)"):format(summary.applied, summary.total)
  if #parts > 0 then
    text = text .. " (skipped - " .. table.concat(parts, ", ") .. ")"
  end
  return text
end

ns.Transfer = Transfer
