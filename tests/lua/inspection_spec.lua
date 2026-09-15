-- Read-only original/current byte inspection, using EVC numeric Boolean arguments.
local json = require("json")
local next_id = 0
local function fixture()
  local f = require("native_fixture").new()
  f.api.eVerPropName = 9001
  f.state.window, f.state.version = 1234, "Synthetic changed version"
  f.state.byte_reads = 0
  f.api.windowGetActive = function() return f.state.window end
  f.api.versionGetProperty = function(kind)
    assert(kind == f.api.eVerPropName)
    return f.state.version
  end
  f.api.projectGetAt = function(address, datatype, count, original)
    assert(datatype == f.api.eByte)
    assert(original == 1 or original == 0, "projectGetAt requires EVC numeric TRUE/FALSE, not Lua booleans")
    f.state.byte_reads = f.state.byte_reads + 1
    if f.state.switch_version then f.state.version = "Other version" end
    if f.state.switch_window then f.state.window = 1235 end
    if f.state.switch_project then f.state.filename = "C:\\synthetic\\other.ols" end
    if f.state.bad_data ~= nil and (not f.state.bad_on_read or f.state.byte_reads == f.state.bad_on_read) then
      return f.state.bad_data
    end
    local values = {}
    for i = 1, count do values[i] = (address + i - 1 + (original == 1 and 0 or 5)) % 256 end
    if count == 1 then return values[1] end
    return values
  end
  return f
end
local function call(f, params)
  next_id = next_id + 1
  local result = f.core:handle({protocol_version=1,id="read-" .. next_id,operation="read_bytes",
    params=params,expires_at=os.time()+60})
  json.encode(result)
  assert(f.state.adds == 0 and f.state.sets == 0 and f.state.binary_writes == 0 and f.state.saves == 0)
  return result
end
local function params(f, address, count)
  return {expected_project_id="winols:synthetic-session:" .. f.state.filename:lower() .. ":" .. f.state.hash,
    address=address or 250,count=count or 8}
end
for _, count in ipairs({1,2,4,8,4096}) do
  local f = fixture()
  local p = params(f, 250, count)
  local r = call(f, p)
  assert(r.ok and r.result.project_id == p.expected_project_id)
  assert(r.result.address == 250 and r.result.window_id == "1234" and r.result.version_name == f.state.version)
  assert(#r.result.original_bytes == count and #r.result.current_bytes == count)
  for i = 1, count do
    assert(r.result.original_bytes[i] == (250 + i - 1) % 256)
    assert(r.result.current_bytes[i] == (255 + i - 1) % 256)
  end
  assert(f.state.byte_reads == 2)
end
do
  local f = fixture()
  local r = call(f, params(f, 1048575, 1))
  assert(r.ok and r.result.original_bytes[1] == 255 and r.result.current_bytes[1] == 4)
end
for _, pair in ipairs({{1048576,1},{1048575,2},{0,0},{0,4097},{-1,1},{0,1.5}}) do
  local f = fixture()
  local r = call(f, params(f, pair[1], pair[2]))
  assert(not r.ok and r.error.code == "invalid_argument" and f.state.byte_reads == 0)
end
do
  local f = fixture()
  local p = params(f)
  p.expected_project_id = "different-project"
  local r = call(f,p)
  assert(not r.ok and r.error.code == "project_changed" and f.state.byte_reads == 0)
end
for _, flag in ipairs({"switch_version","switch_window","switch_project"}) do
  local f = fixture()
  f.state[flag] = true
  local r = call(f, params(f))
  assert(not r.ok and (r.error.code == "version_changed" or r.error.code == "project_changed"))
end
for _, bad in ipairs({-99999,256,"0",false}) do
  local f = fixture()
  f.state.bad_data = bad
  assert(not call(f, params(f,0,1)).ok)
end
for _, failed_read in ipairs({1,2}) do
  local f = fixture()
  f.state.bad_data = {1,2}
  f.state.bad_on_read = failed_read
  local r = call(f, params(f,0,8))
  assert(not r.ok and r.result == nil and f.state.byte_reads == failed_read)
end
