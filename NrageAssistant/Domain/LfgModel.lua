local _, ns = ...

-- Pure rules of a Groups post (docs/LFG_PLAN.md): the kinds, the roles, the needs of a party and the payloads that
-- travel on the wire. Nothing here touches the client.
--
-- A post is { kind, title, needs = { tank, heal, dps }, members, minLevel?, note? }. `members` counts the leader and
-- whoever is already in the party; needs plus members never exceed Constants.LFG_PARTY_SIZE.
local LfgModel = {}

-- In display order; the sets used to validate are in Constants.
LfgModel.KINDS = { "dungeon", "quest", "other" }
LfgModel.ROLES = { "tank", "heal", "dps" }

local WIRE_ROLES = { Tank = "tank", Heal = "heal", Dps = "dps" }

-- The wire role (tank, heal, dps) for a declared role in any spelling, or nil.
function LfgModel.WireRole(value)
  local role = ns.ProfileService.NormalizeRole(value)
  return role and WIRE_ROLES[role] or nil
end

local function trimmed(value)
  return type(value) == "string" and value:match("^%s*(.-)%s*$") or value
end

local function cleanNeeds(needs)
  if type(needs) ~= "table" then
    return nil
  end
  local clean = {}
  for _, role in ipairs(LfgModel.ROLES) do
    local count = needs[role]
    if count == nil then
      count = 0
    end
    if not ns.Validate.Int(count, 0, ns.Constants.LFG_NEED_MAX) then
      return nil
    end
    clean[role] = count
  end
  return clean
end

-- Seats still to fill.
function LfgModel.RemainingNeeds(post)
  return post.needs.tank + post.needs.heal + post.needs.dps
end

function LfgModel.IsFull(post)
  return LfgModel.RemainingNeeds(post) == 0 or post.members >= ns.Constants.LFG_PARTY_SIZE
end

-- Lowers the needs, the last role first, until they fit in `room` seats. Returns a new table.
function LfgModel.FitNeeds(needs, room)
  local fitted = { tank = needs.tank, heal = needs.heal, dps = needs.dps }
  local excess = fitted.tank + fitted.heal + fitted.dps - math.max(0, room)
  for index = #LfgModel.ROLES, 1, -1 do
    if excess <= 0 then
      break
    end
    local role = LfgModel.ROLES[index]
    local cut = math.min(fitted[role], excess)
    fitted[role] = fitted[role] - cut
    excess = excess - cut
  end
  return fitted
end

-- The clean post for `fields` ({ kind, title, needs, members, minLevel, note }), or nil plus "bad_kind" | "bad_title"
-- | "bad_needs" | "no_needs" | "bad_members" | "full" | "bad_level" | "bad_note".
function LfgModel.NewPost(fields)
  local constants = ns.Constants
  if type(fields) ~= "table" then
    return nil, "bad_kind"
  end
  if not (type(fields.kind) == "string" and constants.LFG_KINDS[fields.kind]) then
    return nil, "bad_kind"
  end
  local title = trimmed(fields.title)
  if not ns.Validate.Text(title, constants.LFG_TITLE_MAX) then
    return nil, "bad_title"
  end
  local needs = cleanNeeds(fields.needs)
  if not needs then
    return nil, "bad_needs"
  end
  if not ns.Validate.Int(fields.members, 1, constants.LFG_PARTY_SIZE) then
    return nil, "bad_members"
  end
  if fields.members >= constants.LFG_PARTY_SIZE then
    return nil, "full"
  end
  local total = needs.tank + needs.heal + needs.dps
  if total == 0 then
    return nil, "no_needs"
  end
  if total + fields.members > constants.LFG_PARTY_SIZE then
    return nil, "bad_needs"
  end
  local post = { kind = fields.kind, title = title, needs = needs, members = fields.members }
  if fields.minLevel ~= nil then
    if not ns.Validate.Int(fields.minLevel, 1, constants.LFG_LEVEL_MAX) then
      return nil, "bad_level"
    end
    post.minLevel = fields.minLevel
  end
  local note = trimmed(fields.note)
  if note ~= nil and note ~= "" then
    if not ns.Validate.Text(note, constants.LFG_NOTE_MAX) then
      return nil, "bad_note"
    end
    post.note = note
  end
  return post
end

-- An open post as LFG_POST carries it.
function LfgModel.PostPayload(pid, rev, post)
  return {
    pid = pid,
    rev = rev,
    s = "open",
    kind = post.kind,
    title = post.title,
    needs = { tank = post.needs.tank, heal = post.needs.heal, dps = post.needs.dps },
    members = post.members,
    minLevel = post.minLevel,
    note = post.note,
  }
end

function LfgModel.ClosedPayload(pid, rev, outcome)
  return { pid = pid, rev = rev, s = "closed", o = outcome }
end

function LfgModel.ApplyPayload(pid, role, note)
  return { pid = pid, s = "apply", role = role, note = note }
end

function LfgModel.WithdrawPayload(pid)
  return { pid = pid, s = "withdraw" }
end

function LfgModel.AcceptPayload(pid, to)
  return { pid = pid, s = "accept", to = to }
end

function LfgModel.DeclinePayload(pid, to)
  return { pid = pid, s = "decline", to = to }
end

ns.LfgModel = LfgModel
