local function load_modules()
  local ns = {}
  for _, path in ipairs({ "Core/Constants", "Core/Validate", "Sync/Protocol", "Domain/PublishService" }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Service = ns.PublishService

local function profile()
  return {
    class = "WARRIOR",
    level = 60,
    ilvl = 200,
    professions = { { name = "Mining", skill = 300, max = 300 }, { name = "Herbalism", skill = 100 } },
    fields = {
      role = { value = "tank", source = "declared" },
      main = { value = "Other", source = "declared" },
      notes = { value = "raids on weekends", source = "declared" },
    },
  }
end

local function fake_comm()
  local comm = { sent = {} }
  function comm:Send(messageType, payload, key)
    self.sent[#self.sent + 1] = { type = messageType, payload = payload, key = key }
    return true
  end
  return comm
end

local function character(consent)
  return { profile = profile(), consent = consent or {}, publish = {} }
end

local platform = { ServerTime = function() return 1000000 end }

describe("PublishService.SetConsent", function()
  it("turns a consent key on and off", function()
    local consent = {}
    assert.is_true(Service.SetConsent(consent, "gear", true))
    assert.is_true(consent.gear)
    assert.is_true(Service.SetConsent(consent, "gear", false))
    assert.is_nil(consent.gear)
  end)

  it("rejects unknown keys", function()
    local ok, reason = Service.SetConsent({}, "attendance", true)
    assert.is_false(ok)
    assert.are.equal("unknown_key", reason)
  end)
end)

describe("PublishService.BuildPayload", function()
  it("shares nothing without profile consent, whatever else is on", function()
    local payload, reason = Service.BuildPayload(profile(), { gear = true, professions = true, notes = true }, 1)
    assert.is_nil(payload)
    assert.are.equal("no_consent", reason)
  end)

  it("shares only class, level and role/main with profile consent alone", function()
    local payload = Service.BuildPayload(profile(), { profile = true }, 1)
    assert.are.equal("WARRIOR", payload.class)
    assert.are.equal(60, payload.level)
    assert.is_nil(payload.ilvl)
    assert.is_nil(payload.professions)
    assert.are.same({ role = "tank", main = "Other" }, payload.fields)
  end)

  it("adds each kind of data only with its own consent", function()
    local consent = { profile = true, gear = true, professions = true, notes = true }
    local payload = Service.BuildPayload(profile(), consent, 1)
    assert.are.equal(200, payload.ilvl)
    assert.are.equal(2, #payload.professions)
    assert.are.equal("raids on weekends", payload.fields.notes)
  end)

  it("keeps notes private without notes consent", function()
    local payload = Service.BuildPayload(profile(), { profile = true }, 1)
    assert.is_nil(payload.fields.notes)
  end)

  it("does not guess unknown data", function()
    local data = profile()
    data.class, data.level = nil, nil
    local payload, reason = Service.BuildPayload(data, { profile = true }, 1)
    assert.is_nil(payload)
    assert.are.equal("missing_data", reason)

    data = profile()
    data.ilvl, data.professions, data.fields = nil, nil, nil
    payload = Service.BuildPayload(data, { profile = true, gear = true, professions = true, notes = true }, 1)
    assert.is_nil(payload.ilvl)
    assert.is_nil(payload.professions)
    assert.is_nil(payload.fields)
  end)

  it("strips escape sequences and control characters from declared text", function()
    local data = profile()
    data.fields.role = { value = "  |cffff0000ta\nnk|r ", source = "declared" }
    data.fields.main = { value = "|||", source = "declared" }
    local payload = Service.BuildPayload(data, { profile = true }, 1)
    assert.are.equal("cffff0000tankr", payload.fields.role)
    assert.is_nil(payload.fields.main)
  end)

  it("produces a payload the protocol accepts", function()
    local consent = { profile = true, gear = true, professions = true, notes = true }
    local payload = Service.BuildPayload(profile(), consent, 7)
    local message = ns.Protocol.Build("PROFILE", payload, "id-1")
    assert.is_truthy(ns.Protocol.Validate(message))
  end)
end)

describe("PublishService.Describe", function()
  it("previews what is shared and what is not", function()
    local text = table.concat(Service.Describe(profile(), { profile = true, gear = true }), "\n")
    assert.is_truthy(text:find("Will share: WARRIOR, level 60", 1, true))
    assert.is_truthy(text:find("Will share: item level 200", 1, true))
    assert.is_truthy(text:find("Not shared: professions (no consent)", 1, true))
    assert.is_truthy(text:find("Not shared: notes (no consent)", 1, true))
    assert.is_nil(text:find("Mining", 1, true))
  end)

  it("says nothing is shared without profile consent", function()
    local lines = Service.Describe(profile(), {})
    assert.are.equal(1, #lines)
    assert.is_truthy(lines[1]:find("profile consent is off", 1, true))
  end)
end)

describe("PublishService.Publish", function()
  it("sends nothing without consent", function()
    local comm = fake_comm()
    local ok, reason = Service.Publish(comm, character({}), platform)
    assert.is_false(ok)
    assert.are.equal("no_consent", reason)
    assert.are.equal(0, #comm.sent)
  end)

  it("sends a keyed PROFILE and records revision and time", function()
    local comm, char = fake_comm(), character({ profile = true })
    assert.is_true(Service.Publish(comm, char, platform))
    assert.are.equal("PROFILE", comm.sent[1].type)
    assert.are.equal("PROFILE", comm.sent[1].key)
    assert.are.equal(1000000, comm.sent[1].payload.rev)
    assert.are.equal(1000000, char.publish.at)
  end)

  it("keeps the revision above the previous one even if the clock is behind", function()
    local comm, char = fake_comm(), character({ profile = true })
    char.publish = { rev = 5000000, at = 0 }
    Service.Publish(comm, char, platform)
    assert.are.equal(5000001, comm.sent[1].payload.rev)
  end)

  it("enforces a cooldown between publications", function()
    local comm, char = fake_comm(), character({ profile = true })
    assert.is_true(Service.Publish(comm, char, platform))
    local ok, reason = Service.Publish(comm, char, platform)
    assert.is_false(ok)
    assert.are.equal("cooldown", reason)
    assert.are.equal(1, #comm.sent)
  end)

  it("does not consume a revision when the send fails", function()
    local comm, char = fake_comm(), character({ profile = true })
    function comm.Send() return false, "full" end
    local ok, reason = Service.Publish(comm, char, platform)
    assert.is_false(ok)
    assert.are.equal("full", reason)
    assert.is_nil(char.publish.rev)
    assert.is_nil(char.publish.at)
  end)
end)
