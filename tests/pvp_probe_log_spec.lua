local function load_log()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/PvPProbeLog.lua"))("NrageAssistant", ns)
  return ns.PvPProbeLog
end

local function fake_platform()
  local p = { clock = 0 }
  p.Now = function()
    p.clock = p.clock + 1
    return p.clock
  end
  p.WallClock = function()
    return "12:00:00"
  end
  return p
end

-- Stands in for a secret value: it cannot be turned into text, compared or indexed.
local function secret()
  return setmetatable({}, {
    __tostring = function()
      error("secret value")
    end,
    __eq = function()
      error("secret value")
    end,
    __index = function()
      error("secret value")
    end,
  })
end

describe("PvPProbeLog", function()
  local PvPProbeLog = load_log()

  describe("log", function()
    it("records entries with the injected clocks", function()
      local log = PvPProbeLog.New(fake_platform())
      log:Record("honor", "text")
      local entry = log:GetLog()[1]
      assert.are.same({ t = 1, wall = "12:00:00", kind = "honor", detail = "text" }, entry)
    end)

    it("is bounded and drops the oldest entries", function()
      local log = PvPProbeLog.New(fake_platform())
      for i = 1, 250 do
        log:Record("event", tostring(i))
      end
      assert.are.equal(200, #log:GetLog())
      assert.are.equal("51", log:GetLog()[1].detail)
      assert.are.equal("250", log:GetLog()[200].detail)
    end)

    it("clears", function()
      local log = PvPProbeLog.New(fake_platform())
      log:Record("event", "x")
      log:Clear()
      assert.are.equal(0, #log:GetLog())
    end)
  end)

  describe("ToText", function()
    it("converts ordinary values", function()
      assert.are.equal("12", PvPProbeLog.ToText(12))
      assert.are.equal("nil", PvPProbeLog.ToText(nil))
    end)

    it("turns a value that cannot be converted into <secret>", function()
      assert.are.equal("<secret>", PvPProbeLog.ToText(secret()))
    end)
  end)

  describe("FormatArgs", function()
    it("formats every argument on one line, secrets and nils included", function()
      assert.are.equal("[1]=a [2]=nil [3]=<secret> [4]=5", PvPProbeLog.FormatArgs("a", nil, secret(), 5))
    end)

    it("says when there are none", function()
      assert.are.equal("(no arguments)", PvPProbeLog.FormatArgs())
    end)
  end)

  describe("Snapshot", function()
    it("reads the four counters", function()
      local snapshot = PvPProbeLog.Snapshot(function()
        return 3, 120, 500, 4
      end)
      assert.are.same({ sessionHK = 3, sessionHonor = 120, lifetimeHK = 500, highestRank = 4 }, snapshot)
    end)

    it("returns an error marker when the reader raises", function()
      local snapshot = PvPProbeLog.Snapshot(function()
        error("boom", 0)
      end)
      assert.are.equal("boom", snapshot.error)
    end)

    it("returns an error marker when the reader is missing", function()
      assert.are.equal("missing", PvPProbeLog.Snapshot(nil).error)
    end)

    it("keeps secrets as text instead of raising", function()
      local snapshot = PvPProbeLog.Snapshot(function()
        return secret(), 1, nil, secret()
      end)
      assert.are.equal("<secret>", snapshot.sessionHK)
      assert.are.equal(1, snapshot.sessionHonor)
      assert.are.equal("nil", snapshot.lifetimeHK)
    end)

    it("describes a snapshot and an error marker", function()
      local snapshot = { sessionHK = 1, sessionHonor = 2, lifetimeHK = 3, highestRank = 4 }
      assert.are.equal("sessionHK=1 sessionHonor=2 lifetimeHK=3 highestRank=4", PvPProbeLog.DescribeSnapshot(snapshot))
      assert.are.equal("counters unavailable (missing)", PvPProbeLog.DescribeSnapshot({ error = "missing" }))
    end)
  end)

  describe("DescribeDelta", function()
    local base = { sessionHK = 3, sessionHonor = 100, lifetimeHK = 10, highestRank = 2 }

    it("reports no change", function()
      assert.are.equal("no change", PvPProbeLog.DescribeDelta(base, base))
    end)

    it("reports an increase", function()
      local after = { sessionHK = 4, sessionHonor = 100, lifetimeHK = 11, highestRank = 2 }
      assert.are.equal("sessionHK 3->4 (+1), lifetimeHK 10->11 (+1)", PvPProbeLog.DescribeDelta(base, after))
    end)

    it("reports a decrease, such as the session counters resetting on a relog", function()
      local after = { sessionHK = 0, sessionHonor = 0, lifetimeHK = 10, highestRank = 2 }
      assert.are.equal("sessionHK 3->0 (-3), sessionHonor 100->0 (-100)", PvPProbeLog.DescribeDelta(base, after))
    end)

    it("does not raise when a snapshot is an error marker or holds secrets", function()
      assert.are.equal("delta unavailable (missing)", PvPProbeLog.DescribeDelta({ error = "missing" }, base))
      local hidden = { sessionHK = "<secret>", sessionHonor = 100, lifetimeHK = 10, highestRank = 2 }
      assert.are.equal("sessionHK 3-><secret> (not comparable)", PvPProbeLog.DescribeDelta(base, hidden))
    end)
  end)

  describe("DescribeInstance", function()
    it("describes a battleground", function()
      assert.are.equal("inInstance=true instanceType=pvp", PvPProbeLog.DescribeInstance(true, "pvp"))
    end)

    it("copes with missing and secret values", function()
      assert.are.equal("inInstance=nil instanceType=<secret>", PvPProbeLog.DescribeInstance(nil, secret()))
    end)
  end)

  describe("DescribeCombatEvent", function()
    local event = {
      subevent = "PARTY_KILL",
      sourceGUID = "Player-1-A",
      sourceName = "Me",
      destGUID = "Player-2-B",
      destName = "Enemy",
      destFlags = 548,
      spellName = "ignored",
    }

    it("flags a source that is the player and keeps only the relevant fields", function()
      local text, fields = PvPProbeLog.DescribeCombatEvent(event, "Player-1-A")
      assert.is_true(fields.sourceIsPlayer)
      assert.are.equal("Enemy", fields.destName)
      assert.is_nil(fields.spellName)
      assert.is_nil(text:find("ignored", 1, true))
      assert.is_truthy(text:find("sourceIsPlayer=true", 1, true))
    end)

    it("flags a source that is someone else, or an unknown player GUID", function()
      assert.is_false(select(2, PvPProbeLog.DescribeCombatEvent(event, "Player-9-Z")).sourceIsPlayer)
      assert.is_false(select(2, PvPProbeLog.DescribeCombatEvent(event, nil)).sourceIsPlayer)
    end)

    it("survives accessors that raise", function()
      local hostile = setmetatable({}, {
        __index = function()
          error("secret value")
        end,
      })
      local text, fields = PvPProbeLog.DescribeCombatEvent(hostile, "Player-1-A")
      assert.are.equal("<secret>", fields.destGUID)
      assert.is_false(fields.sourceIsPlayer)
      assert.is_truthy(text:find("subevent=<secret>", 1, true))
    end)

    it("survives secret field values", function()
      local _, fields = PvPProbeLog.DescribeCombatEvent({ sourceGUID = secret(), destName = secret() }, "Player-1-A")
      assert.are.equal("<secret>", fields.destName)
      assert.is_false(fields.sourceIsPlayer)
    end)
  end)
end)
