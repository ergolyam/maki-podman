local M = {}
local MAX_BYTES = 64 * 1024 * 1024

local function checked(value, err)
  if value == nil then error(tostring(err or "container filesystem operation failed"), 0) end
  return value
end

local function dirname(path)
  if path == "/" then return nil end
  local parent = path:gsub("/+$", ""):match("^(.*)/[^/]*$")
  return parent == "" and "/" or parent
end

local function version(value)
  return { canonical = value.canonical, fingerprint = value.fingerprint, exists = value.exists ~= false }
end

function M.new(manager, options)
  options = options or {}
  local transport = require("maki_podman.transport").new(manager, options)
  local factory = {}

  function factory.for_context(ctx)
    local target, channel, home, initialized
    local opening = maki.async.semaphore(1)
    local closed = false
    local seen, expected = {}, {}
    local fs = {}

    local function open()
      if closed or ctx:cancelled() then error("container file call is closed or cancelled", 0) end
      if initialized then return end
      local permit = opening:acquire()
      local held = true
      local function release() if held then held = false; permit:release() end end
      maki.async.on_cancel(release)
      local ok, err = pcall(function()
        if initialized then return end
        target = checked(manager.prepare(ctx))
        channel = checked(transport.open(target, ctx))
        home = type(channel.context.home) == "string" and channel.context.home or false
        initialized = true
      end)
      release()
      if not ok then error(err, 0) end
    end

    local function rpc(request)
      open()
      if ctx:cancelled() then error("container file call was cancelled", 0) end
      local chunks, lines, line_chunks, entries, entry_chunks = {}, {}, {}, {}, {}
      local terminal, bytes = nil, 0
      local function count(size)
        bytes = bytes + size
        if bytes > MAX_BYTES + 1024 * 1024 then error("container response exceeds the 64 MiB transfer limit", 0) end
      end
      local function decode64(encoded)
        local value, err = maki.base64.decode(encoded)
        if not value then error("invalid filesystem response: " .. tostring(err), 0) end
        count(#value)
        return value
      end
      local function accept(frame, encoded_bytes)
        if frame.chunk then chunks[#chunks + 1] = decode64(frame.chunk)
        elseif frame.line_chunk then line_chunks[#line_chunks + 1] = decode64(frame.line_chunk)
        elseif frame.line_end then count(24); lines[#lines + 1] = table.concat(line_chunks); line_chunks = {}
        elseif frame.entry_chunk then entry_chunks[#entry_chunks + 1] = decode64(frame.entry_chunk)
        elseif frame.entry_end then
          local entry, decode_err = maki.json.decode(table.concat(entry_chunks))
          if entry == nil then error("invalid filesystem entry: " .. tostring(decode_err), 0) end
          entries[#entries + 1] = entry
          entry_chunks = {}
        elseif frame.entry ~= nil then
          count(encoded_bytes)
          entries[#entries + 1] = frame.entry
        else error("unknown filesystem response frame", 0) end
      end
      local transport_err
      terminal, transport_err = channel.rpc(request, accept, ctx)
      if not terminal then error(tostring(transport_err), 0) end
      if #line_chunks > 0 or #entry_chunks > 0 then
        channel.close("incomplete container filesystem response")
        error("incomplete container filesystem response", 0)
      end
      if not terminal.ok then error(tostring(terminal.error), 0) end
      local value = terminal.value
      if request.op == "read" or request.op == "read_bytes" then
        seen[request.path] = version(value)
        return table.concat(chunks)
      elseif request.op == "read_lines" then
        value.lines = lines
        seen[request.path] = version(value)
      elseif request.op == "glob" or request.op == "dir" or request.op == "grep" then
        for _, entry in ipairs(entries) do
          if type(entry) == "table" and entry.path and entry.fingerprint then seen[entry.path] = version(entry) end
        end
        return entries
      end
      return value
    end

    local function safe(request)
      local ok, value = pcall(rpc, request)
      if not ok then return nil, tostring(value) end
      return value
    end

    function fs.state()
      open()
      return { id = target.id, sid = target.sid, cwd = target.cwd, home = home or nil, resources = target.resources or {} }
    end
    function fs.abspath(path)
      assert(type(path) == "string" and not path:find("\0", 1, true), "path must be a string without NUL bytes")
      local state = fs.state()
      if path == "~" or path:sub(1, 2) == "~/" then
        assert(state.home, "container HOME is unavailable")
        return state.home .. path:sub(2)
      end
      return path:sub(1, 1) == "/" and path or state.cwd .. "/" .. path
    end
    fs.dirname = dirname
    function fs.basename(path) return path:gsub("/+$", ""):match("([^/]+)$") end
    function fs.joinpath(...)
      local parts = { ... }
      return (table.concat(parts, "/"):gsub("/+", "/"))
    end
    function fs.normalize(path)
      local parts = {}
      for part in fs.abspath(path):gmatch("[^/]+") do
        if part == ".." then parts[#parts] = nil elseif part ~= "." then parts[#parts + 1] = part end
      end
      return "/" .. table.concat(parts, "/")
    end
    function fs.parents(path)
      local out, parent = {}, dirname(fs.abspath(path))
      while parent do out[#out + 1] = parent; parent = dirname(parent) end
      return out
    end
    function fs.metadata(path)
      local value, err = safe({ op = "metadata", path = fs.abspath(path) })
      return type(value) == "table" and value or nil, err
    end
    function fs.version(path) return safe({ op = "version", path = fs.abspath(path) }) end
    function fs.observed(path) return seen[fs.abspath(path)] end
    function fs.expect(path, version) expected[fs.abspath(path)] = version end
    function fs.read(path, opts) return safe({ op = "read", path = fs.abspath(path), opts = opts }) end
    function fs.read_bytes(path, opts)
      local value, err = safe({ op = "read_bytes", path = fs.abspath(path), opts = opts })
      return value and buffer.fromstring(value) or nil, err
    end
    function fs.read_lines(path, opts) return safe({ op = "read_lines", path = fs.abspath(path), opts = opts }) end
    for _, op in ipairs({ "write", "append" }) do
      fs[op] = function(path, content)
        if #content > MAX_BYTES then return nil, "file content exceeds the 64 MiB transfer limit" end
        path = fs.abspath(path)
        local result, err = safe({ op = op, path = path, content_b64 = maki.base64.encode(content), expected = expected[path] })
        if type(result) == "table" then seen[path] = result; expected[path] = result end
        return result and true or nil, err
      end
    end
    function fs.mkdir(path, opts) return safe({ op = "mkdir", path = fs.abspath(path), opts = opts }) end
    function fs.rm(path, opts)
      path = fs.abspath(path)
      return safe({ op = "rm", path = path, opts = opts, expected = expected[path] })
    end
    function fs.dir(path, opts) return safe({ op = "dir", path = fs.abspath(path), opts = opts }) end
    function fs.glob(pattern, opts)
      opts = opts or {}
      return safe({ op = "glob", path = fs.abspath(opts.path or "."), pattern = pattern, opts = opts })
    end
    function fs.grep(pattern, opts)
      opts = opts or {}
      return safe({ op = "grep", path = fs.abspath(opts.path or "."), pattern = pattern, opts = opts })
    end
    function fs.close()
      if closed then return end
      closed = true
    end
    return fs
  end
  return factory
end

return M
