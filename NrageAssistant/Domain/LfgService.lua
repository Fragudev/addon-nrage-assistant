local _, ns = ...

-- The Groups flow (docs/LFG_PLAN.md 2 and 3.3), one state machine per client that runs both sides: the leader of an
-- own post and the applicant of one application. Nothing here touches the client: the clock, the timers, the
-- transport, the eligibility rules and the game actions (invite) are injected, so the rules are tested with fakes.
--
--   Leader: Post() publishes an open post; applicants arrive as rows ("pending"); Invite() is a button click that asks
--     the game to invite and, only if the game accepts, sends `accept` ("invited", then "retry" if the join never
--     came); Decline() answers `decline`.
--     OnGroupChanged() turns a joined applicant into one seat less, and closes the post when it is full or when the
--     party stops being the one that was posted (outcome `full` | `cancelled` | `expired`).
--   Applicant: Apply() -> "applied" -> "invited" (the leader accepted) -> "joined". It ends as "declined", "withdrawn"
--     or "expired" (a timeout, or the post closed or was replaced).
--   Own messages are never received, so every change of the own post is also applied to the board.
--   Authority comes from the sender, never from the payload: an application is only heard by the owner of the post
--     it names, and an `accept` or a `decline` only counts from the owner of that `pid` on the local board and when
--     `to` is this client.
--   A `/reload` loses the post and the application; the time to live clears them on the other clients.
--
-- deps = { now = function() -> seconds (monotonic), schedule = function(delay, fn),
--          send = { post = function(payload) -> ok, reason, apply = function(payload) -> ok, reason }
--            (live only: they refuse during the lockdown),
--          isLocked = function() -> boolean, ownName = function() -> string, newId = function() -> pid,
--          ownLevel = function() -> number or nil (unknown),
--          eligibility = { post = function() -> ok, reason, apply = function() -> ok, reason,
--            invite = function() -> ok, reason }  (see LfgService.Eligibility),
--          invite = function(name) -> ok, reason, isGroupMember = function(name) -> boolean,
--          groupSize = function() -> number (0 or 1 when alone), isRaid = function() -> boolean (only `true` counts),
--          isLeader = function() -> boolean, board = LfgBoard, onChange = function() (optional),
--          partyClasses = function() -> { { name, class } } the party, the player first (optional),
--          ownRole = function() -> wire role or nil, the player's declared role (optional),
--          onNewPost = function(sender, post) a group of another member that was not on the board opened; not called
--            for Constants.LFG_ALERT_WARMUP after New (optional) }
local LfgService = {}
LfgService.__index = LfgService

local ACTIVE = { applied = true, invited = true }

function LfgService.New(deps)
  return setmetatable({ deps = deps, post = nil, application = nil, tokens = 0, startedAt = deps.now() }, LfgService)
end

local function changed(self)
  if self.deps.onChange then
    pcall(self.deps.onChange)
  end
end

local function locked(self)
  local ok, isLocked = pcall(self.deps.isLocked)
  return not ok or isLocked == true
end

local function transmit(self, channel, payload)
  local ok, sent, reason = pcall(self.deps.send[channel], payload)
  if not ok then
    return false, "error"
  end
  return sent == true, reason
end

-- Asks an eligibility rule; a rule that raises refuses.
local function eligible(rule, ...)
  local ok, allowed, reason = pcall(rule, ...)
  if not ok then
    return false, "error"
  end
  return allowed == true, reason
end

local function ownName(self)
  local ok, name = pcall(self.deps.ownName)
  return ok and type(name) == "string" and name or ""
end

local function sameName(a, b)
  return type(a) == "string" and type(b) == "string" and ns.Validate.NameKey(a) == ns.Validate.NameKey(b)
end

local function isMemberOfGroup(self, name)
  local ok, member = pcall(self.deps.isGroupMember, name)
  return ok and member == true
end

-- The size of the group, or nil when the client cannot say.
local function groupSize(self)
  local ok, size = pcall(self.deps.groupSize)
  if ok and type(size) == "number" and size >= 0 then
    return size
  end
  return nil
end

-- Runs `fn` after `delay` seconds; the timers are never cancelled, so `fn` checks that its target is still current.
local function after(self, delay, fn)
  self.deps.schedule(delay, fn)
