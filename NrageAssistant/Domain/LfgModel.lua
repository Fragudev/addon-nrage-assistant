local _, ns = ...

-- Pure rules of a Groups post (docs/LFG_PLAN.md): the kinds, the roles, the needs of a party and the payloads that
-- travel on the wire. Nothing here touches the client.
--
-- A post is { kind, title, needs = { tank, heal, dps }, members, size?, minLevel?, note?, party? }. `members` counts
-- the leader and whoever is already in the group; needs plus members never exceed the size of the post: `size` (one of
-- Constants.LFG_RAID_SIZES) for a raid, which is the kind `raid` and only that kind, else Constants.LFG_PARTY_SIZE.
-- `party` lists the seats taken, the leader first: { { c = class file token, r = wire role or nil } }, exactly
-- `members` long. It is optional: older clients do not send it, and a party the client cannot read is left out.
local LfgModel = {}

-- In display order; the sets used to validate are in Constants.
LfgModel.KINDS = { "dungeon", "quest", "other", "raid" }
LfgModel.ROLES = { "tank", "heal", "dps" }

local WIRE_ROLES = { Tank = "tank", Heal = "heal", Dps = "dps" }

-- The wire role (tank, heal, dps) for a declared role in any spelling, or nil.
function LfgModel.WireRole(value)
  local role = ns.ProfileService.NormalizeRole(value)
  return role and WIRE_ROLES[role] or nil
end

local MAX_CLASS_LENGTH = 20

-- A clean copy of `party` for a post of `members` seats, or nil when it is missing or does not fit: every seat needs a
-- class file token ("WARRIOR") and may carry a wire role.
function LfgModel.CleanParty(party, members)
  if type(party) ~= "table" or type(members) ~= "number" or #party ~= members then
    return nil
  end
  local clean = {}
  for index = 1, members do
    local seat = party[index]
    if type(seat) ~= "table" then
      return nil
    end
    local class = seat.c
    if not (type(class) == "string" and #class <= MAX_CLASS_LENGTH and class:find("^%u+$")) then
      return nil
    end
    local role = seat.r
    if role ~= nil and not (type(role) == "string" and ns.Constants.LFG_ROLES[role]) then
      return nil
    end
    clean[index] = { c = class, r = role }
  end
  return clean
end

-- true when two parties (clean or nil) show the same seats.
function LfgModel.SameParty(a, b)
  if a == nil or b == nil then
    return a == b
  end
  if #a ~= #b then
    return false
  end
  for index = 1, #a do
    if a[index].c ~= b[index].c or a[index].r ~= b[index].r then
      return false
    end
  end
  return true
end

local function copyParty(party)
  if not party then
    return nil
  end
  local copy = {}
  for index, seat in ipairs(party) do
    copy[index] = { c = seat.c, r = seat.r }
  end
  return copy
end
LfgModel.CopyParty = copyParty

local function trimmed(value)
  return type(value) == "string" and value:match("^%s*(.-)%s*$") or value
end

-- The number of seats of a post: its raid size, or a party.
function LfgModel.SizeOf(post)
  return post and post.size or ns.Constants.LFG_PARTY_SIZE
end

function LfgModel.IsRaid(post)
  return post ~= nil and post.size ~= nil
end

-- How many applicants the leader of `post` keeps at once.
function LfgModel.ApplicantsMax(post)
  return LfgModel.IsRaid(post) and ns.Constants.LFG_RAID_APPLICANTS_MAX or ns.Constants.LFG_APPLICANTS_MAX
end

-- The share of each role in a suggested group, before it is fitted to the free seats.
local DEFAULT_SHARES = {
  [5] = { tank = 1, heal = 1, dps = 3 },
  [10] = { tank = 2, heal = 3, dps = 5 },
  [20] = { tank = 3, heal = 5, dps = 12 },
  [25] = { tank = 3, heal = 6, dps = 16 },
  [40] = { tank = 4, heal = 10, dps = 26 },
}

-- The needs a new post of `size` seats starts with when the leader's group has `members`: a usual composition minus
-- the leader, fitted to the free seats. A party asks for one of each role, as it always did.
function LfgModel.DefaultNeeds(size, members)
  local room = size - math.max(1, members or 1)
  if size == ns.Constants.LFG_PARTY_SIZE or not DEFAULT_SHARES[size] then
    return LfgModel.FitNeeds({ tank = 1, heal = 1, dps = 1 }, room)
  end
  local shares = DEFAULT_SHARES[size]
  return LfgModel.FitNeeds({ tank = shares.tank, heal = shares.heal, dps = shares.dps - 1 }, room)
end

local function cleanNeeds(needs, size)
  if type(needs) ~= "table" then
    return nil
  end
  local clean = {}
  for _, role in ipairs(LfgModel.ROLES) do
    local count = needs[role]
    if count == nil then
      count = 0
    end
    if not ns.Validate.Int(count, 0, size - 1) then
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
  return LfgModel.RemainingNeeds(post) == 0 or post.members >= LfgModel.SizeOf(post)
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

-- The size of a post of `kind` that says `size`, or nil when they do not go together: a raid needs one of
-- Constants.LFG_RAID_SIZES, any other kind is a party and carries no size.
local function sizeFor(kind, size)
  local constants = ns.Constants
  if kind == "raid" then
    return (type(size) == "number" and constants.LFG_RAID_SIZE_SET[size]) and size or nil
  end
  return size == nil and constants.LFG_PARTY_SIZE or nil
end
LfgModel.SizeFor = sizeFor

-- The clean post for `fields` ({ kind, title, needs, members, size, minLevel, note, party }), or nil plus "bad_kind" |
-- "bad_size" | "bad_title" | "bad_needs" | "no_needs" | "bad_members" | "full" | "bad_level" | "bad_note".
function LfgModel.NewPost(fields)
  local constants = ns.Constants
  if type(fields) ~= "table" then
    return nil, "bad_kind"
  end
  if not (type(fields.kind) == "string" and constants.LFG_KINDS[fields.kind]) then
    return nil, "bad_kind"
  end
  local size = sizeFor(fields.kind, fields.size)
  if not size then
    return nil, "bad_size"
  end
  local title = trimmed(fields.title)
  if not ns.Validate.Text(title, constants.LFG_TITLE_MAX) then
    return nil, "bad_title"
  end
  local needs = cleanNeeds(fields.needs, size)
  if not needs then
    return nil, "bad_needs"
  end
  if not ns.Validate.Int(fields.members, 1, size) then
    return nil, "bad_members"
  end
  if fields.members >= size then
    return nil, "full"
  end
  local total = needs.tank + needs.heal + needs.dps
  if total == 0 then
    return nil, "no_needs"
  end
  if total + fields.members > size then
    return nil, "bad_needs"
  end
  local post = { kind = fields.kind, title = title, needs = needs, members = fields.members }
  if fields.kind == "raid" then
    post.size = size
  end
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
  -- A party that does not fit is left out rather than refusing the post: it only decorates the seats.
  post.party = LfgModel.CleanParty(fields.party, fields.members)
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
    size = post.size,
    minLevel = post.minLevel,
    note = post.note,
    party = copyParty(post.party),
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
