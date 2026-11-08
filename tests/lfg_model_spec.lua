local function load_model()
  local ns = {}
  local files = { "Core/Constants", "Core/Validate", "Core/Locale", "Domain/ProfileService", "Domain/LfgModel" }
  for _, path in ipairs(files) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_model()
local Model = ns.LfgModel

local function fields(overrides)
  local f = { kind = "dungeon", title = "Deadmines", needs = { tank = 1, heal = 1, dps = 2 }, members = 1 }
  for k, v in pairs(overrides or {}) do
    f[k] = v
  end
  return f
end

describe("LfgModel.WireRole", function()
  it("converts the profile roles to the wire roles", function()
    assert.are.equal("tank", Model.WireRole("Tank"))
    assert.are.equal("heal", Model.WireRole("Heal"))
    assert.are.equal("dps", Model.WireRole("Dps"))
    assert.are.equal("heal", Model.WireRole(" healer "))
    assert.are.equal("dps", Model.WireRole("DPS"))
  end)

  it("returns nil for anything that is not a role", function()
    assert.is_nil(Model.WireRole("bard"))
    assert.is_nil(Model.WireRole(nil))
    assert.is_nil(Model.WireRole(3))
  end)
end)

describe("LfgModel.NewPost", function()
  it("builds a clean post and trims the text", function()
    local post = assert(Model.NewPost(fields({ title = "  Deadmines  ", note = " bring water ", minLevel = 18 })))
    assert.are.same({
      kind = "dungeon",
      title = "Deadmines",
      needs = { tank = 1, heal = 1, dps = 2 },
      members = 1,
      minLevel = 18,
      note = "bring water",
    }, post)
  end)

  it("treats a missing role as zero and an empty note as none", function()
    local post = assert(Model.NewPost(fields({ needs = { dps = 3 }, note = "   " })))
    assert.are.same({ tank = 0, heal = 0, dps = 3 }, post.needs)
    assert.is_nil(post.note)
  end)

  it("does not keep fields it does not know", function()
    local post = assert(Model.NewPost(fields({ extra = 1 })))
    assert.is_nil(post.extra)
  end)

  it("refuses an unknown kind and a bad title", function()
    assert.are.equal("bad_kind", select(2, Model.NewPost(fields({ kind = "raid" }))))
    assert.are.equal("bad_kind", select(2, Model.NewPost("x")))
    for _, title in ipairs({ "", "   ", string.rep("a", 61), "a|b", "a\nb", 4 }) do
      assert.are.equal("bad_title", select(2, Model.NewPost(fields({ title = title }))))
    end
  end)

  it("limits the needs to four each and to the room left in the party", function()
    assert.are.equal("bad_needs", select(2, Model.NewPost(fields({ needs = { tank = 5 } }))))
    assert.are.equal("bad_needs", select(2, Model.NewPost(fields({ needs = { tank = -1, heal = 1 } }))))
    assert.are.equal("bad_needs", select(2, Model.NewPost(fields({ needs = "x" }))))
    -- Five seats in all: needs plus members never exceed them.
    assert.are.equal(
      "bad_needs",
      select(2, Model.NewPost(fields({ needs = { tank = 1, heal = 1, dps = 2 }, members = 2 })))
    )
    assert.is_truthy(Model.NewPost(fields({ needs = { tank = 1, heal = 1, dps = 1 }, members = 2 })))
    assert.is_truthy(Model.NewPost(fields({ needs = { dps = 4 } })))
  end)

  it("needs at least one seat to fill", function()
    assert.are.equal("no_needs", select(2, Model.NewPost(fields({ needs = { tank = 0, heal = 0, dps = 0 } }))))
  end)

  it("refuses a full party and a bad member count", function()
    assert.are.equal("full", select(2, Model.NewPost(fields({ members = 5 }))))
    for _, members in ipairs({ 0, 6, 1.5, "1", false }) do
      assert.are.equal("bad_members", select(2, Model.NewPost(fields({ members = members }))))
    end
  end)

  it("validates the optional level and note", function()
    for _, level in ipairs({ 0, 101, 1.5, "20" }) do
      assert.are.equal("bad_level", select(2, Model.NewPost(fields({ minLevel = level }))))
    end
    assert.are.equal("bad_note", select(2, Model.NewPost(fields({ note = string.rep("a", 101) }))))
    assert.are.equal("bad_note", select(2, Model.NewPost(fields({ note = "a|b" }))))
  end)
end)

