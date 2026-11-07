-- Who runs the addon and which version (Domain/InstallDirectory.lua).
local ns = {}
assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
assert(loadfile("NrageAssistant/Domain/InstallDirectory.lua"))("NrageAssistant", ns)
local InstallDirectory = ns.InstallDirectory

describe("InstallDirectory.Note", function()
  it("saves the version of a HELLO and when it was heard", function()
    local installs = {}
    assert.is_true(InstallDirectory.Note(installs, "Ann", { version = "1.2.0" }, 100))
    assert.are.same({ version = "1.2.0", seenAt = 100 }, installs.Ann)
  end)

  it("keeps the version seen before when a message only says the addon is there", function()
    local installs = { Ann = { version = "1.2.0", seenAt = 100 } }
    InstallDirectory.Note(installs, "Ann", {}, 200)
    assert.are.same({ version = "1.2.0", seenAt = 200 }, installs.Ann)
  end)

  it("records a member heard from without a version", function()
    local installs = {}
    InstallDirectory.Note(installs, "Bob", {}, 50)
    assert.are.same({ seenAt = 50 }, installs.Bob)
  end)

  it("marks another protocol version, and clears the mark when a HELLO arrives", function()
    local installs = { Ann = { version = "1.0.0", seenAt = 1 } }
    InstallDirectory.Note(installs, "Ann", { incompatible = true }, 2)
    assert.are.same({ version = "1.0.0", incompatible = true, seenAt = 2 }, installs.Ann)
    InstallDirectory.Note(installs, "Ann", { version = "1.3.0" }, 3)
    assert.are.same({ version = "1.3.0", seenAt = 3 }, installs.Ann)
  end)

  it("drops the member heard from longest ago when the table is full", function()
    local installs = { Old = { seenAt = 1 }, Mid = { seenAt = 5 } }
    InstallDirectory.Note(installs, "New", { version = "1.0" }, 10, 2)
    assert.is_nil(installs.Old)
    assert.is_table(installs.Mid)
    assert.is_table(installs.New)
    InstallDirectory.Note(installs, "Mid", {}, 11, 2)
    assert.is_table(installs.New)
  end)

  it("writes nothing for a bad name, table or time", function()
    local installs = {}
    assert.is_false(InstallDirectory.Note(installs, "", {}, 1))
    assert.is_false(InstallDirectory.Note(installs, nil, {}, 1))
    assert.is_false(InstallDirectory.Note(installs, "Ann", {}, nil))
    assert.is_false(InstallDirectory.Note(nil, "Ann", {}, 1))
    assert.are.same({}, installs)
  end)
end)

describe("InstallDirectory.CompareVersions", function()
  it("compares number by number", function()
    assert.are.equal(1, InstallDirectory.CompareVersions("1.10.0", "1.9.3"))
    assert.are.equal(-1, InstallDirectory.CompareVersions("1.2", "1.2.1"))
    assert.are.equal(0, InstallDirectory.CompareVersions("v1.2.0", "1.2"))
  end)

  it("cannot compare a version with no number", function()
    assert.is_nil(InstallDirectory.CompareVersions("dev", "1.0"))
    assert.is_nil(InstallDirectory.CompareVersions("1.0", nil))
  end)
end)

describe("InstallDirectory.Newest", function()
  it("picks the newest comparable version, the own one included", function()
    local installs = { A = { version = "1.2.0" }, B = { version = "1.10.0" }, C = { version = "dev" } }
    assert.are.equal("1.10.0", InstallDirectory.Newest(installs, "1.3.0"))
    assert.are.equal("2.0", InstallDirectory.Newest(installs, "2.0"))
  end)

  it("ignores members on another protocol version", function()
    assert.are.equal("1.0", InstallDirectory.Newest({ A = { version = "9.0", incompatible = true } }, "1.0"))
  end)

  it("is nil when nothing can be compared", function()
    assert.is_nil(InstallDirectory.Newest({ A = { version = "dev" } }, "dev"))
  end)
end)

describe("InstallDirectory.Status", function()
  it("tells current, outdated, unknown version and incompatible apart", function()
    assert.are.equal("current", InstallDirectory.Status({ version = "1.3.0" }, "1.3.0"))
    assert.are.equal("outdated", InstallDirectory.Status({ version = "1.2.9" }, "1.3.0"))
    assert.are.equal("installed", InstallDirectory.Status({ seenAt = 1 }, "1.3.0"))
    assert.are.equal("installed", InstallDirectory.Status({ version = "dev" }, "1.3.0"))
    assert.are.equal("installed", InstallDirectory.Status({ version = "1.0" }, nil))
    assert.are.equal("incompatible", InstallDirectory.Status({ version = "1.3.0", incompatible = true }, "1.3.0"))
  end)

  it("says missing for an online member with no record and unseen for an offline one", function()
    assert.are.equal("missing", InstallDirectory.Status(nil, "1.0", true))
    assert.are.equal("unseen", InstallDirectory.Status(nil, "1.0", false))
  end)
end)
