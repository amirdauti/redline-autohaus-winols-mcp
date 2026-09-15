local json = require('json')

local function rejects(text)
  local ok = pcall(json.decode, text)
  assert(not ok, 'accepted malformed JSON: ' .. text)
end

local definition = json.decode([[{"name":"Synthetic \u03bc table \ud83d\udd27","factor":0.03125,"offset":-40,"address":4294967295,"x_axis":null,"enabled":false,"maps":[],"properties":{}}]])
assert(definition.name == 'Synthetic ' .. string.char(206,188) .. ' table ' .. string.char(240,159,148,167))
assert(definition.factor == 0.03125 and definition.address == 4294967295)
assert(definition.enabled == false and definition.x_axis == json.null)
assert(json.is_array(definition.maps) and json.is_object(definition.properties))
local encoded = json.encode(definition)
local roundtrip = json.decode(encoded)
assert(roundtrip.name == definition.name and roundtrip.x_axis == json.null)
assert(encoded:find('"maps":%[%]') and encoded:find('"properties":{}'))
assert(json.decode('false') == false and json.decode('null') == json.null)
assert(json.decode(' -1.25e+2 \r\n') == -125)
assert(json.decode('"\\\"\\\\\\/\\b\\f\\n\\r\\t"') == '"\\/\b\f\n\r\t')

for _, invalid in ipairs({
  '', ' ', 'true false', 'truex', '+1', '01', '-01', '.1', '1.', '1e', '1e+',
  '1e999', 'NaN', 'Infinity', '{"x":1,"x":2}', '{"x":null,"x":2}',
  '{"x":1,}', '[1,]', '[,1]', '{x:1}', '"\\q"', '"\\u123"',
  '"\\ud800"', '"\\udc00"', '"\\ud800\\u0041"', '"unterminated',
  '"' .. string.char(0) .. '"', '"' .. string.char(192,128) .. '"',
  '"' .. string.char(237,160,128) .. '"', '"' .. string.char(244,144,128,128) .. '"',
  string.rep('[', 34) .. '0' .. string.rep(']', 34),
}) do rejects(invalid) end
assert(not pcall(json.decode, '"123456"', 4))

for _, value in ipairs({math.huge, -math.huge, 0/0}) do
  assert(not pcall(json.encode, value), 'encoded nonfinite number')
end
local cycle = {}; cycle.self = cycle
assert(not pcall(json.encode, cycle))
assert(not pcall(json.encode, json.array({[1]='a', [3]='c'})))
assert(not pcall(json.encode, function() end))
assert(not pcall(json.text_length, string.char(127), true))
assert(json.text_length(definition.name, true) == 19)

-- Caller strings remain data, even when they resemble Lua source.
local text = 'os.execute("do not execute"); return {}'
assert(json.decode(json.encode(text)) == text)