describe("LfgModel needs", function()
  it("counts the seats left", function()
    local post = assert(Model.NewPost(fields()))
    assert.are.equal(4, Model.RemainingNeeds(post))
  end)

  it("is full when no seat is left", function()
    local post = assert(Model.NewPost(fields()))
    assert.is_false(Model.IsFull(post))
    post.needs = { tank = 0, heal = 0, dps = 0 }
    assert.is_true(Model.IsFull(post))
  end)

  it("is full when the party has five members, whatever the needs say", function()
    local post = assert(Model.NewPost(fields()))
    post.members = 5
    assert.is_true(Model.IsFull(post))
  end)

  it("fits the needs in the room, taking from dps first and never changing its input", function()
    local needs = { tank = 1, heal = 1, dps = 2 }
    assert.are.same({ tank = 1, heal = 1, dps = 0 }, Model.FitNeeds(needs, 2))
    assert.are.same({ tank = 1, heal = 0, dps = 0 }, Model.FitNeeds(needs, 1))
    assert.are.same({ tank = 0, heal = 0, dps = 0 }, Model.FitNeeds(needs, 0))
    assert.are.same({ tank = 0, heal = 0, dps = 0 }, Model.FitNeeds(needs, -3))
    assert.are.same(needs, Model.FitNeeds(needs, 4))
    assert.are.same({ tank = 1, heal = 1, dps = 2 }, needs)
  end)
end)

describe("LfgModel payloads", function()
  it("builds an open post and a closed one", function()
    local post = assert(Model.NewPost(fields({ minLevel = 10, note = "hi" })))
    assert.are.same({
      pid = "p1",
      rev = 3,
      s = "open",
      kind = "dungeon",
      title = "Deadmines",
      needs = { tank = 1, heal = 1, dps = 2 },
      members = 1,
      minLevel = 10,
      note = "hi",
    }, Model.PostPayload("p1", 3, post))
    assert.are.same({ pid = "p1", rev = 4, s = "closed", o = "full" }, Model.ClosedPayload("p1", 4, "full"))
  end)

  it("carries the party of the post, one seat per member, as a copy", function()
    local party = { { c = "WARRIOR", r = "tank" }, { c = "PRIEST" } }
    local post = assert(Model.NewPost(fields({ members = 2, needs = { tank = 0, heal = 1, dps = 2 }, party = party })))
    local payload = Model.PostPayload("p1", 1, post)
    assert.are.same(party, payload.party)
    payload.party[1].c = "MAGE"
    assert.are.equal("WARRIOR", post.party[1].c)
  end)

  it("leaves out a party that does not fit the members, and keeps the post", function()
    local post = assert(Model.NewPost(fields({ party = { { c = "WARRIOR" }, { c = "PRIEST" } } })))
    assert.is_nil(post.party)
    assert.is_nil(Model.PostPayload("p1", 1, post).party)
    assert.is_nil(Model.CleanParty({ { c = "WARRIOR", r = "healer" } }, 1))
    assert.is_nil(Model.CleanParty({ { c = "Warrior" } }, 1))
    assert.are.same({ { c = "WARRIOR" } }, Model.CleanParty({ { c = "WARRIOR", x = 1 } }, 1))
  end)

  it("tells when two parties show the same seats", function()
    assert.is_true(Model.SameParty(nil, nil))
    assert.is_false(Model.SameParty(nil, { { c = "MAGE" } }))
    assert.is_true(Model.SameParty({ { c = "MAGE", r = "dps" } }, { { c = "MAGE", r = "dps" } }))
    assert.is_false(Model.SameParty({ { c = "MAGE", r = "dps" } }, { { c = "MAGE" } }))
    assert.is_false(Model.SameParty({ { c = "MAGE" } }, { { c = "MAGE" }, { c = "PRIEST" } }))
  end)

  it("does not share the needs table with the post", function()
    local post = assert(Model.NewPost(fields()))
    local payload = Model.PostPayload("p1", 1, post)
    payload.needs.tank = 0
    assert.are.equal(1, post.needs.tank)
  end)

  it("builds the application steps", function()
    assert.are.same({ pid = "p1", s = "apply", role = "tank", note = "n" }, Model.ApplyPayload("p1", "tank", "n"))
    assert.are.same({ pid = "p1", s = "withdraw" }, Model.WithdrawPayload("p1"))
    assert.are.same({ pid = "p1", s = "accept", to = "Ann" }, Model.AcceptPayload("p1", "Ann"))
    assert.are.same({ pid = "p1", s = "decline", to = "Ann" }, Model.DeclinePayload("p1", "Ann"))
  end)
end)
