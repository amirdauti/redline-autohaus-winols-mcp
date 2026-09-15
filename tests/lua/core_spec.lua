-- Synthetic native API fixtures: these tests never open a WinOLS project or file.
local json = require("json")

local function equal(actual, expected, label)
  if type(actual) ~= type(expected) then
    error((label or "value") .. ": type differs (" .. type(actual) .. " vs " .. type(expected) .. ")", 0)
  end
  if type(actual) ~= "table" or actual == json.null or expected == json.null then
    assert(actual == expected, (label or "value") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
    return
  end
  for key, value in pairs(expected) do equal(actual[key], value, (label or "value") .. "." .. tostring(key)) end
  for key in pairs(actual) do assert(expected[key] ~= nil, (label or "value") .. ": unexpected key " .. tostring(key)) end
end

local function definition(name, address)
  return {
    name = name or "Synthetic torque table", address = address or 4096,
    columns = 4, rows = 2, data_type = "i16_be", factor = 0.25, offset = -40,
    unit = "Nm",
    x_axis = { address = 8192, data_type = "u16_le", factor = 0.5, offset = 10, unit = "rpm" },
    y_axis = { address = 8200, data_type = "u8", factor = 2, offset = 1, unit = "%" },
  }
end

local next_request_id = 0
local function request(operation, params)
  next_request_id = next_request_id + 1
  return {
    protocol_version = 1, id = "synthetic-request-" .. next_request_id,
    operation = operation, params = params or {}, expires_at = os.time() + 60,
  }
end

local function response(core, req)
  local result = core:handle(req)
  assert(type(result) == "table", "core must return an envelope")
  assert(result.protocol_version == 1, "response protocol version")
  assert(result.id == req.id, "response must keep the request ID")
  assert(type(result.ok) == "boolean", "response ok must be boolean")
  if result.ok then
    assert(result.result ~= nil and result.error == nil, "success must only contain result")
  else
    assert(result.result == nil and type(result.error) == "table", "failure must only contain error")
    assert(type(result.error.code) == "string" and #result.error.code > 0, "error code")
    assert(type(result.error.message) == "string" and #result.error.message > 0, "error message")
  end
  -- Encoding the envelope also rejects NaN/Infinity and invalid JSON shapes.
  json.decode(json.encode(result))
  return result
end

local function success(core, operation, params)
  local result = response(core, request(operation, params))
  assert(result.ok, operation .. " failed: " .. (result.error and result.error.message or "unknown"))
  return result.result
end

local function failure(core, operation, params)
  local result = response(core, request(operation, params))
  assert(not result.ok, operation .. " unexpectedly succeeded")
  return result.error
end

local function run(name, fn)
  local ok, err = pcall(fn)
  if not ok then error("core_spec: " .. name .. ": " .. tostring(err), 0) end
end

local function fixture()
  local result = require("native_fixture").new()
  return result.core, result.state, result.api
end

local function create(core, project, map)
  return success(core, "create_map", { expected_project_id = project.id, definition = map })
end

local function untouched(state, expected_maps)
  assert(#state.maps == (expected_maps or 0), "unexpected map mutation")
  assert(state.binary_writes == 0, "binary data was written")
  assert(state.saves == 0, "project was saved")
end

run("create and native readback preserve axes, signed endian types, and scaling", function()
  local core, state = fixture()
  local project = success(core, "get_project")
  assert(project.name == "fixture.ols" and project.size_bytes == 1048576 and project.map_count == 0)
  local wanted = definition()
  local created = create(core, project, wanted)
  equal(created.definition, wanted, "created definition")
  assert(created.id == "map:4096:0")
  equal(success(core, "get_map", { id = created.id }), created, "native readback")
  local listed = success(core, "list_maps", { offset = 0, limit = 10 })
  equal(listed.maps[1], created)
  assert(listed.total == 1 and #listed.maps == 1)
  assert(success(core, "get_project").map_count == 1)
  assert(state.adds == 1 and state.sets > 0)
  untouched(state, 1)
end)

run("identity defaults and comma decimal native properties are supported", function()
  local core, state = fixture()
  local project = success(core, "get_project")
  local wanted = { name = "Synthetic defaults", address = 0, columns = 1, rows = 1, data_type = "u8" }
  local created = create(core, project, wanted)
  assert(created.definition.factor == 1 and created.definition.offset == 0 and created.definition.unit == "")
  assert(created.definition.x_axis == nil and created.definition.y_axis == nil)
  local scaled = definition("Synthetic comma decimal", 4096)
  state.comma_decimal = true
  equal(create(core, project, scaled).definition, scaled)
  untouched(state, 2)
end)

run("every supported integer type uses the documented native byte order and sign", function()
  local cases = {
    { "u8", "eByte", "0" }, { "i8", "eByte", "1" },
    { "u16_le", "eLoHi", "0" }, { "i16_le", "eLoHi", "1" },
    { "u16_be", "eHiLo", "0" }, { "i16_be", "eHiLo", "1" },
    { "u32_le", "eLoHiLoHi", "0" }, { "i32_le", "eLoHiLoHi", "1" },
    { "u32_be", "eHiLoHiLo", "0" }, { "i32_be", "eHiLoHiLo", "1" },
  }
  for _, storage in ipairs(cases) do
    local core, state, api = fixture()
    local project = success(core, "get_project")
    local map = definition("Synthetic " .. storage[1])
    map.data_type = storage[1]
    map.x_axis.data_type = storage[1]
    local created = create(core, project, map)
    equal(created.definition, map)
    assert(state.maps[1].DataOrg == tostring(api[storage[2]]), storage[1] .. " native data organization")
    assert(state.maps[1].bVorzeichen == storage[3], storage[1] .. " native signed flag")
    assert(state.maps[1]["StuetzX.DataOrg"] == tostring(api[storage[2]]), storage[1] .. " axis data organization")
    assert(state.maps[1]["StuetzX.bVorzeichen"] == storage[3], storage[1] .. " axis signed flag")
    untouched(state, 1)
  end
end)

run("stale project identity and a switch during inventory prevent mutation", function()
  local core, state = fixture()
  local first = success(core, "get_project")
  state.filename = "C:\\synthetic\\different-project.ols"
  assert(failure(core, "create_map", { expected_project_id = first.id, definition = definition() }).code == "project_changed")
  local current = success(core, "get_project")
  state.switch_on_inventory = true
  assert(failure(core, "create_map", { expected_project_id = current.id, definition = definition() }).code == "project_changed")
  assert(state.adds == 0 and state.sets == 0)
  untouched(state)
end)

run("map and axis bounds, dimensions, and metadata reject before native mutation", function()
  local core, state = fixture()
  local project = success(core, "get_project")
  local bad = {}
  local map = definition(); map.address = 1048575; bad[#bad + 1] = map
  map = definition(); map.x_axis.address = 1048575; bad[#bad + 1] = map
  map = definition(); map.y_axis.address = 1048575; bad[#bad + 1] = map
  map = definition(); map.address = -1; bad[#bad + 1] = map
  map = definition(); map.columns = 0; bad[#bad + 1] = map
  map = definition(); map.rows = 4097; bad[#bad + 1] = map
  map = definition(); map.columns = 4096; map.rows = 4096; bad[#bad + 1] = map
  map = definition(); map.factor = 0; bad[#bad + 1] = map
  map = definition(); map.offset = math.huge; bad[#bad + 1] = map
  map = definition(); map.name = "invalid\nname"; bad[#bad + 1] = map
  map = definition(); map.colums = 4; bad[#bad + 1] = map
  map = definition(); map.x_axis.length = 4; bad[#bad + 1] = map
  for _, invalid in ipairs(bad) do
    assert(failure(core, "create_map", { expected_project_id = project.id, definition = invalid }).code == "invalid_argument")
  end
  assert(state.adds == 0 and state.sets == 0)
  untouched(state)
end)

run("exact end-of-project address is accepted", function()
  local core, state = fixture()
  local project = success(core, "get_project")
  local map = { name = "Synthetic final byte", address = 1048575, columns = 1, rows = 1, data_type = "u8" }
  assert(create(core, project, map).definition.address == 1048575)
  untouched(state, 1)
end)

run("EVC numeric Boolean constants are verified before any creation", function()
  for _, replacement in ipairs({
    {"TRUE", true}, {"FALSE", false}, {"TRUE", "1"}, {"FALSE", "0"},
    {"TRUE", 2}, {"FALSE", 1}, {"TRUE"}, {"FALSE"},
  }) do
    local core, state, api = fixture()
    local project = success(core, "get_project")
    api[replacement[1]] = replacement[2]
    local r = failure(core, "create_map", { expected_project_id=project.id, definition=definition() })
    assert(r.code == "unsupported_winols")
    assert(state.adds == 0 and state.sets == 0 and state.deletes == 0)
    untouched(state)
  end
end)

run("duplicate names and addresses do not alter existing maps", function()
  local core, state = fixture()
  local project = success(core, "get_project")
  local original = create(core, project, definition())
  local same_name = definition(original.definition.name, 16384)
  assert(failure(core, "create_map", { expected_project_id = project.id, definition = same_name }).code == "duplicate_map")
  local same_address = definition("Another synthetic map", original.definition.address)
  assert(failure(core, "create_map", { expected_project_id = project.id, definition = same_address }).code == "duplicate_map")
  equal(success(core, "get_map", { id = original.id }), original)
  assert(state.adds == 1)
  untouched(state, 1)
end)

run("expired and replayed requests never repeat a mutation", function()
  local core, state = fixture()
  local project = success(core, "get_project")
  local params = { expected_project_id = project.id, definition = definition() }
  local expired = request("create_map", params)
  expired.expires_at = os.time() - 1
  assert(response(core, expired).error.code == "expired_request")
  untouched(state)
  local once = request("create_map", params)
  assert(response(core, once).ok)
  assert(response(core, once).error.code == "duplicate_request")
  assert(state.adds == 1)
  untouched(state, 1)
end)

run("expiry during the final project check prevents native creation", function()
  local core, state = fixture()
  local project = success(core, "get_project")
  state.now, state.hash_reads, state.expire_on_hash_read = 1000, 0, 3
  local req = request("create_map", { expected_project_id = project.id, definition = definition() })
  req.expires_at = 1001
  local result = response(core, req)
  assert(not result.ok and result.error.code == "expired_request")
  assert(state.adds == 0 and state.sets == 0)
  untouched(state)
end)

run("a recoverable setter failure deletes only its temporary map", function()
  local core, state = fixture()
  local project = success(core, "get_project")
  local original = create(core, project, definition("Original synthetic map", 4096))
  state.fail_property = "DataOrg"
  assert(failure(core, "create_map", {
    expected_project_id = project.id, definition = definition("Rejected synthetic map", 16384),
  }).code == "native_error")
  assert(not core.halted and state.deletes == 1)
  equal(success(core, "get_map", { id = original.id }), original)
  untouched(state, 1)
end)

run("an unidentifiable partial creation halts all later operations", function()
  local core, state = fixture()
  local project = success(core, "get_project")
  state.fail_property = "Name"
  assert(failure(core, "create_map", { expected_project_id = project.id, definition = definition() }).code == "mutation_uncertain")
  assert(core.halted and state.adds == 1)
  local sets = state.sets
  assert(failure(core, "get_project").code == "bridge_halted")
  assert(failure(core, "create_map", { expected_project_id = project.id, definition = definition() }).code == "bridge_halted")
  assert(state.adds == 1 and state.sets == sets and state.deletes == 0)
  untouched(state, 1)
end)

run("rollback failure and native exceptions also halt uncertain creation", function()
  for _, mode in ipairs({ "delete", "add" }) do
    local core, state = fixture()
    local project = success(core, "get_project")
    if mode == "delete" then state.fail_property = "DataOrg"; state.delete_fails = true
    else state.add_throws = true end
    assert(failure(core, "create_map", { expected_project_id = project.id, definition = definition() }).code == "mutation_uncertain")
    assert(core.halted and state.adds == 1)
    untouched(state, 1)
  end
end)

run("native readback disagreement rolls back metadata creation", function()
  local core, state = fixture()
  local project = success(core, "get_project")
  state.override_property, state.override_value = "Feldwerte.Faktor", "99"
  assert(failure(core, "create_map", { expected_project_id = project.id, definition = definition() }).code == "verification_failed")
  assert(not core.halted and state.deletes == 1)
  untouched(state)
end)

run("unsupported native layouts and gaps are reported without reinterpretation", function()
  local cases = {
    { "Typ", "eZweiInv" }, { "DataOrg", "eFloatLoHi" },
    { "SkipBytes", "1" }, { "LineSkipBytes", "2" }, { "bKehrwert", "1" },
    { "Feldwerte.PreOffset", "1" }, { "StuetzX.DataSrc", "eUserdef" },
    { "StuetzX.SkipBytes", "1" }, { "StuetzY.bRueckwaerts", "1" },
    { "StuetzX.DataHeader", "2" },
  }
  for _, unsupported in ipairs(cases) do
    local core, state = fixture()
    local project = success(core, "get_project")
    local created = create(core, project, definition())
    state.maps[1][unsupported[1]] = unsupported[2]
    local sets = state.sets
    assert(failure(core, "get_map", { id = created.id }).code == "unsupported_map", unsupported[1])
    assert(failure(core, "list_maps", { offset = 0, limit = 10 }).code == "unsupported_map", unsupported[1])
    assert(state.sets == sets and state.adds == 1)
    untouched(state, 1)
  end
end)

run("multiple elements, displaced elements, and missing identity are unsupported", function()
  for _, mode in ipairs({ "multiple", "offset", "hash", "unsaved" }) do
    local core, state = fixture()
    if mode == "multiple" then state.ranges = "Eprom:0-1023;Processor:1024-2047"
    elseif mode == "offset" then state.element_offset = 4096
    elseif mode == "hash" then state.hash = ""
    else state.filename = "" end
    failure(core, "get_project")
    assert(state.adds == 0 and state.sets == 0)
    untouched(state)
  end
end)

run("unknown operation, parameters, and invalid pages are rejected", function()
  local core, state = fixture()
  assert(failure(core, "run_lua", { code = "return 1" }).code == "unknown_operation")
  assert(failure(core, "get_project", { save = true }).code == "invalid_argument")
  for _, limit in ipairs({ 0, 101 }) do
    assert(failure(core, "list_maps", { offset = 0, limit = limit }).code == "invalid_argument")
  end
  assert(failure(core, "get_map", { id = "map:0:0" }).code == "map_not_found")
  untouched(state)
end)

run("numeric request IDs are rejected before dispatch", function()
  local core, state = fixture()
  local malformed = request("get_project")
  malformed.id = 123
  local result = core:handle(malformed)
  assert(not result.ok and result.error.code == "protocol_error")
  assert(result.id == "invalid")
  assert(state.adds == 0 and state.sets == 0)
  untouched(state)
end)
