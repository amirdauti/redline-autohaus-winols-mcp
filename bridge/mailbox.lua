-- Atomic, fixed-name file handoff. A request is never executed as Lua code.
local json = require("json")
local mailbox = {}
local pending = { "request.tmp", "request.json", "processing.json", "response.tmp", "response.json" }
local function exists(path)
  local file = io.open(path, "rb")
  if not file then return false end
  file:close()
  return true
end
mailbox.exists = exists
local function read(path, maximum)
  local file = assert(io.open(path, "rb"))
  local bytes = file:read(maximum + 1) or ""
  assert(file:close())
  if #bytes > maximum then error("Mailbox request exceeds 1 MiB", 0) end
  return bytes
end
function mailbox.new(directory, adapter)
  assert(type(directory) == "string" and directory ~= "", "mailbox directory required")
  local separator = directory:find("\\", 1, true) and "\\" or "/"
  local function path(name) return directory .. separator .. name end
  for _, name in ipairs(pending) do
    if exists(path(name)) then error("Unfinished mailbox file " .. name .. "; inspect WinOLS and follow recovery instructions", 0) end
  end
  local self = { directory=directory, adapter=adapter, halted=false }
  function self:step()
    if self.halted or adapter.halted then error("Bridge halted; manual recovery required", 0) end
    if exists(path("processing.json")) or exists(path("response.tmp")) then
      self.halted = true
      error("Unfinished processing/response file; refusing to replay", 0)
    end
    -- The client removes each complete response before sending another request.
    if exists(path("response.json")) then return false end
    if not exists(path("request.json")) then return false end
    -- Any exception below stops reuse and leaves evidence for manual recovery.
    self.halted = true
    assert(os.rename(path("request.json"), path("processing.json")))
    local bytes = read(path("processing.json"), 1048576)
    local valid, request = pcall(json.decode, bytes)
    if not valid then error("Invalid mailbox JSON; request retained for manual recovery", 0) end
    local response = adapter:handle(request)
    local encoded = json.encode(response)
    local output = assert(io.open(path("response.tmp"), "wb"))
    assert(output:write(encoded))
    assert(output:flush())
    assert(output:close())
    assert(os.remove(path("processing.json")))
    assert(os.rename(path("response.tmp"), path("response.json")))
    self.halted = adapter.halted or false
    return true
  end
  return self
end
return mailbox
