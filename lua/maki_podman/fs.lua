local worker = require("maki_podman.worker_source")
local M = {}
local MAX_BYTES = 64 * 1024 * 1024
local FRAME_BYTES = 128 * 1024

local function checked(value, err)
  if value == nil then error(tostring(err or "container filesystem operation failed"), 0) end
  return value
end

local function host_job(args, timeout)
  local job, err = maki.fn.jobstart(args, { cwd = "/" })
  if not job then return nil, err end
  local result, wait_err = maki.fn.jobwait(job, timeout)
  if not result then maki.fn.jobstop(job); return nil, wait_err end
  if result.exit_code ~= 0 then return nil, result.stderr or "transport process failed" end
  return result.stdout
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
  local timeout = options.operation_timeout_ms or 120000
  local lua = options.lua or "lua5.4"
  assert(type(lua) == "string" and lua ~= "" and not lua:find("\0", 1, true), "lua must name the container Lua executable")
  local factory = {}

  function factory.for_context(ctx)
    local target, staging, remote, home, initialized
    local opening = maki.async.semaphore(1)
    local sequence, closed = 0, false
    local seen, expected = {}, {}
    local fs = {}

    local function run(args, on_stdout)
      local job, err, cancel = manager.exec_prepared(target, args, {
        tail = 5, max_line_bytes = FRAME_BYTES, on_stdout = on_stdout,
      }, ctx)
      checked(job, err)
      local result, wait_err = maki.fn.jobwait(job, timeout)
      if not result then
        if cancel then cancel() end
        maki.fn.jobstop(job)
        error(tostring(wait_err), 0)
      end
      if result.exit_code ~= 0 then
        error("container filesystem helper failed (exit " .. tostring(result.exit_code) .. "): " .. (result.stderr or "")
          .. "; the image needs Lua 5.4, LuaFileSystem, ripgrep and GNU coreutils", 0)
      end
      return result
    end

    local function cleanup()
      if remote and target then manager.cleanup(target, remote) end
      if staging then
        maki.fn.jobstart({ "rm", "-rf", "--", staging }, { cwd = "/", scope = "plugin", tail = 0 })
      end
    end

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
        staging = checked(host_job({ "mktemp", "-d", "/tmp/maki-podman-files.XXXXXXXXXX" }, timeout)):match("^%s*(.-)%s*$")
        assert(staging:match("^/tmp/maki%-podman%-files%.[A-Za-z0-9]+$"), "invalid private transfer directory")
        remote = staging .. "-remote"
        maki.async.on_cancel(cleanup)
        checked(maki.fs.write(staging .. "/worker.lua", worker))
        run({ "/bin/sh", "-c", 'umask 077; mkdir -- "$1"', "maki-files", remote })
        checked(manager.copy_in(target, staging .. "/worker.lua", remote .. "/worker.lua"))
        initialized = true
      end)
      release()
      if not ok then cleanup(); error(err, 0) end
    end

    local function rpc(request)
      open()
      if ctx:cancelled() then error("container file call was cancelled", 0) end
      sequence = sequence + 1
      local name = "request-" .. sequence .. ".json"
      local local_path, remote_path = staging .. "/" .. name, remote .. "/" .. name
      checked(maki.fs.write(local_path, maki.json.encode(request)))
      checked(manager.copy_in(target, local_path, remote_path))
      local chunks, lines, line_chunks, entries, entry_chunks = {}, {}, {}, {}, {}
      local terminal, protocol_error, bytes = nil, nil, 0
      local function decode64(encoded)
        local value, err = maki.base64.decode(encoded)
        if not value then protocol_error = "invalid filesystem response: " .. tostring(err); return "" end
        bytes = bytes + #value
        if bytes > MAX_BYTES + 1024 * 1024 then protocol_error = "container response exceeds the 64 MiB transfer limit" end
        return value
      end
      local function accept(_, line, _, actual_bytes)
        if protocol_error then return end
        if actual_bytes and actual_bytes > #line then protocol_error = "container filesystem response was truncated"; return end
        local frame, err = maki.json.decode(line)
        if type(frame) ~= "table" or terminal then protocol_error = "invalid filesystem response: " .. tostring(err or "unexpected frame"); return end
        if frame.chunk then chunks[#chunks + 1] = decode64(frame.chunk)
        elseif frame.line_chunk then line_chunks[#line_chunks + 1] = decode64(frame.line_chunk)
        elseif frame.line_end then lines[#lines + 1] = table.concat(line_chunks); line_chunks = {}
        elseif frame.entry_chunk then entry_chunks[#entry_chunks + 1] = decode64(frame.entry_chunk)
        elseif frame.entry_end then
          local entry, decode_err = maki.json.decode(table.concat(entry_chunks))
          if entry == nil then protocol_error = "invalid filesystem entry: " .. tostring(decode_err) else entries[#entries + 1] = entry end
          entry_chunks = {}
        elseif frame.entry ~= nil then
          bytes = bytes + #line
          if bytes > MAX_BYTES + 1024 * 1024 then protocol_error = "container response exceeds the 64 MiB transfer limit" end
          entries[#entries + 1] = frame.entry
        elseif frame.ok ~= nil then terminal = frame
        else protocol_error = "unknown filesystem response frame" end
      end
      local ok, result = pcall(run, { lua, remote .. "/worker.lua", remote_path }, accept)
      maki.fs.rm(local_path, { force = true })
      if not ok then error(result, 0) end
      if protocol_error then error(protocol_error, 0) end
      if not terminal or #line_chunks > 0 or #entry_chunks > 0 then error("incomplete container filesystem response", 0) end
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
      if home == nil then
        local env = checked(safe({ op = "context" }))
        home = type(env.home) == "string" and env.home or false
      end
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
      return table.concat(parts, "/"):gsub("/+", "/")
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
      cleanup()
    end
    return fs
  end
  return factory
end

return M
