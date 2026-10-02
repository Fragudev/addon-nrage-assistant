local function load_service()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Domain/PvPService.lua"))("NrageAssistant", ns)
  return ns.PvPService, ns.Constants
end

local PvPService, Constants = load_service()

describe("PvPService.Ensure", function()
  it("builds the full shape from nothing", function()
    assert.are.same(
      { honor = { world = 0, bg = 0 }, blows = { world = 0, bg = 0 }, daily = {} },
      PvPService.Ensure(nil)
    )
  end)

  it("replaces anything that is not a table", function()
    assert.are.same(
      { honor = { world = 0, bg = 0 }, blows = { world = 0, bg = 0 }, daily = {} },
      PvPService.Ensure("x")
    )
  end)

  it("keeps good counts and repairs corrupt ones", function()
    local stats = PvPService.Ensure({
      honor = { world = 5, bg = "many" },
      blows = "oops",
      daily = {
        ["2026-10-01"] = { honor = { world = 2, bg = -1 }, blows = { world = 1.5 } },
        ["2026-10-02"] = "bad",
        yesterday = {},
      },
    })
    assert.are.equal(5, stats.honor.world)
    assert.are.equal(0, stats.honor.bg)
    assert.are.same({ world = 0, bg = 0 }, stats.blows)
    assert.are.same({ honor = { world = 2, bg = 0 }, blows = { world = 0, bg = 0 } }, stats.daily["2026-10-01"])
    assert.is_nil(stats.daily["2026-10-02"])
    assert.is_nil(stats.daily.yesterday)
  end)

  it("repairs a daily table that is not a table", function()
    assert.are.same({}, PvPService.Ensure({ daily = 3 }).daily)
  end)

  it("returns the same table it was given", function()
    local stats = {}
    assert.are.equal(stats, PvPService.Ensure(stats))
  end)
end)

describe("PvPService recording", function()
  local stats

  before_each(function()
    stats = PvPService.Ensure({})
  end)

  it("counts honourable kills in the right bucket, in total and per day", function()
    assert.is_true(PvPService.RecordHonorKills(stats, 2, "world", "2026-10-01"))
    assert.is_true(PvPService.RecordHonorKills(stats, 3, "bg", "2026-10-01"))
    assert.are.same({ world = 2, bg = 3 }, stats.honor)
    assert.are.same({ world = 2, bg = 3 }, stats.daily["2026-10-01"].honor)
    assert.are.same({ world = 0, bg = 0 }, stats.blows)
  end)

  it("counts killing blows in the right bucket", function()
    assert.is_true(PvPService.RecordKillingBlow(stats, "world", "2026-10-01"))
    assert.is_true(PvPService.RecordKillingBlow(stats, "bg", "2026-10-01"))
    assert.is_true(PvPService.RecordKillingBlow(stats, "bg", "2026-10-01"))
    assert.are.same({ world = 1, bg = 2 }, stats.blows)
    assert.are.same({ world = 1, bg = 2 }, stats.daily["2026-10-01"].blows)
  end)

  it("ignores deltas that are not positive whole numbers", function()
    for _, delta in ipairs({ 0, -1, 1.5, "2", math.huge, 0 / 0 }) do
      assert.is_false(PvPService.RecordHonorKills(stats, delta, "world", "2026-10-01"))
    end
    assert.is_false(PvPService.RecordHonorKills(stats, nil, "world", "2026-10-01"))
    assert.are.same({ world = 0, bg = 0 }, stats.honor)
    assert.are.same({}, stats.daily)
  end)

  it("ignores an unknown bucket", function()
    assert.is_false(PvPService.RecordHonorKills(stats, 1, "arena", "2026-10-01"))
    assert.is_false(PvPService.RecordKillingBlow(stats, nil, "2026-10-01"))
    assert.are.same({ world = 0, bg = 0 }, stats.honor)
    assert.are.same({ world = 0, bg = 0 }, stats.blows)
  end)

  it("still counts the total when the day is unknown", function()
    assert.is_true(PvPService.RecordHonorKills(stats, 1, "world", nil))
    assert.is_true(PvPService.RecordKillingBlow(stats, "bg", "not a day"))
    assert.are.equal(1, stats.honor.world)
    assert.are.equal(1, stats.blows.bg)
    assert.are.same({}, stats.daily)
  end)

  it("repairs damaged data before counting", function()
    local damaged = { honor = "x" }
    PvPService.RecordHonorKills(damaged, 1, "world", "2026-10-01")
    assert.are.equal(1, damaged.honor.world)
    assert.are.equal(0, damaged.blows.bg)
  end)
end)

