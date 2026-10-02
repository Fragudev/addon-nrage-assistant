local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/EventModel",
    "Sync/Protocol",
    "Domain/PublishService",
  }) do
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

local function character()
  return { profile = profile(), publish = {} }
end

local platform = {
  ServerTime = function()
    return 1000000
  end,
}

describe("PublishService.BuildPayload", function()
  it("shares class, level, item level, professions and role/main", function()
    local payload = Service.BuildPayload(profile(), 1)
    assert.are.equal("WARRIOR", payload.class)
    assert.are.equal(60, payload.level)
    assert.are.equal(200, payload.ilvl)
    assert.are.equal(2, #payload.professions)
    assert.are.same({ role = "tank", main = "Other" }, payload.fields)
  end)

  it("never shares the notes", function()
    local payload = Service.BuildPayload(profile(), 1)
    assert.is_nil(payload.fields.notes)
    local data = profile()
    data.fields = { notes = { value = "private", source = "declared" } }
    assert.is_nil(Service.BuildPayload(data, 1).fields)
  end)

  it("does not guess unknown data", function()
    local data = profile()
    data.class, data.level = nil, nil
    local payload, reason = Service.BuildPayload(data, 1)
    assert.is_nil(payload)
    assert.are.equal("missing_data", reason)

    data = profile()
    data.ilvl, data.professions, data.fields = nil, nil, nil
    payload = Service.BuildPayload(data, 1)
    assert.is_nil(payload.ilvl)
    assert.is_nil(payload.professions)
    assert.is_nil(payload.fields)
  end)

  it("strips escape sequences and control characters from declared text", function()
    local data = profile()
    data.fields.role = { value = "  |cffff0000ta\nnk|r ", source = "declared" }
    data.fields.main = { value = "|||", source = "declared" }
    local payload = Service.BuildPayload(data, 1)
    assert.are.equal("cffff0000tankr", payload.fields.role)
    assert.is_nil(payload.fields.main)
  end)

  it("produces a payload the protocol accepts", function()
    local payload = Service.BuildPayload(profile(), 7)
    local message = ns.Protocol.Build("PROFILE", payload, "id-1")
    assert.is_truthy(ns.Protocol.Validate(message))
  end)
end)

describe("PublishService.Describe", function()
  it("lists what is shared and says what stays on this computer", function()
    local text = table.concat(Service.Describe(profile()), "\n")
    assert.is_truthy(text:find("Shared with the guild: WARRIOR, level 60", 1, true))
    assert.is_truthy(text:find("Shared with the guild: item level 200", 1, true))
    assert.is_truthy(text:find("Shared with the guild: Mining 300", 1, true))
    assert.is_truthy(text:find("Shared with the guild: role = tank", 1, true))
    assert.is_truthy(text:find("Not shared: notes, enchants and buffs", 1, true))
    assert.is_nil(text:find("raids on weekends", 1, true))
  end)

  it("says nothing can be shared while class or level is unknown", function()
    local data = profile()
    data.level = nil
    local lines = Service.Describe(data)
    assert.are.equal(1, #lines)
    assert.is_truthy(lines[1]:find("class or level is unknown", 1, true))
  end)
end)

describe("PublishService.Publish", function()
  it("sends a keyed PROFILE and records revision and time", function()
    local comm, char = fake_comm(), character()
    assert.is_true(Service.Publish(comm, char, platform))
    assert.are.equal("PROFILE", comm.sent[1].type)
    assert.are.equal("PROFILE", comm.sent[1].key)
    assert.are.equal(1000000, comm.sent[1].payload.rev)
    assert.are.equal(1000000, char.publish.at)
  end)

  it("sends nothing while class or level is unknown", function()
    local comm, char = fake_comm(), character()
    char.profile.level = nil
    local ok, reason = Service.Publish(comm, char, platform)
    assert.is_false(ok)
    assert.are.equal("missing_data", reason)
    assert.are.equal(0, #comm.sent)
  end)

  it("keeps the revision above the previous one even if the clock is behind", function()
    local comm, char = fake_comm(), character()
    char.publish = { rev = 5000000, at = 0 }
    Service.Publish(comm, char, platform)
    assert.are.equal(5000001, comm.sent[1].payload.rev)
  end)

  it("enforces a cooldown between publications", function()
    local comm, char = fake_comm(), character()
    assert.is_true(Service.Publish(comm, char, platform))
    local ok, reason = Service.Publish(comm, char, platform)
    assert.is_false(ok)
    assert.are.equal("cooldown", reason)
    assert.are.equal(1, #comm.sent)
  end)

  it("does not consume a revision when the send fails", function()
    local comm, char = fake_comm(), character()
    function comm.Send()
      return false, "full"
    end
    local ok, reason = Service.Publish(comm, char, platform)
    assert.is_false(ok)
    assert.are.equal("full", reason)
    assert.is_nil(char.publish.rev)
    assert.is_nil(char.publish.at)
    assert.is_nil(char.publish.fingerprint)
  end)
end)

describe("PublishService.PublishIfChanged", function()
  local later = {
    ServerTime = function()
      return 1000000 + 100
    end,
  }

  it("publishes the first time and then stays quiet while nothing changes", function()
    local comm, char = fake_comm(), character()
    assert.is_true(Service.PublishIfChanged(comm, char, platform))
    local ok, reason = Service.PublishIfChanged(comm, char, later)
    assert.is_false(ok)
    assert.are.equal("unchanged", reason)
    assert.are.equal(1, #comm.sent)
  end)

  it("publishes again when something shared changes", function()
    local comm, char = fake_comm(), character()
    Service.PublishIfChanged(comm, char, platform)
    char.profile.level = 61
    assert.is_true(Service.PublishIfChanged(comm, char, later))
    assert.are.equal(2, #comm.sent)
    assert.are.equal(61, comm.sent[2].payload.level)
  end)

  it("does not publish because of notes, which are never shared", function()
    local comm, char = fake_comm(), character()
    Service.PublishIfChanged(comm, char, platform)
    char.profile.fields.notes = { value = "something else", source = "declared" }
    local ok, reason = Service.PublishIfChanged(comm, char, later)
    assert.is_false(ok)
    assert.are.equal("unchanged", reason)
  end)

  it("keeps a change that came inside the cooldown for the next call", function()
    local comm, char = fake_comm(), character()
    Service.PublishIfChanged(comm, char, platform)
    char.profile.ilvl = 210
    local ok, reason = Service.PublishIfChanged(comm, char, platform)
    assert.is_false(ok)
    assert.are.equal("cooldown", reason)
    assert.is_true(Service.PublishIfChanged(comm, char, later))
    assert.are.equal(210, comm.sent[2].payload.ilvl)
  end)

  it("tells when there is nothing to share yet", function()
    local comm, char = fake_comm(), character()
    char.profile.class = nil
    local ok, reason = Service.PublishIfChanged(comm, char, platform)
    assert.is_false(ok)
    assert.are.equal("missing_data", reason)
  end)
end)