end

local function copyNeeds(needs)
  return { tank = needs.tank, heal = needs.heal, dps = needs.dps }
end

---------------------------------------------------------------------------------------------------------------------
-- Leader: the own post
---------------------------------------------------------------------------------------------------------------------

local function postPayload(post)
  return ns.LfgModel.PostPayload(post.pid, post.rev, post.fields)
end

-- Sends the own post and puts it on the board. Without `strict` the board takes it even when the send is refused (a
-- lockdown): the next Republish sends the current `rev`. With `strict` a refused send leaves the board as it was.
local function publish(self, post, strict)
  local payload = postPayload(post)
  local sent, why = transmit(self, "post", payload)
  if sent or not strict then
    self.deps.board:Apply(ownName(self), payload)
  end
  return sent, why
end

-- Ends the own post. `strict` (a click) keeps the post when the close message cannot be sent; an automatic close
-- ends it locally anyway and the time to live clears the board of the others, and is remembered in `closed` so the
-- leader can see that it ended and why (until Dismiss or a new post).
local function closePost(self, outcome, strict)
  local post = self.post
  local payload = ns.LfgModel.ClosedPayload(post.pid, post.rev + 1, outcome)
  local sent, why = transmit(self, "post", payload)
  if strict and not sent then
    return false, why or "error"
  end
  self.post = nil
  if not strict then
    self.closed = { title = post.fields.title, outcome = outcome }
  end
  self.deps.board:Apply(ownName(self), payload)
  changed(self)
  return true
end

local function members(self)
  local size = groupSize(self)
  return math.max(1, size or 1)
end

-- The key of a joined member's role: the name without a realm, so the party (UnitName) and the applicant (the sender)
-- meet.
local function roleKey(name)
  if type(name) ~= "string" then
    return nil
  end
  return ns.Validate.NameKey(name:match("^[^%-]+") or name)
end