describe("PvPService.Totals and Today", function()
  it("adds the buckets up", function()
    local stats = PvPService.Ensure({})
    PvPService.RecordHonorKills(stats, 2, "world", "2026-10-01")
    PvPService.RecordHonorKills(stats, 3, "bg", "2026-10-02")
    PvPService.RecordKillingBlow(stats, "bg", "2026-10-02")
    assert.are.same({
      honor = { world = 2, bg = 3, total = 5 },
      blows = { world = 0, bg = 1, total = 1 },
    }, PvPService.Totals(stats))
  end)

  it("reports only the given day, and zeros for a day without kills", function()
    local stats = PvPService.Ensure({})
    PvPService.RecordHonorKills(stats, 2, "world", "2026-10-01")
    PvPService.RecordHonorKills(stats, 3, "bg", "2026-10-02")
    assert.are.same({
      honor = { world = 0, bg = 3, total = 3 },
      blows = { world = 0, bg = 0, total = 0 },
    }, PvPService.Today(stats, "2026-10-02"))
    assert.are.equal(0, PvPService.Today(stats, "2026-10-05").honor.total)
    assert.are.equal(0, PvPService.Today(stats, nil).honor.total)
  end)

  it("rolls over at the day change without touching the total", function()
    local stats = PvPService.Ensure({})
    PvPService.RecordHonorKills(stats, 2, "world", "2026-10-01")
    PvPService.RecordHonorKills(stats, 1, "world", "2026-10-02")
    assert.are.equal(1, PvPService.Today(stats, "2026-10-02").honor.total)
    assert.are.equal(2, PvPService.Today(stats, "2026-10-01").honor.total)
    assert.are.equal(3, PvPService.Totals(stats).honor.total)
  end)

  it("works on nil", function()
    assert.are.equal(0, PvPService.Totals(nil).honor.total)
    assert.are.equal(0, PvPService.Today(nil, "2026-10-01").blows.total)
  end)
end)

describe("PvPService.Prune", function()
  local function stats_with(days)
    local stats = PvPService.Ensure({})
    for _, day in ipairs(days) do
      PvPService.RecordHonorKills(stats, 1, "world", day)
    end
    return stats
  end

  it("keeps the last 30 days, counting today", function()
    local stats = stats_with({ "2026-09-01", "2026-09-02", "2026-10-01" })
    PvPService.Prune(stats, "2026-10-01", Constants.PVP_DAILY_DAYS)
    assert.is_nil(stats.daily["2026-09-01"])
    assert.is_table(stats.daily["2026-09-02"])
    assert.is_table(stats.daily["2026-10-01"])
  end)

  it("keeps at most 30 days even after a long run", function()
    local days = {}
    for day = 1, 28 do
      days[#days + 1] = ("2026-08-%02d"):format(day)
      days[#days + 1] = ("2026-09-%02d"):format(day)
    end
    local stats = stats_with(days)
    PvPService.Prune(stats, "2026-09-28", Constants.PVP_DAILY_DAYS)
    local kept = 0
    for _ in pairs(stats.daily) do
      kept = kept + 1
    end
    assert.is_true(kept <= Constants.PVP_DAILY_DAYS)
    assert.is_table(stats.daily["2026-09-28"])
    assert.is_nil(stats.daily["2026-08-28"])
  end)

  it("counts across a year change and a leap day", function()
    local stats = stats_with({ "2023-12-31", "2024-01-01", "2024-02-29", "2024-03-01", "2024-03-30" })
    PvPService.Prune(stats, "2024-03-30", 30)
    assert.is_nil(stats.daily["2023-12-31"])
    assert.is_nil(stats.daily["2024-01-01"])
    assert.is_nil(stats.daily["2024-02-29"])
    assert.is_table(stats.daily["2024-03-01"])
    assert.is_table(stats.daily["2024-03-30"])

    local longer = stats_with({ "2024-02-29", "2024-02-28" })
    PvPService.Prune(longer, "2024-03-30", 31)
    assert.is_table(longer.daily["2024-02-29"])
    assert.is_nil(longer.daily["2024-02-28"])
  end)

  it("does not touch the totals", function()
    local stats = stats_with({ "2026-01-01", "2026-10-01" })
    PvPService.Prune(stats, "2026-10-01", 30)
    assert.are.equal(2, stats.honor.world)
  end)

  it("does nothing when today or the limit is unusable", function()
    local stats = stats_with({ "2026-01-01" })
    PvPService.Prune(stats, nil, 30)
    PvPService.Prune(stats, "2026-13-45", 30)
    PvPService.Prune(stats, "2026-10-01", 0)
    PvPService.Prune(stats, "2026-10-01", "x")
    assert.is_table(stats.daily["2026-01-01"])
  end)

  it("drops buckets with an impossible date", function()
    local stats = stats_with({ "2026-00-10" })
    PvPService.Prune(stats, "2026-10-01", 30)
    assert.are.same({}, stats.daily)
  end)
end)
