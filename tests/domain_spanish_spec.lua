-- The texts the domain layer builds, in Spanish, with the same data as in English.
local function load_spanish(locale)
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/RosterService",
    "Domain/RecipeService",
    "Domain/EventModel",
    "Domain/Professions",
    "Domain/ReadinessService",
    "Domain/ReadinessRules",
    "Domain/ProfileService",
    "Domain/PublishService",
    "Domain/TemplateService",
    "Domain/ReportService",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
    if path == "Locales/esES" then
      ns.Locale.Use(locale)
    end
  end
  return ns
end

local function text(lines)
  return table.concat(lines, "\n")
end

describe("Readiness in Spanish", function()
  local ns = load_spanish("esES")
  local profile = { level = 60, ilvl = 1, fields = { role = { value = "tank", source = "declared" } } }

  it("shows the statuses, the starting labels and the details in Spanish", function()
    local results, summary = ns.ReadinessService.Evaluate(ns.Constants.DEFAULT_RULES, profile, {})
    local lines = text(ns.ReadinessService.Describe(results, summary))
    assert.is_truthy(lines:find("Preparación: 3/5 cumplidos, 2 desconocidos", 1, true))
    assert.is_truthy(lines:find("[cumplido] Nivel 60 - nivel 60 (hace falta 60)", 1, true))
    assert.is_truthy(lines:find("[desconocido] Consumibles listos - sin confirmar", 1, true))
  end)

  it("keeps the English status in the data, and shows a rule the guild wrote as written", function()
    local results = ns.ReadinessService.Evaluate({ { id = "x", label = "My own rule", check = "confirm" } }, {}, {})
    assert.are.equal("unknown", results[1].status)
    assert.are.equal("My own rule", results[1].label)
  end)

  it("says what is missing for each automatic check", function()
    local function detail(rule, data)
      return ns.ReadinessService.EvaluateRule(rule, data, {}).detail
    end
    assert.are.equal("sin datos de nivel", detail({ id = "a", label = "A", check = "level", min = 60 }, {}))
    assert.are.equal(
      "Minería no aprendida",
      detail({ id = "a", label = "A", check = "profession", profession = "Mining" }, { professions = {} })
    )
    assert.are.equal(
      "sin encantar: ranura 5",
      detail({ id = "a", label = "A", check = "enchants", slots = { 5 } }, { enchants = { [5] = 0 } })
    )
    assert.are.equal(
      "ningún buff coincidente activo",
      detail({ id = "a", label = "A", check = "buff", names = { "Flask" } }, { buffs = {} })
    )
  end)

  it("describes the rules in force", function()
    assert.is_truthy(ns.ReadinessRules.Describe({})[1]:find("Reglas iniciales", 1, true))
    local record = { rev = 2, rules = { { id = "a", label = "A", check = "confirm" } } }
    assert.is_truthy(ns.ReadinessRules.Describe(record)[1]:find("revisión 2", 1, true))
  end)
end)

describe("Profile and publication in Spanish", function()
  local ns = load_spanish("esES")
  local profile = {
    class = "WARRIOR",
    level = 60,
    ilvl = 200,
    professions = { { name = "Mining", skill = 300 } },
    enchants = { [16] = 100, [5] = 0 },
    buffs = { { name = "Well Fed", spellId = 1 } },
    provenance = { class = { source = "observed" }, level = { source = "observed" }, ilvl = { source = "observed" } },
    fields = { role = { value = "tank", source = "declared" } },
  }

  it("describes the profile with where each value comes from", function()
    local lines = text(ns.ProfileService.Describe(profile))
    assert.is_truthy(lines:find("Clase: WARRIOR [verificado]", 1, true))
    assert.is_truthy(lines:find("Profesiones: Mining (300) [verificado]", 1, true))
    assert.is_truthy(lines:find("Encantamientos: 1 de 2 objetos equipados [verificado]", 1, true))
    assert.is_truthy(lines:find("Buffs activos: 1 [verificado]", 1, true))
    assert.is_truthy(lines:find("role: tank [declarado]", 1, true))
  end)

  it("says what is unknown", function()
    local lines = text(ns.ProfileService.Describe({}))
    assert.is_truthy(lines:find("Clase: desconocido", 1, true))
    assert.is_truthy(lines:find("Profesiones: desconocidas", 1, true))
  end)

  it("lists what is shared with the guild and what stays here", function()
    local lines = text(ns.PublishService.Describe(profile))
    assert.is_truthy(lines:find("Compartido con la guild: WARRIOR, nivel 60", 1, true))
    assert.is_truthy(lines:find("Compartido con la guild: Mining 300", 1, true))
    assert.is_truthy(lines:find("No se comparte: notas, encantamientos ni buffs", 1, true))
    assert.is_truthy(ns.PublishService.Describe({})[1]:find("Todavía no se puede compartir nada", 1, true))
  end)
end)

describe("Reports and templates in Spanish", function()
  local ns = load_spanish("esES")

  it("writes the attendance report with the states in Spanish", function()
    local rows = {
      { characterKey = "Ann-Realm", attended = 2, outcomes = 3, rate = 2 / 3, counts = { present = 2, absent = 1 } },
      { characterKey = "Bob-Realm", attended = 0, outcomes = 0, counts = { excused = 1 } },
    }
    local lines = text(ns.ReportService.DescribeAttendance(rows, 3))
    assert.is_truthy(lines:find("Asistencia en 3 evento(s) celebrado(s):", 1, true))
    assert.is_truthy(lines:find("Ann-Realm: 2/3 (67%) - presente 2, ausente 1", 1, true))
    assert.is_truthy(lines:find("Bob-Realm: sin resultado registrado - justificado 1", 1, true))
    assert.is_truthy(ns.ReportService.DescribeAttendance({}, 0)[1]:find("Aún no se ha celebrado", 1, true))
  end)

  it("writes the loot report", function()
    local lines = text(ns.ReportService.DescribeLoot({}, { sessions = 2, awarded = 1, notAwarded = 1, open = 0 }))
    assert.is_truthy(
      lines:find("Loot: 2 sesión(es), 1 adjudicada(s), 1 cerrada(s) sin adjudicar, 0 aún abierta(s).", 1, true)
    )
    assert.are.same({ "Aún no hay sesiones de loot." }, ns.ReportService.DescribeLoot({}, { sessions = 0 }))
  end)

  it("says what applying a template did", function()
    assert.are.equal("3 asignación(es) añadida(s)", ns.TemplateService.Describe({ 1, 2, 3 }, {}))
    assert.are.equal(
      "0 asignación(es) añadida(s) (omitidas - duplicate: 3)",
      ns.TemplateService.Describe({}, { duplicate = 3 })
    )
  end)
end)

describe("The domain texts for a client that is not Spanish", function()
  it("stay in English", function()
    local ns = load_spanish("frFR")
    local results, summary = ns.ReadinessService.Evaluate(ns.Constants.DEFAULT_RULES, { level = 60 }, {})
    assert.is_truthy(text(ns.ReadinessService.Describe(results, summary)):find("[met] Level 60", 1, true))
    assert.is_truthy(ns.PublishService.Describe({})[1]:find("Nothing can be shared yet", 1, true))
  end)
end)
