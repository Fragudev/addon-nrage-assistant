-- Recipes: the service (scan, chunks, index), the wire validation and the receiving side.
local function load_addon()
  dofile("NrageAssistant/Libs/LibStub/LibStub.lua")
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/RecipeService",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/RecipeSync",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_addon()
local RecipeService, RecipeSync, Protocol = ns.RecipeService, ns.RecipeSync, ns.Protocol

local function wire(payload)
  return Protocol.Validate(Protocol.Build("RECIPES", payload, "id-1"))
end

local function payload(overrides)
  local p = { prof = 171, name = "Alchemy", rev = 5, updatedAt = 100, part = 1, parts = 1, ids = { 3, 1, 2 } }
  for key, value in pairs(overrides or {}) do
    p[key] = value
  end
  return p
end

describe("RecipeService", function()
  it("normalizes ids: valid, unique, sorted and capped", function()
    assert.are.same({ 1, 2, 5 }, RecipeService.Normalize({ 5, 1, 1, 2, -3, "x", 0 }))
    assert.are.same({}, RecipeService.Normalize(nil))
    local many = {}
    for id = 1, ns.Constants.RECIPES_MAX_PER_PROFESSION + 10 do
      many[id] = id
    end
    assert.are.equal(ns.Constants.RECIPES_MAX_PER_PROFESSION, #RecipeService.Normalize(many))
  end)

  it("gives the same fingerprint to the same ids in any order", function()
    assert.are.equal(RecipeService.Fingerprint({ 3, 1 }), RecipeService.Fingerprint({ 1, 3, 3 }))
  end)

  it("stores a scan and raises the revision only when the recipes changed", function()
    local recipes = {}
    local scan = { professionId = 171, professionName = "Alchemy", ids = { 2, 1 } }
    local record, changed = RecipeService.StoreScan(recipes, scan, 1000, 150)
    assert.is_true(changed)
    assert.are.same({ 1, 2 }, record.ids)
    assert.are.equal(1000, record.rev)
    local again, changedAgain = RecipeService.StoreScan(recipes, scan, 2000, 151)
    assert.is_false(changedAgain)
    assert.are.equal(1000, again.rev)
    assert.are.equal(2000, again.at)
    local _, third = RecipeService.StoreScan(recipes, { professionId = 171, ids = { 1, 2, 9 } }, 3000, 151)
    assert.is_true(third)
    assert.are.equal(3000, recipes[171].rev)
  end)

  it("refuses a scan with a bad profession id", function()
    assert.is_nil((RecipeService.StoreScan({}, { professionId = 0, ids = { 1 } }, 1, 1)))
  end)

  it("splits a record into chunks that fit a message", function()
    local ids = {}
    for id = 1, ns.Constants.RECIPE_CHUNK * 2 + 1 do
      ids[id] = id
    end
    local chunks = RecipeService.Chunks(171, { name = "Alchemy", rev = 7, ids = ids }, 50)
    assert.are.equal(3, #chunks)
    assert.are.equal(3, chunks[3].parts)
    assert.are.equal(1, #chunks[3].ids)
    assert.are.equal(1, #RecipeService.Chunks(171, { name = "x", rev = 1, ids = {} }, 1))
  end)

  it("tells when a profession needs a new scan", function()
    assert.is_true(RecipeService.NeedsScan(nil, 10))
    assert.is_true(RecipeService.NeedsScan({ skill = 10 }, 11))
    assert.is_false(RecipeService.NeedsScan({ skill = 10 }, 10))
    assert.is_false(RecipeService.NeedsScan({ skill = 10 }, nil))
  end)

  it("indexes the recipes of everyone and leaves out members that left", function()
    local own = { key = "Me-R", recipes = { [171] = { name = "Alchemy", ids = { 1, 2 } } } }
    local received = {
      ["Ann-R"] = { [171] = { name = "Alchemy", ids = { 2, 3 } } },
      ["Gone-R"] = { [164] = { name = "Smithing", ids = { 9 } } },
      ["Me-R"] = { [171] = { name = "Alchemy", ids = { 77 } } },
    }
    local index = RecipeService.Index(own, received, function(name)
      return name ~= "Gone-R"
    end)
    assert.are.same({ "Ann-R", "Me-R" }, index.recipes[2].crafters)
    assert.is_nil(index.recipes[9])
    assert.is_nil(index.recipes[77])
    assert.are.equal(2, index.members)
    assert.are.equal("Alchemy", index.professions[171])
  end)
end)

describe("RECIPES on the wire", function()
  it("accepts a well-formed message", function()
    local message = assert(wire(payload()))
    assert.are.same({ 3, 1, 2 }, message.p.ids)
  end)

  it("rejects bad fields", function()
    assert.is_nil(wire(payload({ prof = 0 })))
    assert.is_nil(wire(payload({ parts = 0 })))
    assert.is_nil(wire(payload({ part = 2 })))
    assert.is_nil(wire(payload({ ids = { 1, 1 } })))
    assert.is_nil(wire(payload({ ids = { "a" } })))
    assert.is_nil(wire(payload({ name = 5 })))
    assert.is_nil(wire(payload({ total = -1 })))
    assert.is_nil(wire(payload({ ids = "x" })))
    local big = {}
    for id = 1, ns.Constants.RECIPE_CHUNK + 1 do
      big[id] = id
    end
    assert.is_nil(wire(payload({ ids = big })))
  end)
end)

describe("RecipeSync.Apply", function()
  local function ctx()
    return {
      recipes = {},
      staging = {},
      now = function()
        return 500
      end,
    }
  end
  local function message(overrides)
    return assert(wire(payload(overrides)))
  end

  it("stores a complete single-part list for the sender", function()
    local c = ctx()
    local stored = 0
    c.onStored = function()
      stored = stored + 1
    end
    assert.is_true(RecipeSync.Apply(c, message(), "Ann-R", "member"))
    assert.are.same({ 1, 2, 3 }, c.recipes["Ann-R"][171].ids)
    assert.are.equal(5, c.recipes["Ann-R"][171].rev)
    assert.are.equal(1, stored)
  end)

  it("assembles parts in any order and only then replaces what is stored", function()
    local c = ctx()
    local ok, partial = RecipeSync.Apply(c, message({ parts = 2, part = 2, ids = { 9 } }), "Ann-R", "member")
    assert.is_true(ok)
    assert.are.equal("partial", partial)
    assert.is_nil(c.recipes["Ann-R"])
    assert.is_true(RecipeSync.Apply(c, message({ parts = 2, part = 1, ids = { 4 } }), "Ann-R", "member"))
    assert.are.same({ 4, 9 }, c.recipes["Ann-R"][171].ids)
    assert.is_nil(next(c.staging))
  end)

  it("ignores a stale or equal revision", function()
    local c = ctx()
    RecipeSync.Apply(c, message(), "Ann-R", "member")
    local ok, reason = RecipeSync.Apply(c, message({ ids = { 8 } }), "Ann-R", "member")
    assert.is_false(ok)
    assert.are.equal("stale", reason)
  end)

  it("drops a half list when a newer revision starts", function()
    local c = ctx()
    RecipeSync.Apply(c, message({ parts = 2, part = 1, rev = 6 }), "Ann-R", "member")
    local ok, reason = RecipeSync.Apply(c, message({ parts = 2, part = 1, rev = 5 }), "Ann-R", "member")
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    RecipeSync.Apply(c, message({ parts = 1, rev = 7, ids = { 1 } }), "Ann-R", "member")
    assert.are.same({ 1 }, c.recipes["Ann-R"][171].ids)
  end)

  it("rejects the same recipe in two parts", function()
    local c = ctx()
    RecipeSync.Apply(c, message({ parts = 2, part = 1, ids = { 4 } }), "Ann-R", "member")
    local ok, reason = RecipeSync.Apply(c, message({ parts = 2, part = 2, ids = { 4 } }), "Ann-R", "member")
    assert.is_false(ok)
    assert.are.equal("bad_parts", reason)
  end)

  it("refuses an outsider and other message types", function()
    local c = ctx()
    local ok, reason = RecipeSync.Apply(c, message(), "Zed-R", "outsider")
    assert.is_false(ok)
    assert.is_truthy(reason)
    assert.is_nil(c.recipes["Zed-R"])
    local other = { t = "DELETE", p = {} }
    assert.are.equal("unsupported", select(2, RecipeSync.Apply(c, other, "Ann-R", "member")))
  end)

  it("evicts the member whose lists arrived longest ago when the table is full", function()
    local c = ctx()
    for index = 1, ns.Constants.RECIPE_MEMBERS_MAX do
      c.recipes["M" .. index] = { [171] = { rev = 1, ids = {}, receivedAt = 100 + index } }
    end
    assert.is_true(RecipeSync.Apply(c, message(), "New-R", "member"))
    assert.is_truthy(c.recipes["New-R"])
    assert.is_nil(c.recipes["M1"])
    assert.is_truthy(c.recipes["M2"])
    local count = 0
    for _ in pairs(c.recipes) do
      count = count + 1
    end
    assert.are.equal(ns.Constants.RECIPE_MEMBERS_MAX, count)
  end)

  it("counts the ids again when a part is sent twice, and rejects parts that do not add up to the total", function()
    local c = ctx()
    local function ids(first, last)
      local list = {}
      for id = first, last do
        list[#list + 1] = id
      end
      return list
    end
    assert.is_true(RecipeSync.Apply(c, message({ parts = 2, part = 1, ids = ids(1, 150) }), "Ann-R", "member"))
    assert.are.equal(150, c.staging["Ann-R\n171"].ids)
    -- The part is sent again, smaller: what it held before no longer counts.
    assert.is_true(RecipeSync.Apply(c, message({ parts = 2, part = 1, ids = ids(1, 10) }), "Ann-R", "member"))
    assert.are.equal(10, c.staging["Ann-R\n171"].ids)
    assert.are.equal(1, c.staging["Ann-R\n171"].count)

    -- A total that does not match what the parts hold.
    local c2 = ctx()
    RecipeSync.Apply(c2, message({ parts = 2, part = 1, total = 5, ids = { 1, 2 } }), "Ann-R", "member")
    local ok, reason = RecipeSync.Apply(c2, message({ parts = 2, part = 2, total = 5, ids = { 3 } }), "Ann-R", "member")
    assert.is_false(ok)
    assert.are.equal("bad_parts", reason)
    assert.is_nil(c2.recipes["Ann-R"])

    -- A matching total is stored; no total (an older client) is accepted as before.
    local c3 = ctx()
    RecipeSync.Apply(c3, message({ parts = 2, part = 1, total = 3, ids = { 1, 2 } }), "Ann-R", "member")
    assert.is_true(RecipeSync.Apply(c3, message({ parts = 2, part = 2, total = 3, ids = { 3 } }), "Ann-R", "member"))
    assert.are.same({ 1, 2, 3 }, c3.recipes["Ann-R"][171].ids)
  end)

  it("bounds professions and half lists", function()
    local ok, reason
    local c2 = ctx()
    c2.recipes["Ann-R"] = {}
    for index = 1, ns.Constants.RECIPE_PROFESSIONS_MAX do
      c2.recipes["Ann-R"][index + 1000] = { rev = 1, ids = {} }
    end
    ok, reason = RecipeSync.Apply(c2, message(), "Ann-R", "member")
    assert.is_false(ok)
    assert.are.equal("limit", reason)

    local c3 = ctx()
    for index = 1, ns.Constants.RECIPE_STAGING_MAX + 5 do
      RecipeSync.Apply(c3, message({ parts = 2, part = 1, prof = 100 + index }), "Ann-R", "member")
    end
    local count = 0
    for _ in pairs(c3.staging) do
      count = count + 1
    end
    assert.is_true(count <= ns.Constants.RECIPE_STAGING_MAX)
  end)

  it("recognizes its message type and builds payloads", function()
    assert.is_true(RecipeSync.IsRecipeMessage("RECIPES"))
    assert.is_false(RecipeSync.IsRecipeMessage("DELETE"))
    assert.are.equal(1, #RecipeSync.Payloads(171, { name = "A", rev = 1, ids = { 1 } }, 1))
  end)
end)
