local function load_protocol()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Sync/Protocol.lua"))("NrageAssistant", ns)
  return ns.Protocol, ns.Constants
end

local Protocol, Constants = load_protocol()

local function profile(overrides)
  local p = {
    rev = 3,
    class = "WARRIOR",
    level = 60,
    ilvl = 200,
    professions = { { name = "Mining", skill = 300, max = 300 } },
    fields = { role = "tank" },
  }
  for k, v in pairs(overrides or {}) do p[k] = v end
  return p
end

local function message(payload, overrides)
  local m = Protocol.Build("PROFILE", payload or profile(), "abc-123")
  for k, v in pairs(overrides or {}) do m[k] = v end
  return m
end

describe("Protocol.Build", function()
  it("stamps the current protocol version", function()
    local m = Protocol.Build("HELLO", { version = "0.1.0" }, "id-1")
    assert.are.equal(Constants.PROTOCOL_MAJOR, m.v)
    assert.are.equal(Constants.PROTOCOL_MINOR, m.m)
    assert.are.equal("HELLO", m.t)
  end)
end)

describe("Protocol.Validate envelope", function()
  it("accepts a well-formed HELLO", function()
    local clean = Protocol.Validate(Protocol.Build("HELLO", { version = "0.1.0" }, "id-1"))
    assert.are.equal("HELLO", clean.t)
    assert.are.equal("0.1.0", clean.p.version)
  end)

  it("rejects non-tables", function()
    for _, value in ipairs({ "text", 5, true }) do
      local clean, reason = Protocol.Validate(value)
      assert.is_nil(clean)
      assert.are.equal("not_table", reason)
    end
  end)

  it("rejects a bad version and explains an incompatible major", function()
    local _, reason = Protocol.Validate(message(nil, { v = "1" }))
    assert.are.equal("bad_version", reason)
    _, reason = Protocol.Validate(message(nil, { v = Constants.PROTOCOL_MAJOR + 1 }))
    assert.are.equal("incompatible_version", reason)
  end)

  it("accepts a newer minor version", function()
    assert.is_truthy(Protocol.Validate(message(nil, { m = Constants.PROTOCOL_MINOR + 5 })))
  end)

  it("rejects unknown types", function()
    local _, reason = Protocol.Validate(message(nil, { t = "EVENT_UPSERT" }))
    assert.are.equal("unknown_type", reason)
    _, reason = Protocol.Validate(message(nil, { t = {} }))
    assert.are.equal("unknown_type", reason)
  end)

  it("rejects bad ids", function()
    for _, id in ipairs({ "", ("x"):rep(41), "has space", "pipe|id", 7 }) do
      local _, reason = Protocol.Validate(message(nil, { id = id }))
      assert.are.equal("bad_id", reason)
    end
  end)

  it("rejects a missing payload", function()
    local _, reason = Protocol.Validate(message(nil, { p = "nope" }))
    assert.are.equal("bad_payload", reason)
  end)
end)

describe("Protocol.Validate HELLO", function()
  it("rejects a missing or hostile version string", function()
    for _, version in ipairs({ "", ("v"):rep(33), "|cffff0000red", "line\nbreak", 1 }) do
      local _, reason = Protocol.Validate(Protocol.Build("HELLO", { version = version }, "id-1"))
      assert.are.equal("bad_payload", reason)
    end
  end)
end)

describe("Protocol.Validate PROFILE", function()
  it("keeps every valid field", function()
    local clean = Protocol.Validate(message())
    assert.are.equal(3, clean.p.rev)
    assert.are.equal("WARRIOR", clean.p.class)
    assert.are.equal(60, clean.p.level)
    assert.are.equal(200, clean.p.ilvl)
    assert.are.same({ { name = "Mining", skill = 300, max = 300 } }, clean.p.professions)
    assert.are.same({ role = "tank" }, clean.p.fields)
  end)

  it("accepts a minimal profile", function()
    local clean = Protocol.Validate(message({ rev = 0, class = "MAGE", level = 1 }))
    assert.is_truthy(clean)
    assert.is_nil(clean.p.ilvl)
    assert.is_nil(clean.p.professions)
    assert.is_nil(clean.p.fields)
  end)

  it("drops unknown fields, including nested ones", function()
    local payload = profile({ guid = "Player-1", secret = "x" })
    payload.fields.evil = "y"
    payload.professions[1].extra = "z"
    local clean = Protocol.Validate(message(payload))
    assert.is_nil(clean.p.guid)
    assert.is_nil(clean.p.secret)
    assert.is_nil(clean.p.fields.evil)
    assert.is_nil(clean.p.professions[1].extra)
  end)

  it("rejects values outside their domain", function()
    local bad = {
      { rev = -1 }, { rev = 1.5 }, { rev = "3" },
      { class = "warrior" }, { class = "" }, { class = "WAR|RIOR" },
      { level = 0 }, { level = 1000 }, { level = "60" },
      { ilvl = -1 }, { ilvl = 2001 },
      { professions = "mining" },
      { professions = { { name = "", skill = 1 } } },
      { professions = { { name = "Mining", skill = 1001 } } },
      { professions = { { name = "Mining", skill = 1, max = -1 } } },
      { fields = "role" },
      { fields = { role = "|cffff0000red" } },
      { fields = { notes = ("n"):rep(Constants.MAX_FIELD_LENGTH + 1) } },
    }
    for _, overrides in ipairs(bad) do
      local clean, reason = Protocol.Validate(message(profile(overrides)))
      assert.is_nil(clean)
      assert.are.equal("bad_payload", reason)
    end
  end)

  it("rejects too many professions", function()
    local list = {}
    for i = 1, 9 do list[i] = { name = "P" .. i, skill = 1 } end
    local _, reason = Protocol.Validate(message(profile({ professions = list })))
    assert.are.equal("bad_payload", reason)
  end)
end)
