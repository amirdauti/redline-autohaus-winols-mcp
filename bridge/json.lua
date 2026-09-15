-- Small JSON codec for mailbox data. No load(), loadstring(), or code evaluation.
-- Original project code, licensed under the repository MIT license.
local json = {}
local array_mt, object_mt = {}, {}
json.null = setmetatable({}, { __tostring = function() return "null" end })
function json.array(t) return setmetatable(t or {}, array_mt) end
function json.object(t) return setmetatable(t or {}, object_mt) end
function json.is_array(t) return type(t) == "table" and getmetatable(t) == array_mt end
function json.is_object(t) return type(t) == "table" and getmetatable(t) == object_mt end

local function utf8(code)
  if code < 128 then return string.char(code) end
  if code < 2048 then return string.char(192 + math.floor(code / 64), 128 + code % 64) end
  if code < 65536 then
    return string.char(224 + math.floor(code / 4096), 128 + math.floor(code / 64) % 64, 128 + code % 64)
  end
  return string.char(240 + math.floor(code / 262144), 128 + math.floor(code / 4096) % 64,
    128 + math.floor(code / 64) % 64, 128 + code % 64)
end

-- Validate UTF-8, count characters, and optionally reject Unicode control characters.
function json.text_length(s, reject_controls)
  if type(s) ~= "string" then error("expected string", 0) end
  local i, count = 1, 0
  while i <= #s do
    local b, code, n = s:byte(i), 0, 1
    if b < 128 then code = b
    elseif b >= 194 and b <= 223 then code, n = b - 192, 2
    elseif b >= 224 and b <= 239 then code, n = b - 224, 3
    elseif b >= 240 and b <= 244 then code, n = b - 240, 4
    else error("invalid UTF-8", 0) end
    for j = 1, n - 1 do
      local c = s:byte(i + j)
      if not c or c < 128 or c > 191 then error("invalid UTF-8", 0) end
      code = code * 64 + c - 128
    end
    if (n == 2 and code < 128) or (n == 3 and code < 2048) or (n == 4 and code < 65536)
      or code > 1114111 or (code >= 55296 and code <= 57343) then error("invalid UTF-8", 0) end
    if reject_controls and (code < 32 or (code >= 127 and code <= 159)) then error("control character", 0) end
    count, i = count + 1, i + n
  end
  return count
end