-- The seats of the own post: { { c = class, r = role } } for `count` members, the leader first, or nil when the client
-- cannot read the whole party. The leader's role is the declared one; a member's role is the one they joined as
-- (`roles`, by roleKey), unknown for whoever was in the party before.
local function partyOf(self, count, roles)
  if not self.deps.partyClasses then
    return nil
  end
  local ok, seats = pcall(self.deps.partyClasses)
  if not (ok and type(seats) == "table" and #seats == count) then
    return nil
  end
  local party = {}
  for index, seat in ipairs(seats) do
    local role
    if index == 1 then
      local okRole, own = pcall(self.deps.ownRole or function() end)
      role = okRole and own or nil
    else
      local key = roleKey(seat.name)
      role = key and roles and roles[key] or nil
    end
    party[index] = { c = seat.class, r = role }
  end
  return ns.LfgModel.CleanParty(party, count)
end

local function cleanLevel(value)
  if value == false or value == 0 then
    return nil
  end
  return value
end

-- The fields of the model for a post being created or changed: `fields` over `base`.
local function merge(base, fields)
  local merged = {}
  for _, key in ipairs({ "kind", "title", "needs", "minLevel", "note" }) do
    if base and base[key] ~= nil then
      merged[key] = base[key]
    end
    if fields[key] ~= nil then
      merged[key] = fields[key]
    end
  end
  merged.minLevel = cleanLevel(merged.minLevel)
  return merged
end

-- Is this client running a Groups flow: an own post, or an application that has not ended? The layer swap reads it to
-- stay out of the way (docs/LFG_PLAN.md 2.4).
function LfgService:IsBusy()
  return self.post ~= nil or (self.application ~= nil and ACTIVE[self.application.state] == true)
end

-- Can this client post a group now? Returns true, or false plus "locked" | "busy" | a reason of the eligibility. The
-- tab asks it to enable its button; Post asks it again.
function LfgService:CanPost()
  if locked(self) then
    return false, "locked"
  end
  local ok, reason = eligible(self.deps.eligibility.post)
  if not ok then
    return false, reason
  end
  if self.application and ACTIVE[self.application.state] then
    return false, "busy"
  end
  return true
end

-- Leader: posts a group. fields = { kind, title, needs = { tank, heal, dps }, minLevel (optional), note (optional) };
-- the members are the party the leader is in now. A new post replaces the old one. Returns true, or false plus a
-- reason: "locked" | "busy" | a reason of the eligibility | the reason of LfgModel.NewPost ("full", "no_needs"...) |
-- the reason the send was refused.
function LfgService:Post(fields)
  local ok, reason = self:CanPost()
  if not ok then
    return false, reason
  end
  local merged = merge(nil, type(fields) == "table" and fields or {})
  merged.members = members(self)
  merged.party = partyOf(self, merged.members, nil)
  local clean, why = ns.LfgModel.NewPost(merged)
  if not clean then
    return false, why
  end

  local now = self.deps.now()
  local post =
    { pid = self.deps.newId(), rev = 1, fields = clean, createdAt = now, applicants = {}, roles = {}, grouped = false }
  post.grouped = clean.members > 1
  local sent, why2 = publish(self, post, true)
  if not sent then
    return false, why2 or "error"
  end
  self.post = post
  self.closed = nil
  -- Notify the local client only after its group was published successfully.
  -- This does not run for edits, republications or failed posts.
  if self.deps.onOwnPost then
    pcall(self.deps.onOwnPost, post)
  end
  after(self, ns.Constants.LFG_POST_MAX_AGE, function()
    if self.post == post then
      closePost(self, "expired", false)
    end
  end)
  changed(self)
  return true
end

-- Leader: changes the own post (same fields as Post, only the ones given). Returns true, or false plus a reason.
function LfgService:Update(fields)
  local post = self.post
  if not post then
    return false, "no_post"
  end
  if locked(self) then
    return false, "locked"
  end
  local merged = merge(post.fields, type(fields) == "table" and fields or {})
  merged.members = members(self)
  merged.party = partyOf(self, merged.members, post.roles)
  local clean, why = ns.LfgModel.NewPost(merged)
  if not clean then
    return false, why
  end
  local previous, previousRev = post.fields, post.rev
  post.fields, post.rev = clean, post.rev + 1
  local sent, why2 = publish(self, post, true)
  if not sent then
    post.fields, post.rev = previous, previousRev
    return false, why2 or "error"
  end
  changed(self)
  return true
end

-- Leader: closes the own post (outcome `cancelled`).
function LfgService:Close()
  if not self.post then
    return false, "no_post"
  end
  return closePost(self, "cancelled", true)
end

-- Leader: repeats the open post with the same `rev` (the transport gives it a fresh message id). A post past
-- LFG_POST_MAX_AGE closes instead.
function LfgService:Republish()
  local post = self.post
  if not post then
    return false, "no_post"
  end
  if self.deps.now() - post.createdAt >= ns.Constants.LFG_POST_MAX_AGE then
    return closePost(self, "expired", false)
  end
  local sent, why = publish(self, post)
  return sent, why
end

---------------------------------------------------------------------------------------------------------------------
-- Leader: applicants
---------------------------------------------------------------------------------------------------------------------

local function findRow(post, name)
  return type(name) == "string" and post.applicants[ns.Validate.NameKey(name)] or nil
end

local function countRows(post)
  local count = 0
  for _ in pairs(post.applicants) do
    count = count + 1
  end
  return count
end

-- Can the leader invite now? Returns true, or false plus "locked" | a reason of the eligibility | "full". The tab asks
-- it to enable its buttons; Invite asks it again.
function LfgService:CanInvite()
  if locked(self) then
    return false, "locked"
  end
  local ok, reason = eligible(self.deps.eligibility.invite)
  if not ok then
    return false, reason
  end
  local size = groupSize(self)
  if size and size >= ns.Constants.LFG_PARTY_SIZE then
    return false, "full"
  end
  return true
end

-- Is the encounter lockdown on? Nothing is sent while it is.
function LfgService:IsLocked()
  return locked(self)
end

-- Leader: invites an applicant through the game (a button, never automatic). Asks the game first: a refused invite
-- leaves the row as it was and tells the applicant nothing. Only after the game accepted does the row become
-- "invited" and `accept` go out; if that send fails the invite still stands, and the applicant, who saw the game
-- prompt, waits out their own timeout.
function LfgService:Invite(applicant)
  local post = self.post
  if not post then
    return false, "no_post"
  end
  local row = findRow(post, applicant)
  if not row then
    return false, "unknown_applicant"
  end
  local allowed, why = self:CanInvite()
  if not allowed then
    return false, why
  end
  local ok, reason = eligible(self.deps.invite, row.name)
  if not ok then
    return false, reason or "error"
  end
  transmit(self, "apply", ns.LfgModel.AcceptPayload(post.pid, row.name))
  self.tokens = self.tokens + 1
  local token = self.tokens
  row.state, row.token = "invited", token
  row.deadline = self.deps.now() + ns.Constants.LFG_INVITE_TIMEOUT
  after(self, ns.Constants.LFG_INVITE_TIMEOUT, function()
    if self.post == post and post.applicants[ns.Validate.NameKey(row.name)] == row and row.token == token then
      if row.state == "invited" then
        row.state, row.deadline = "retry", nil
        changed(self)
      end
    end
  end)
  changed(self)
  return true
end

-- Leader: turns an applicant down and tells them.
function LfgService:Decline(applicant)
  local post = self.post
  if not post then
    return false, "no_post"
  end
  local row = findRow(post, applicant)
  if not row then
    return false, "unknown_applicant"
  end
  local sent, why = transmit(self, "apply", ns.LfgModel.DeclinePayload(post.pid, row.name))
  if not sent then
    return false, why or "error"
  end
  post.applicants[ns.Validate.NameKey(row.name)] = nil
  changed(self)
  return true
end

local function onApplicantStep(self, sender, payload)
  local post = self.post
  if not (post and post.pid == payload.pid) then
    return false, "unknown_post"
  end
  if sameName(sender, ownName(self)) then
    return false, "self"
  end
  local key = ns.Validate.NameKey(sender)
  local row = post.applicants[key]
  if payload.s == "withdraw" then
    if not row then
      return false, "unknown_applicant"
    end
    post.applicants[key] = nil
    changed(self)
    return true
  end
  -- An `apply`.
  if (post.fields.needs[payload.role] or 0) <= 0 then
    return false, "role"
  end
  local now = self.deps.now()
  if row then
    row.role, row.note, row.at = payload.role, payload.note, now
    if row.state ~= "invited" then
      row.state, row.deadline = "pending", nil
    end
  else
    if countRows(post) >= ns.Constants.LFG_APPLICANTS_MAX then
      return false, "limit"
    end
    post.applicants[key] = { name = sender, role = payload.role, note = payload.note, state = "pending", at = now }
  end
  changed(self)
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Applicant: the own application
---------------------------------------------------------------------------------------------------------------------

local function endApplication(self, app, state, reason)
  app.state, app.reason, app.deadline = state, reason, nil
  changed(self)
end

local function armTimeout(self, app, state, seconds)
  app.deadline = self.deps.now() + seconds
  after(self, seconds, function()
    if self.application == app and app.state == state then
      endApplication(self, app, "expired", "timeout")
    end
  end)
end

-- What Apply checks before it sends: returns the board entry and the wire role, or nil plus the reason. Without a
-- `role` the role is not checked, which is how the board asks whether a post can be applied to at all.
local function applyCheck(self, pid, role)
  local constants = ns.Constants
  if locked(self) then
    return nil, "locked"
  end
  local ok, reason = eligible(self.deps.eligibility.apply)
  if not ok then
    return nil, reason
  end
  if self.post then
    return nil, "own_post"
  end
  local entry = type(pid) == "string" and self.deps.board:ByPid(pid) or nil
  if not (entry and entry.state == "open") then
    return nil, "no_post"
  end
  if sameName(entry.owner, ownName(self)) then
    return nil, "own_post"
  end
  local wire
  if role ~= nil then
    wire = type(role) == "string" and (constants.LFG_ROLES[role] and role or ns.LfgModel.WireRole(role)) or nil
    if not (wire and (entry.needs[wire] or 0) > 0) then
      return nil, "role"
    end
  end
  local okLevel, level = pcall(self.deps.ownLevel)
  if okLevel and type(level) == "number" and entry.minLevel and level < entry.minLevel then
    return nil, "level"
  end
  if self.application and ACTIVE[self.application.state] then
    return nil, "busy"
  end
  return entry, wire
end

-- Can this client apply to the post `pid` now (with `role`, optional)? Returns true, or false plus the reason Apply
-- would give.
function LfgService:CanApply(pid, role)
  local entry, reason = applyCheck(self, pid, role)
  return entry ~= nil, reason
end

-- Applicant: applies to the post `pid` of the board with a role (`tank`, `heal`, `dps`, or a declared role) and an
-- optional note. Returns true, or false plus "locked" | a reason of the eligibility | "own_post" | "no_post" | "role" |
-- "level" | "busy" | "bad_note" | the reason the send was refused.
function LfgService:Apply(pid, role, note)
  local constants = ns.Constants
  local entry, wire = applyCheck(self, pid, role or false)
  if not entry then
    return false, wire
  end
  if note ~= nil and note ~= "" then
    note = note:match("^%s*(.-)%s*$")
  end
  if note == "" then
    note = nil
  end
  if note ~= nil and not ns.Validate.Text(note, constants.LFG_NOTE_MAX) then
    return false, "bad_note"
  end

  local sent, why = transmit(self, "apply", ns.LfgModel.ApplyPayload(entry.pid, wire, note))
  if not sent then
    return false, why or "error"
  end
  local app =
    { pid = entry.pid, leader = entry.owner, title = entry.title, role = wire, note = note, state = "applied" }
  self.application = app
  armTimeout(self, app, "applied", constants.LFG_APPLY_TIMEOUT)
  changed(self)
  return true
end

-- Both sides: clears what stays on screen after it ended: a finished application (joined, declined, withdrawn or
-- expired) and the note of an own post that closed by itself. Never touches an active application or an open post.
function LfgService:Dismiss()
  local app = self.application
  if app and not ACTIVE[app.state] then
    self.application = nil
  end
  self.closed = nil
  changed(self)
  return true
end

-- Applicant: takes the application back. Returns true, or false plus a reason.
function LfgService:Withdraw()
  local app = self.application
  if not (app and ACTIVE[app.state]) then
    return false, "no_application"
  end
  local sent, why = transmit(self, "apply", ns.LfgModel.WithdrawPayload(app.pid))
  if not sent then
    return false, why or "error"
  end
  endApplication(self, app, "withdrawn")
  return true
end

local function onLeaderAnswer(self, sender, payload)
  local app = self.application
  if not (app and app.pid == payload.pid and ACTIVE[app.state]) then
    return false, "unknown_application"
  end
  -- The answer counts only from the owner of that post on the local board, whatever it says about itself.
  local entry = self.deps.board:Get(sender)
  if not (entry and entry.pid == payload.pid and sameName(sender, app.leader)) then
    return false, "forbidden"
  end
  if not sameName(payload.to, ownName(self)) then
    return false, "not_for_me"
  end
  if payload.s == "decline" then
    endApplication(self, app, "declined")
    return true
  end
  if app.state == "applied" then
    app.state = "invited"
    armTimeout(self, app, "invited", ns.Constants.LFG_INVITE_TIMEOUT)
    changed(self)
  end
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Messages from the guild
---------------------------------------------------------------------------------------------------------------------

-- A LFG_POST message, already validated by Protocol and authorized by LfgSync. `sender` is the member who sent it, as
-- the client delivered it; the payload never says who anyone is. Returns true, or false plus the reason.
function LfgService:OnPost(sender, payload)
  if sameName(sender, ownName(self)) then
    return false, "self"
  end
  local before = self.deps.board:Get(sender)
  local ok, reason = self.deps.board:Apply(sender, payload)
  if not ok then
    return false, reason
  end
  -- A group the board did not know is announced, but not during the warm-up after login: the posts that were already
  -- open arrive as new then, with their repeats.
  local isNew = payload.s == "open" and not (before and before.pid == payload.pid)
  if isNew and self.deps.onNewPost and self.deps.now() - self.startedAt >= ns.Constants.LFG_ALERT_WARMUP then
    local post = self.deps.board:Get(sender)
    if post then
      pcall(self.deps.onNewPost, sender, post)
    end
  end
  local app = self.application
  if app and ACTIVE[app.state] and sameName(sender, app.leader) then
    -- The post of the leader closed or was replaced. A leader who closes it as `full` after our join can arrive before
    -- the roster update does, so the group is asked first.
    if isMemberOfGroup(self, app.leader) then
      app.state, app.deadline = "joined", nil
      changed(self)
    elseif payload.pid ~= app.pid or payload.s == "closed" then
      endApplication(self, app, "expired", "post_closed")
    end
  end
  changed(self)
  return true
end

-- A LFG_APPLY message, already validated and authorized. Returns true, or false plus the reason.
function LfgService:OnApply(sender, payload)
  if type(sender) ~= "string" or sender == "" then
    return false, "bad_sender"
  end
  if payload.s == "apply" or payload.s == "withdraw" then
    return onApplicantStep(self, sender, payload)
  end
  if payload.s == "accept" or payload.s == "decline" then
    return onLeaderAnswer(self, sender, payload)
  end
  return false, "unsupported"
end

---------------------------------------------------------------------------------------------------------------------
-- The game group changed
---------------------------------------------------------------------------------------------------------------------

local function leaderState(self)
  local ok, leader = pcall(self.deps.isLeader)
  if ok and type(leader) == "boolean" then
    return leader
  end
  return nil
end

local function syncPost(self)
  local post = self.post
  local constants = ns.Constants
  local size = groupSize(self)
  if not size then
    return
  end
  local okRaid, raid = pcall(self.deps.isRaid)
  if (okRaid and raid == true) or size > constants.LFG_PARTY_SIZE then
    closePost(self, "cancelled", false)
    return
  end
  if size > 1 and leaderState(self) == false then
    closePost(self, "cancelled", false)
    return
  end
  if size > 1 then
    post.grouped = true
  elseif post.grouped then
    closePost(self, "cancelled", false)
    return
  end

  local needs = copyNeeds(post.fields.needs)
  for key, row in pairs(post.applicants) do
    if isMemberOfGroup(self, row.name) then
      needs[row.role] = math.max(0, needs[row.role] - 1)
      post.roles[roleKey(row.name)] = row.role
      post.applicants[key] = nil
    end
  end
  local count = math.max(1, size)
  needs = ns.LfgModel.FitNeeds(needs, constants.LFG_PARTY_SIZE - count)

  local party = partyOf(self, count, post.roles)
  local fields = post.fields
  local same = count == fields.members
    and needs.tank == fields.needs.tank
    and needs.heal == fields.needs.heal
    and needs.dps == fields.needs.dps
    and ns.LfgModel.SameParty(party, fields.party)
  if same then
    return
  end
  local updated = {
    kind = fields.kind,
    title = fields.title,
    needs = needs,
    members = count,
    minLevel = fields.minLevel,
    note = fields.note,
    party = party,
  }
  post.fields, post.rev = updated, post.rev + 1
  if ns.LfgModel.IsFull(updated) then
    closePost(self, "full", false)
    return
  end
  -- Best effort: a lockdown leaves the new `rev` to the next Republish.
  publish(self, post)
  changed(self)
end

local function syncApplication(self)
  local app = self.application
  if app and ACTIVE[app.state] and isMemberOfGroup(self, app.leader) then
    app.state, app.deadline = "joined", nil
    changed(self)
  end
end

-- Both sides: the player's group changed (GROUP_ROSTER_UPDATE, PLAYER_ENTERING_WORLD). An applicant who is now in
-- the leader's group has joined; the leader's post follows the party: a joined applicant is one seat less, and a
-- party that is gone, no longer led by the poster or now a raid closes the post.
function LfgService:OnGroupChanged()
  if self.post then
    syncPost(self)
  end
  syncApplication(self)
end

-- Both sides: drops what nobody repeated for too long, ends the application whose post is gone and drops the pending
-- applicants nobody refreshed within LFG_APPLY_TIMEOUT (their own timeout ran out, or they logged out). Invited and
-- retry rows stay: the leader is still acting on them. Calls onChange when something was dropped (the sidebar counts
-- the board). Meant for a timer that runs while the addon is active.
function LfgService:Sweep()
  local dropped = self.deps.board:Prune() > 0
  local post = self.post
  if post then
    local cutoff = self.deps.now() - ns.Constants.LFG_APPLY_TIMEOUT
    for key, row in pairs(post.applicants) do
      if row.state == "pending" and row.at < cutoff then
        post.applicants[key] = nil
        dropped = true
      end
    end
  end
  if dropped then
    changed(self)
  end
  local app = self.application
  if app and ACTIVE[app.state] then
    local entry = self.deps.board:Get(app.leader)
    if not (entry and entry.pid == app.pid and entry.state == "open") and not isMemberOfGroup(self, app.leader) then
      endApplication(self, app, "expired", "post_closed")
    end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- What the tab and the popup show
---------------------------------------------------------------------------------------------------------------------

local function left(self, deadline)
  return deadline and math.max(0, deadline - self.deps.now()) or nil
end

-- { post, application, closed }. `closed` is { title, outcome } of an own post that closed by itself, until Dismiss or
-- a new post. `post` is the own post, or nil: { pid, rev, kind, title, needs, members, minLevel, note, party,
-- remaining, age, left (seconds to LFG_POST_MAX_AGE), applicants = { { name, role, note, state (pending | invited |
-- retry), left, at } oldest first } }. `application` is the own application, or nil: { pid, leader, title, role,
-- note, state (applied | invited | joined | declined | withdrawn | expired), reason, left }. A finished
-- application stays until a new one replaces it.
function LfgService:Status()
  local status = {}
  local post = self.post
  if post then
    local rows = {}
    for _, row in pairs(post.applicants) do
      rows[#rows + 1] = {
        name = row.name,
        role = row.role,
        note = row.note,
        state = row.state,
        left = left(self, row.deadline),
        at = row.at,
      }
    end
    table.sort(rows, function(a, b)
      if a.at ~= b.at then
        return a.at < b.at
      end
      return ns.Validate.NameKey(a.name) < ns.Validate.NameKey(b.name)
    end)
    local fields = post.fields
    local now = self.deps.now()
    status.post = {
      pid = post.pid,
      rev = post.rev,
      kind = fields.kind,
      title = fields.title,
      needs = copyNeeds(fields.needs),
      members = fields.members,
      minLevel = fields.minLevel,
      note = fields.note,
      party = ns.LfgModel.CopyParty(fields.party),
      remaining = ns.LfgModel.RemainingNeeds(fields),
      age = math.max(0, now - post.createdAt),
      left = math.max(0, ns.Constants.LFG_POST_MAX_AGE - (now - post.createdAt)),
      applicants = rows,
    }
  end
  if self.closed then
    status.closed = { title = self.closed.title, outcome = self.closed.outcome }
  end
  local app = self.application
  if app then
    status.application = {
      pid = app.pid,
      leader = app.leader,
      title = app.title,
      role = app.role,
      note = app.note,
      state = app.state,
      reason = app.reason,
      left = left(self, app.deadline),
    }
  end
  return status
end

-- The eligibility rules (plan section 2.3) over a platform-like object.
--   platform: IsInGroup, IsInRaid, IsInCombat, IsGroupLeader, GetGroupSize
--   isLocked: function() -> boolean     swapActive: function() -> boolean (a layer swap is running)
-- Each rule returns true, or false plus a reason. The rules that depend on the post or the application (an own post,
-- the level, the role, another application, the needs) are checked by the service.
function LfgService.Eligibility(platform, isLocked, swapActive)
  local function notLeader()
    return platform.IsInGroup() and not platform.IsGroupLeader()
  end
  return {
    post = function()
      if isLocked() then
        return false, "locked"
      end
      if swapActive() then
        return false, "swap"
      end
      if platform.IsInRaid() then
        return false, "raid"
      end
      if notLeader() then
        return false, "not_leader"
      end
      if platform.GetGroupSize() >= ns.Constants.LFG_PARTY_SIZE then
        return false, "full"
      end
      return true
    end,
    apply = function()
      if isLocked() then
        return false, "locked"
      end
      if platform.IsInGroup() then
        return false, "in_group"
      end
      if swapActive() then
        return false, "swap"
      end
      return true
    end,
    invite = function()
      if isLocked() then
        return false, "locked"
      end
      if notLeader() then
        return false, "not_leader"
      end
      if platform.GetGroupSize() >= ns.Constants.LFG_PARTY_SIZE then
        return false, "full"
      end
      if platform.IsInCombat() then
        return false, "combat"
      end
      return true
    end,
  }
end

ns.LfgService = LfgService
