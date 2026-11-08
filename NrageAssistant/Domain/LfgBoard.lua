local _, ns = ...

-- The posts the guild members published (docs/LFG_PLAN.md 3.2). In memory only; nothing is saved. Nothing here
-- touches the client: the clock and the guild membership are injected.
--
--   * One post per sender, keyed by Validate.NameKey of the sender (never a name from the payload).
--   * A higher `rev` replaces the post, an equal one only refreshes `lastSeen`, a lower one is dropped. A different
--     `pid` from the same sender replaces the old post whatever its `rev`.
--   * `lastSeen` is the receiver's own clock. A post nobody repeated for Constants.LFG_POST_TTL is dropped.
--   * A closed post stays as a tombstone, hidden from Query, until it is stale, so a late `open` with a lower `rev`
--     cannot bring it back.
--
-- deps = { now = function() -> seconds (monotonic), isMember = function(name) -> boolean (optional: everyone) }
local LfgBoard = {}
LfgBoard.__index = LfgBoard

function LfgBoard.New(deps)
  return setmetatable({ deps = deps, entries = {}, count = 0 }, LfgBoard)
end

local function keyOf(sender)
  return ns.Validate.NameKey(sender)
end

local function isMember(self, name)
  if not self.deps.isMember then
    return true
  end
  local ok, result = pcall(self.deps.isMember, name)
  return ok and result == true
end

local function stale(self, entry)
  return self.deps.now() - entry.lastSeen > ns.Constants.LFG_POST_TTL
end

local function fresh(self, entry)
  return not stale(self, entry) and isMember(self, entry.owner)
end

-- A copy for the callers: the board's own tables are never handed out.
local function view(self, entry)
  local copy = {
    owner = entry.owner,
    pid = entry.pid,
    rev = entry.rev,
    state = entry.state,
    outcome = entry.outcome,
    kind = entry.kind,
    title = entry.title,
    members = entry.members,
    minLevel = entry.minLevel,
    note = entry.note,
    postedAt = entry.postedAt,
    lastSeen = entry.lastSeen,
    age = math.max(0, self.deps.now() - entry.postedAt),
  }
  if entry.needs then
    copy.needs = { tank = entry.needs.tank, heal = entry.needs.heal, dps = entry.needs.dps }
  end
  copy.party = ns.LfgModel.CopyParty(entry.party)
  return copy
end

-- Applies a validated LFG_POST payload of `sender`. Returns true, or false plus "bad_post" | "not_member" | "stale" |
-- "limit".
function LfgBoard:Apply(sender, payload)
  if type(sender) ~= "string" or sender == "" or type(payload) ~= "table" then
    return false, "bad_post"
  end
  if not (type(payload.pid) == "string" and ns.Validate.Int(payload.rev, 1, 2147483647)) then
    return false, "bad_post"
  end
  if payload.s ~= "open" and payload.s ~= "closed" then
    return false, "bad_post"
  end
  if not isMember(self, sender) then
    return false, "not_member"
  end

  local key = keyOf(sender)
  local now = self.deps.now()
  local entry = self.entries[key]
  if entry and entry.pid == payload.pid then
    if payload.rev < entry.rev then
      return false, "stale"
    end
    if payload.rev == entry.rev then
      entry.lastSeen = now
      return true
    end
  elseif not entry then
    if self.count >= ns.Constants.LFG_BOARD_MAX then
      self:Prune()
      if self.count >= ns.Constants.LFG_BOARD_MAX then
        return false, "limit"
      end
    end
    self.count = self.count + 1
  end

  local replacement = {
    owner = sender,
    pid = payload.pid,
    rev = payload.rev,
    state = payload.s,
    lastSeen = now,
    -- The age of a post counts from the first message of its `pid`, in the receiver's clock.
    postedAt = (entry and entry.pid == payload.pid) and entry.postedAt or now,
  }
  if payload.s == "open" then
    replacement.kind = payload.kind
    replacement.title = payload.title
    replacement.needs = { tank = payload.needs.tank, heal = payload.needs.heal, dps = payload.needs.dps }
    replacement.members = payload.members
    replacement.minLevel = payload.minLevel
    replacement.note = payload.note
    replacement.party = ns.LfgModel.CleanParty(payload.party, payload.members)
  else
    replacement.outcome = payload.o
  end
  self.entries[key] = replacement
  return true
end

-- Drops the posts nobody repeated for Constants.LFG_POST_TTL. Returns how many.
function LfgBoard:Prune()
  local removed = 0
  for key, entry in pairs(self.entries) do
    if stale(self, entry) then
      self.entries[key] = nil
      self.count = self.count - 1
      removed = removed + 1
    end
  end
  return removed
end

function LfgBoard:Remove(sender)
  local key = type(sender) == "string" and keyOf(sender) or nil
  if key and self.entries[key] then
    self.entries[key] = nil
    self.count = self.count - 1
  end
end

-- The post of `sender` as { owner, pid, rev, state, outcome, kind, title, needs, members, minLevel, note, postedAt,
-- lastSeen, age }, or nil. A closed post (a tombstone) is returned too; a stale one is not.
function LfgBoard:Get(sender)
  local entry = type(sender) == "string" and self.entries[keyOf(sender)] or nil
  if entry and fresh(self, entry) then
    return view(self, entry)
  end
  return nil
end

-- The post with this `pid`, as Get returns it, or nil.
function LfgBoard:ByPid(pid)
  for _, entry in pairs(self.entries) do
    if entry.pid == pid and fresh(self, entry) then
      return view(self, entry)
    end
  end
  return nil
end

-- The open posts, newest first. filter = { kind = "dungeon"|..., role = "tank"|... } (both optional): a post matches a
-- role when it still needs it.
function LfgBoard:Query(filter)
  filter = filter or {}
  local list = {}
  for _, entry in pairs(self.entries) do
    local match = entry.state == "open" and fresh(self, entry)
    if match and filter.kind and entry.kind ~= filter.kind then
      match = false
    end
    if match and filter.role and (entry.needs[filter.role] or 0) <= 0 then
      match = false
    end
    if match then
      list[#list + 1] = view(self, entry)
    end
  end
  table.sort(list, function(a, b)
    if a.postedAt ~= b.postedAt then
      return a.postedAt > b.postedAt
    end
    return ns.Validate.NameKey(a.owner) < ns.Validate.NameKey(b.owner)
  end)
  return list
end

-- How many open posts there are, with the same rules as Query.
function LfgBoard:OpenCount()
  return #self:Query()
end

ns.LfgBoard = LfgBoard