function json.decode(input, max_bytes)
  if type(input) ~= "string" or #input > (max_bytes or 1048576) then error("JSON exceeds size limit", 0) end
  local pos, length = 1, #input
  local function fail(message) error(message .. " at byte " .. pos, 0) end
  local function space()
    while input:sub(pos, pos):match("[ \t\r\n]") do pos = pos + 1 end
  end
  local function hex4()
    local value = input:sub(pos, pos + 3)
    if #value ~= 4 or not value:match("^%x%x%x%x$") then fail("invalid Unicode escape") end
    pos = pos + 4
    return tonumber(value, 16)
  end
  local function string_value()
    pos = pos + 1
    local parts, start = {}, pos
    while pos <= length do
      local b = input:byte(pos)
      if b == 34 then
        parts[#parts + 1] = input:sub(start, pos - 1)
        pos = pos + 1
        local s = table.concat(parts)
        json.text_length(s)
        return s
      elseif b == 92 then
        parts[#parts + 1] = input:sub(start, pos - 1)
        pos = pos + 1
        local escape = input:sub(pos, pos)
        local simple = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
        if simple[escape] then parts[#parts + 1], pos = simple[escape], pos + 1
        elseif escape == "u" then
          pos = pos + 1
          local code = hex4()
          if code >= 55296 and code <= 56319 then
            if input:sub(pos, pos + 1) ~= "\\u" then fail("unpaired Unicode surrogate") end
            pos = pos + 2
            local low = hex4()
            if low < 56320 or low > 57343 then fail("unpaired Unicode surrogate") end
            code = 65536 + (code - 55296) * 1024 + low - 56320
          elseif code >= 56320 and code <= 57343 then fail("unpaired Unicode surrogate") end
          parts[#parts + 1] = utf8(code)
        else fail("invalid string escape") end
        start = pos
      elseif b < 32 then fail("unescaped control character")
      else pos = pos + 1 end
    end
    fail("unterminated string")
  end
  local value
  value = function(depth)
    if depth > 32 then fail("JSON nesting exceeds 32") end
    space()
    local c = input:sub(pos, pos)
    if c == '"' then return string_value() end
    if c == "{" or c == "[" then
      local object = c == "{"
      local result, seen = object and json.object() or json.array(), {}
      local close = object and "}" or "]"
      pos = pos + 1
      space()
      if input:sub(pos, pos) == close then pos = pos + 1; return result end
      while true do
        local key = #result + 1
        if object then
          if input:sub(pos, pos) ~= '"' then fail("expected object key") end
          key = string_value()
          if seen[key] then fail("duplicate object key") end
          seen[key] = true
          space()
          if input:sub(pos, pos) ~= ":" then fail("expected colon") end
          pos = pos + 1
        end
        result[key] = value(depth + 1)
        space()
        local delimiter = input:sub(pos, pos)
        pos = pos + 1
        if delimiter == close then return result end
        if delimiter ~= "," then fail("expected comma or closing delimiter") end
        space()
      end
    end
    for literal, result in pairs({ ["true"] = true, ["false"] = false, ["null"] = json.null }) do
      if input:sub(pos, pos + #literal - 1) == literal then pos = pos + #literal; return result end
    end
    local start = pos
    if c == "-" then pos = pos + 1 end
    c = input:sub(pos, pos)
    if c == "0" then pos = pos + 1
    elseif c:match("[1-9]") then repeat pos = pos + 1 until not input:sub(pos, pos):match("%d")
    else fail("expected JSON value") end
    if input:sub(pos, pos) == "." then
      pos = pos + 1
      if not input:sub(pos, pos):match("%d") then fail("expected fractional digit") end
      repeat pos = pos + 1 until not input:sub(pos, pos):match("%d")
    end
    if input:sub(pos, pos):match("[eE]") then
      pos = pos + 1
      if input:sub(pos, pos):match("[+-]") then pos = pos + 1 end
      if not input:sub(pos, pos):match("%d") then fail("expected exponent digit") end
      repeat pos = pos + 1 until not input:sub(pos, pos):match("%d")
    end
    local number = tonumber(input:sub(start, pos - 1))
    if not number or number ~= number or number == math.huge or number == -math.huge then fail("nonfinite number") end
    return number
  end
  local result = value(0)
  space()
  if pos <= length then fail("trailing JSON content") end
  return result
end

function json.encode(input)
  local seen = {}
  local function quote(s)
    json.text_length(s)
    return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
      if c == '"' then return '\\"' end
      if c == '\\' then return '\\\\' end
      return string.format("\\u%04x", c:byte())
    end) .. '"'
  end
  local encode
  encode = function(value, depth)
    if depth > 32 then error("JSON nesting exceeds 32", 0) end
    if value == json.null then return "null" end
    if type(value) == "boolean" then return value and "true" or "false" end
    if type(value) == "string" then return quote(value) end
    if type(value) == "number" then
      if value ~= value or value == math.huge or value == -math.huge then error("nonfinite number", 0) end
      return (string.format("%.17g", value):gsub(",", "."))
    end
    if type(value) ~= "table" or seen[value] then error("invalid JSON value or cycle", 0) end
    seen[value] = true
    local parts = {}
    if json.is_array(value) then
      for i, item in ipairs(value) do parts[i] = encode(item, depth + 1) end
      for k in pairs(value) do
        if type(k) ~= "number" or k < 1 or k > #parts or k % 1 ~= 0 then error("invalid array key", 0) end
      end
      seen[value] = nil
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do
      if type(key) ~= "string" then error("nonstring object key", 0) end
      keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do parts[#parts + 1] = quote(key) .. ":" .. encode(value[key], depth + 1) end
    seen[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
  end
  local result = encode(input, 0)
  if #result > 1048576 then error("JSON exceeds size limit", 0) end
  return result
end
return json
