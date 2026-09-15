local json = require('json')
local mailbox = require('mailbox')
local function path(name) return TEST_TEMP_DIR .. '/' .. name end
local function write(name, contents)
  local file = assert(io.open(path(name), 'wb'))
  assert(file:write(contents)); assert(file:close())
end
local function read(name)
  local file = assert(io.open(path(name), 'rb'))
  local contents = file:read('*a'); file:close(); return contents
end
local function remove(name) assert(os.remove(path(name))) end
local calls = 0
local adapter = {
  handle = function(_, request)
    calls = calls + 1
    assert(mailbox.exists(path('processing.json')))
    assert(not mailbox.exists(path('request.json')))
    return {protocol_version=1, id=request.id, ok=true, result={echo=request.params}}
  end,
}
local connection = mailbox.new(TEST_TEMP_DIR, adapter)
assert(not connection:step() and calls == 0)
write('request.tmp', '{')
assert(not connection:step() and calls == 0, 'read a partial request')
remove('request.tmp')
write('request.json', json.encode({protocol_version=1,id='one',params={name='Synthetic'}}))
assert(connection:step() and calls == 1)
assert(not mailbox.exists(path('processing.json')))
assert(not mailbox.exists(path('response.tmp')))
local response = json.decode(read('response.json'))
assert(response.id == 'one' and response.result.echo.name == 'Synthetic')
assert(not connection:step() and calls == 1, 'replayed a completed request')
assert(not pcall(mailbox.new, TEST_TEMP_DIR, adapter), 'accepted stale completed response')
remove('response.json')

-- Invalid data is retained without dispatch, and the same instance cannot reuse it.
write('request.json', '{"invalid":')
assert(not pcall(connection.step, connection) and calls == 1)
assert(connection.halted and mailbox.exists(path('processing.json')))
assert(not pcall(connection.step, connection) and calls == 1)
assert(not pcall(mailbox.new, TEST_TEMP_DIR, adapter))
remove('processing.json')

connection = mailbox.new(TEST_TEMP_DIR, adapter)
write('request.json', string.rep(' ', 1048577))
assert(not pcall(connection.step, connection) and calls == 1)
assert(connection.halted and mailbox.exists(path('processing.json')))
remove('processing.json')

-- An uncertain adapter still publishes its error once, then stops.
local halted_adapter = {halted=false}
function halted_adapter:handle(request)
  self.halted = true
  return {protocol_version=1,id=request.id,ok=false,error={code='mutation_uncertain',message='Synthetic failure'}}
end
connection = mailbox.new(TEST_TEMP_DIR, halted_adapter)
write('request.json', '{"id":"two"}')
assert(connection:step())
assert(json.decode(read('response.json')).error.code == 'mutation_uncertain')
assert(not pcall(connection.step, connection))
remove('response.json')
