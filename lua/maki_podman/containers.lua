local process = require("maki_podman.process")

-- Keep the original labels so the renamed plugin can reuse existing containers.
local OWNER = "io.maki.podman-bash.owner"
local SESSION = "io.maki.podman-bash.session"
local SPEC = "io.maki.podman-bash.spec"
local KEEPALIVE = [[trap 'exit 0' TERM INT
while :; do sleep 3600 & wait "$!"; done]]
local SHUTDOWN_RESERVE_MS = 100
local WORKER_PORT = 39173

local M = {}

local function text(value, name)
  assert(type(value) == "string" and value ~= "" and not value:find("\0", 1, true), name .. " must be a nonempty string without NUL bytes")
  return value
end

local function positive(value, name)
  assert(type(value) == "number" and value >= 1 and value % 1 == 0, name .. " must be a positive integer")
  return value
end

local function copy(value)
  local result = {}
  for key, item in pairs(value) do
    result[key] = item
  end
  return result
end

function M.new(options)
  options = options or {}
  local opts = {
    podman = text(options.podman or "podman", "podman"),
    image = text(options.image or "docker.io/alpine:latest", "image"),
    shell = text(options.shell or "/bin/sh", "shell"),
    volume_options = options.volume_options == nil and "z" or options.volume_options,
    operation_timeout_ms = positive(options.operation_timeout_ms or 120000, "operation_timeout_ms"),
    remove_on_session_end = options.remove_on_session_end == true,
  }
  assert(opts.shell:sub(1, 1) == "/", "shell must be an absolute path inside the container")
  assert(opts.volume_options == "z" or opts.volume_options == "Z" or opts.volume_options == "", "volume_options must be 'z', 'Z', or ''")
  assert(opts.image:sub(1, 1) ~= "-", "image must not start with '-'")

  local states = {}
  local ending = false
  local sequence = 0
  local instance = tostring(os.time()) .. "-" .. tostring(math.random(1, 2147483646))
  local manager = {}

  local function invalidate(state, reason)
    local worker = state.worker
    state.worker = nil
    if worker then worker.close(reason or "container changed") end
  end

  local function warn(message)
    maki.log.warn("maki-podman: " .. tostring(message))
  end

  local function argv(args)
    local command = { opts.podman }
    for _, arg in ipairs(args) do
      command[#command + 1] = arg
    end
    return command
  end

  local function run(args, timeout)
    local job, err = maki.fn.jobstart(argv(args), { cwd = "/" })
    if not job then
      return nil, "could not start Podman: " .. tostring(err)
    end
    local result, wait_err = maki.fn.jobwait(job, timeout or opts.operation_timeout_ms)
    if not result then
      maki.fn.jobstop(job)
      return nil, "Podman " .. args[1] .. " did not finish: " .. tostring(wait_err)
    end
    return result
  end

  local function failure(args, result)
    local detail = (result.stderr or ""):match("^%s*(.-)%s*$")
    if detail == "" then
      detail = (result.stdout or ""):match("^%s*(.-)%s*$")
    end
    return "Podman " .. args[1] .. " failed (exit " .. tostring(result.exit_code) .. ")"
      .. (detail ~= "" and ": " .. detail or "")
  end

  local function checked(args, timeout)
    local result, err = run(args, timeout)
    if not result then
      return nil, err
    end
    if result.exit_code ~= 0 then
      return nil, failure(args, result)
    end
    return result
  end

  local function state_for(sid)
    if type(sid) ~= "string" or not sid:match("^[A-Za-z0-9_-]+$") or #sid > 128 then
      return nil, "no valid Maki chat ID; refusing to execute a host command"
    end
    if not states[sid] then
      states[sid] = { name = "maki-" .. sid, gate = maki.async.semaphore(1), closed = false }
    end
    return states[sid]
  end

  local function with_lock(state, fn)
    local permit = state.gate:acquire()
    local held = true
    local function release()
      if held then
        held = false
        permit:release()
      end
    end
    maki.async.on_cancel(release)
    local ok, value, err = pcall(fn)
    release()
    if not ok then
      return nil, tostring(value)
    end
    return value, err
  end

  local function session_cwd(sid)
    local session, err = maki.session.read({ session = sid })
    if not session then
      return nil, "cannot read chat working directory: " .. tostring(err)
    end
    local cwd = session.cwd
    if type(cwd) ~= "string" or cwd:sub(1, 1) ~= "/" or cwd:find("\0", 1, true) then
      return nil, "the chat needs an absolute POSIX working directory"
    end
    if cwd:find(":", 1, true) then
      return nil, "Podman's volume syntax cannot represent a working directory containing ':'"
    end
    return cwd
  end

  local function inspect(target)
    local result, err = checked({ "container", "inspect", target })
    if not result then
      return nil, err
    end
    local decoded, decode_err = maki.json.decode(result.stdout)
    local info = type(decoded) == "table" and decoded[1]
    if type(info) ~= "table" or type(info.Id) ~= "string" or type(info.State) ~= "table" then
      return nil, "invalid Podman container inspection: " .. tostring(decode_err or "missing Id/State")
    end
    return info
  end

  local function find(state)
    local args = { "container", "exists", state.name }
    local result, err = run(args)
    if not result then
      return nil, err
    end
    if result.exit_code == 1 then
      state.id = nil
      return false
    end
    if result.exit_code ~= 0 then
      return nil, failure(args, result)
    end
    return inspect(state.name)
  end

  local function owned(info, sid)
    local labels = info.Config and info.Config.Labels or {}
    return labels[OWNER] == "1" and labels[SESSION] == sid
  end

  local function specification(cwd, resources)
    return maki.json.encode({ version = 2, cwd = cwd, image = opts.image, shell = opts.shell,
      volume_options = opts.volume_options, mounts = resources and resources.mounts })
  end

  local function worker_port(info)
    local ports = info.NetworkSettings and info.NetworkSettings.Ports or {}
    local bindings = ports[tostring(WORKER_PORT) .. "/tcp"]
    if type(bindings) ~= "table" or #bindings ~= 1 then return nil end
    local binding = bindings[1]
    local port = tonumber(binding.HostPort)
    if binding.HostIp ~= "127.0.0.1" or not port or port < 1 or port > 65535 or port % 1 ~= 0 then return nil end
    return port
  end

  local function matches(info, cwd, spec, resources)
    if not info.Config or not info.Config.Labels or info.Config.Labels[SPEC] ~= spec then
      return false
    end
    local required = { { source = cwd, destination = cwd, readonly = false } }
    for _, mount in ipairs(resources and resources.mounts or {}) do required[#required + 1] = mount end
    for _, want in ipairs(required) do
      local found = false
      for _, mount in ipairs(info.Mounts or {}) do
        if mount.Type == "bind" and mount.Source == want.source and mount.Destination == want.destination
          and mount.RW == not want.readonly then found = true; break end
      end
      if not found then return false end
    end
    return true
  end

  local function ensure(state, sid, cwd)
    if ending or state.closed then
      return nil, "this chat is closing; no command was started"
    end
    local resources = options.resources and options.resources(sid, cwd) or nil
    state.resources = resources
    local spec = specification(cwd, resources)
    -- A live worker is the readiness proof; this path performs no Podman calls.
    if state.id and state.cwd == cwd and state.spec == spec and state.worker and state.worker.alive() then
      return state.id
    end
    invalidate(state, "container readiness changed")
    local info, err = find(state)
    if info == nil then
      return nil, err
    end
    if info and not owned(info, sid) then
      return nil, "container " .. state.name .. " already exists but is not owned by this plugin/chat; refusing to use or remove it"
    end
    if info then
      state.id = info.Id
    end
    if info and not matches(info, cwd, spec, resources) then
      local stopped, stop_err = checked({ "stop", "--ignore", "--time", "0", info.Id })
      if not stopped then
        return nil, stop_err
      end
      local removed, remove_err = checked({ "rm", info.Id })
      if not removed then
        return nil, remove_err
      end
      info, state.id, state.ready_id = false, nil, nil
    end
    if not info then
      local volume = cwd .. ":" .. cwd .. (opts.volume_options ~= "" and ":" .. opts.volume_options or "")
      local create_args = {
        "create", "--name", state.name, "--init",
        "--label", OWNER .. "=1", "--label", SESSION .. "=" .. sid,
        "--label", SPEC .. "=" .. spec,
        "--volume", volume, "--workdir", cwd, "--entrypoint", "/bin/sh",
        "--publish", "127.0.0.1::" .. WORKER_PORT .. "/tcp",
      }
      for _, mount in ipairs(resources and resources.mounts or {}) do
        local flags = (mount.readonly and "ro" or "rw") .. (opts.volume_options ~= "" and "," .. opts.volume_options or "")
        create_args[#create_args + 1] = "--volume"
        create_args[#create_args + 1] = mount.source .. ":" .. mount.destination .. ":" .. flags
      end
      for _, arg in ipairs({ opts.image, "-c", KEEPALIVE }) do create_args[#create_args + 1] = arg end
      local created, create_err = checked(create_args)
      if not created then
        return nil, create_err
      end
      local id = (created.stdout or ""):match("^%s*([a-fA-F0-9]+)%s*$")
      if id then
        state.id = id
      end
      info, err = inspect(id or state.name)
      if not info then
        return nil, err
      end
      if not owned(info, sid) then
        return nil, "container ownership changed during creation"
      end
      state.id = info.Id
    end
    -- Creation and start are separate so cancellation before the new ID is
    -- known can leave only a stopped container, never a running orphan.
    if ending or state.closed then
      return nil, "the chat closed while its container was being created"
    end
    if not info.State.Running then
      local started, start_err = checked({ "start", info.Id })
      if not started then
        return nil, start_err
      end
      state.ready_id = nil
      info, err = inspect(state.id)
      if not info then return nil, err end
    end
    if ending or state.closed then
      checked({ "stop", "--ignore", "--time", "0", state.id })
      return nil, "the chat closed while its container was starting"
    end
    if state.ready_id ~= state.id then
      local ready, ready_err = checked({ "exec", state.id, "/bin/sh", "-c", process.check, "maki-check", opts.shell })
      if not ready then
        return nil, ready_err
      end
      state.ready_id = state.id
    end
    state.port = worker_port(info)
    if not state.port then
      return nil, "container has no private worker port; the plugin requires a local Podman instance with port publishing"
    end
    state.cwd, state.spec = cwd, spec
    return state.id
  end

  local function activate(sid)
    local state, err = state_for(sid)
    if not state then
      return nil, err
    end
    if ending then
      return nil, "the plugin is shutting down"
    end
    state.pending = true
    if state.preparing then
      return true
    end
    state.preparing = true
    -- Provisioning may pull an image. Host autocmds are serialized, so let
    -- their queue advance to SessionEnd while Podman is working.
    state.preparation = maki.async.spawn(function()
      repeat
        state.pending = false
        local ok, prepare_err = with_lock(state, function()
          if state.closed or ending then
            return nil, "the chat closed before its container was ready"
          end
          local cwd, cwd_err = session_cwd(sid)
          if not cwd then
            return nil, cwd_err
          end
          return ensure(state, sid, cwd)
        end)
        if not ok and not state.closed and not ending then
          warn(prepare_err)
        end
      until not state.pending or state.closed or ending
      state.preparing, state.preparation = false, nil
    end)
    return true
  end

  local function close(state)
    state.closed = true
    invalidate(state, "chat is closing")
    if state.preparation then
      state.preparation:cancel()
      state.preparation = nil
    end
  end

  local function stop(sid, deadline, reason)
    local state = states[sid]
    if reason == "shutdown" or reason == "reload" then
      -- All teardown events share Maki's two-second budget. Handle the known
      -- containers in one request, rather than spending that budget per tab.
      if ending then
        return true
      end
      ending = true
      local args = opts.remove_on_session_end and { "rm", "--force", "--ignore", "--time", "0" }
        or { "stop", "--ignore", "--time", "0" }
      local base_count = #args
      for _, entry in pairs(states) do
        close(entry)
        if entry.id then
          args[#args + 1] = entry.id
        end
      end
      if #args == base_count then
        return true
      end
      return checked(args, math.max(1, (deadline or 2000) - SHUTDOWN_RESERVE_MS))
    end
    if not state then
      return true
    end
    close(state)
    -- ACP can replace a live chat with the same ID, without a focus event.
    -- In-flight work retains the closed object; the next call gets a new one.
    states[sid] = nil
    local function stop_one()
      if not state.id then
        return true
      end
      local args = opts.remove_on_session_end and { "rm", "--force", "--ignore", "--time", "0", state.id }
        or { "stop", "--ignore", "--time", "0", state.id }
      return checked(args, deadline and math.max(1, deadline - SHUTDOWN_RESERVE_MS))
    end
    if deadline ~= nil then
      return stop_one()
    end
    return with_lock(state, stop_one)
  end

  function manager.setup()
    maki.api.create_autocmd({ "SessionFocusChanged", "SessionCwdChanged" }, {
      callback = function(ev)
        local ok, err = activate(ev.data.session_id)
        if not ok then
          warn(err)
        end
      end,
    })
    maki.api.create_autocmd("SessionEnd", {
      callback = function(ev)
        local ok, err = stop(ev.data.session_id, ev.data.deadline_ms, ev.data.reason)
        if not ok then
          warn(err)
        end
      end,
    })
  end

  local function spawn(state, cwd, id, command, job_options, ctx, shell, persistent)
    if ctx:cancelled() or state.closed or ending then
      return nil, "the command was cancelled before it started"
    end
    sequence = sequence + 1
    local token = instance .. "-" .. sequence
    local args = { "exec", "--workdir", cwd }
    for key, value in pairs(job_options.env or {}) do
      if type(key) ~= "string" or not key:match("^[A-Za-z_][A-Za-z0-9_]*$") or type(value) ~= "string" or value:find("\0", 1, true) then
        return nil, "invalid environment variable for container command"
      end
      args[#args + 1] = "--env"
      args[#args + 1] = key .. "=" .. value
    end
    for _, value in ipairs({ id, "/bin/sh", "-c", process.launch, "maki-exec", token, shell or opts.shell, command, job_options.cwd or "" }) do
      args[#args + 1] = value
    end
    local host_options = copy(job_options)
    host_options.cwd, host_options.env = "/", nil
    local finished = false
    host_options.on_exit = function(job, code)
      finished = true
      if job_options.on_exit then
        job_options.on_exit(job, code)
      end
    end
    local job, start_err = maki.fn.jobstart(argv(args), host_options)
    if not job then
      return nil, "could not start container command: " .. tostring(start_err)
    end
    local cancelled = false
    local function cancel(force)
      if cancelled or (finished and not force) then
        return
      end
      cancelled = true
      local cleanup, cleanup_err = maki.fn.jobstart(argv({ "exec", id, "/bin/sh", "-c", process.cancel, "maki-cancel", token }), {
        cwd = "/", scope = "plugin", tail = 5,
        on_exit = function(_, code)
          if code ~= 0 then
            warn("container-side command cancellation failed (exit " .. tostring(code) .. "); close the chat to stop its remaining processes")
          end
        end,
      })
      if not cleanup then
        warn("could not start command cancellation: " .. tostring(cleanup_err))
      end
    end
    if not persistent then maki.async.on_cancel(function() cancel(false) end) end
    return job, nil, function() cancel(true) end
  end

  function manager.prepare(ctx)
    if ctx:cancelled() then return nil, "the call was cancelled before it started" end
    local sid = ctx:session_id()
    local state, err = state_for(sid)
    if not state then return nil, err end
    return with_lock(state, function()
      local cwd, cwd_err = session_cwd(sid)
      if not cwd then return nil, cwd_err end
      local id, ensure_err = ensure(state, sid, cwd)
      if not id then return nil, ensure_err end
      return { id = id, cwd = cwd, sid = sid, port = state.port, resources = state.resources, _state = state }
    end)
  end

  -- A file operation stays pinned to this ID even if /cd recreates the chat.
  -- It fails on the old container instead of silently switching environments.
  function manager.exec_prepared(target, command, job_options, ctx)
    local parts = {}
    for _, arg in ipairs(command) do
      if type(arg) ~= "string" or arg:find("\0", 1, true) then return nil, "invalid container argument" end
      parts[#parts + 1] = "'" .. arg:gsub("'", "'\"'\"'") .. "'"
    end
    return spawn(target._state, target.cwd, target.id, table.concat(parts, " "), job_options or {}, ctx, "/bin/sh")
  end

  function manager.worker(target, create)
    local state = target._state
    return with_lock(state, function()
      if ending or state.closed or state.id ~= target.id or state.cwd ~= target.cwd or state.port ~= target.port then
        return nil, "the chat container changed; start a new file tool call"
      end
      if state.worker and state.worker.alive() then return state.worker end
      invalidate(state, "file worker is unavailable")
      local worker, err = create()
      if not worker then return nil, err end
      if ending or state.closed or state.id ~= target.id then
        worker.close("chat closed during worker startup")
        return nil, "the chat closed while its file worker was starting"
      end
      state.worker = worker
      return worker
    end)
  end

  function manager.start_worker(target, command, job_options, ctx)
    local parts = {}
    for _, arg in ipairs(command) do
      if type(arg) ~= "string" or arg:find("\0", 1, true) then return nil, "invalid worker argument" end
      parts[#parts + 1] = "'" .. arg:gsub("'", "'\"'\"'") .. "'"
    end
    job_options = copy(job_options or {})
    job_options.scope = "plugin"
    return spawn(target._state, target.cwd, target.id, table.concat(parts, " "), job_options, ctx, "/bin/sh", true)
  end

  function manager.worker_port() return WORKER_PORT end

  function manager.copy_in(target, source, destination)
    if ending or target._state.closed then return nil, "the chat is closing" end
    return checked({ "cp", "--", source, target.id .. ":" .. destination })
  end

  function manager.cleanup(target, directory)
    assert(directory:match("^/tmp/maki%-podman%-files%.[A-Za-z0-9]+%-remote$"), "invalid transfer cleanup path")
    return maki.fn.jobstart(argv({ "exec", target.id, "/bin/rm", "-rf", "--", directory }), {
      cwd = "/", scope = "plugin", tail = 0,
    })
  end

  function manager.jobstart(command, job_options, ctx)
    if ctx:cancelled() then
      return nil, "the command was cancelled before it started"
    end
    if type(command) ~= "string" or command:find("\0", 1, true) then
      return nil, "command must be a string without NUL bytes"
    end
    local sid = ctx:session_id()
    local state, err = state_for(sid)
    if not state then
      return nil, err
    end
    return with_lock(state, function()
      local cwd, cwd_err = session_cwd(sid)
      if not cwd then
        return nil, cwd_err
      end
      local id, ensure_err = ensure(state, sid, cwd)
      if not id then
        return nil, ensure_err
      end
      if ctx:cancelled() or state.closed or ending then
        return nil, "the command was cancelled before it started"
      end
      return spawn(state, cwd, id, command, job_options, ctx)
    end)
  end

  return manager
end

return M
