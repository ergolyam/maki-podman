local source = require("maki_podman.worker_source")
local M = {}
local FRAME_BYTES = 128 * 1024
local REQUEST_BYTES = 128 * 1024 * 1024
local PROTOCOL = 1

local function checked(value, err)
  if value == nil then error(tostring(err or "container worker transport failed"), 0) end
  return value
end

local function host_job(args, timeout)
  local job = checked(maki.fn.jobstart(args, { cwd = "/" }))
  local result, err = maki.fn.jobwait(job, timeout)
  if not result then maki.fn.jobstop(job); error(tostring(err), 0) end
  if result.exit_code ~= 0 then error(result.stderr or "transport setup failed", 0) end
  return result.stdout
end

function M.new(manager, options)
  local timeout = options.operation_timeout_ms or 120000
  local lua = options.lua or "lua5.4"
  assert(type(lua) == "string" and lua ~= "" and not lua:find("\0", 1, true), "lua must name the container Lua executable")
  assert(maki.net and maki.net.connect, "maki-podman requires Maki's maki.net.connect API")
  local factory = {}

  function factory.open(target, ctx)
    return manager.worker(target, function()
      local channel = { sequence = 0, gate = maki.async.semaphore(1), buffer = "", offset = 1 }
      local staging, remote, job, cancel, conn, timer, timer_token
      local setup_job, cancel_setup
      local creating, ready, dead = true, false, false
      local failure, stopped_job, cancelled_worker, worker_exited

      local function stop_timer()
        timer_token = nil
        if timer then timer:stop(); timer = nil end
      end
      local function remove_staging()
        if staging then
          maki.fn.jobstart({ "rm", "-rf", "--", staging }, { cwd = "/", scope = "plugin", tail = 0 })
          staging = nil
        end
      end
      function channel.close(reason, exited)
        dead = true
        failure = failure or reason or "container worker connection closed"
        worker_exited = worker_exited or exited
        stop_timer()
        if conn then conn:close() end
        if cancel_setup then cancel_setup(); cancel_setup = nil end
        if setup_job then maki.fn.jobstop(setup_job); setup_job = nil end
        if cancel and not worker_exited and not cancelled_worker then cancelled_worker = true; cancel() end
        if job and not worker_exited and stopped_job ~= job then stopped_job = job; maki.fn.jobstop(job) end
        if remote then manager.cleanup(target, remote); remote = nil end
        remove_staging()
      end
      function channel.alive()
        if dead or not conn then return false end
        local info = job and maki.fn.jobinfo(job)
        return info ~= nil and info.status == "running"
      end
      local function deadline()
        stop_timer()
        local token = {}
        timer_token = token
        timer = maki.defer_fn(function()
          if timer_token == token then channel.close("container file operation timed out") end
        end, timeout)
      end
      local function starting(value, err)
        if dead or ctx:cancelled() then
          channel.close("container worker startup cancelled")
          error(failure, 0)
        end
        return checked(value, err)
      end
      local function line()
        while true do
          if dead then error(failure, 0) end
          local first = channel.offset
          local stop = channel.buffer:find("\n", first, true)
          if stop then
            if stop - first > FRAME_BYTES then error("container response frame exceeds 128 KiB", 0) end
            channel.offset = stop + 1
            return channel.buffer:sub(first, stop - 1)
          end
          if first > 1 then
            channel.buffer = channel.buffer:sub(first)
            channel.offset = 1
          end
          if #channel.buffer > FRAME_BYTES then error("container response frame exceeds 128 KiB", 0) end
          local bytes, err = conn:read()
          if not bytes then error(failure or err or "container worker disconnected", 0) end
          channel.buffer = channel.buffer .. bytes
        end
      end
      local function frame()
        local encoded = line()
        local value, err = maki.json.decode(encoded)
        if type(value) ~= "table" then error("invalid container response: " .. tostring(err), 0) end
        return value, #encoded
      end
      local function send(value)
        local encoded = maki.json.encode(value)
        if #encoded > REQUEST_BYTES then error("container request exceeds 128 MiB", 0) end
        checked(conn:write(string.format("%08x\n", #encoded) .. encoded))
      end

      maki.async.on_cancel(function()
        if creating then channel.close("container worker startup cancelled") end
      end)
      local ok, err = pcall(function()
        staging = host_job({ "mktemp", "-d", "/tmp/maki-podman-files.XXXXXXXXXX" }, timeout):match("^%s*(.-)%s*$")
        assert(staging:match("^/tmp/maki%-podman%-files%.[A-Za-z0-9]+$"), "invalid private worker directory")
        starting(true)
        remote = staging .. "-remote"
        local token = maki.base64.encode(starting(maki.fs.read_bytes("/dev/urandom", { len = 32 })))
        starting(maki.fs.write(staging .. "/worker.lua", source))
        starting(maki.fs.atomic_write(staging .. "/token", token))
        local directory = remote
        local setup, setup_err, setup_cancel = manager.exec_prepared(target,
          { "/bin/sh", "-c", 'umask 077; mkdir -- "$1"', "maki-files", directory }, {
            scope = "plugin", tail = 5,
            on_exit = function()
              setup_job, cancel_setup = nil, nil
              if dead then manager.cleanup(target, directory) end
            end,
          }, ctx)
        setup_job, cancel_setup = setup, setup_cancel
        checked(setup, setup_err)
        local result, wait_err = maki.fn.jobwait(setup, timeout)
        if dead then manager.cleanup(target, directory) end
        if not result then
          if setup_cancel then setup_cancel() end
          maki.fn.jobstop(setup)
          error(tostring(wait_err), 0)
        end
        if result.exit_code ~= 0 then error("cannot create container worker directory: " .. (result.stderr or ""), 0) end
        starting(true)
        local copied, copy_err = manager.copy_in(target, staging .. "/.", directory)
        if dead then manager.cleanup(target, directory) end
        starting(copied, copy_err)
        remove_staging()
        deadline()
        local start_err
        job, start_err, cancel = manager.start_worker(target,
          { lua, directory .. "/worker.lua", "--serve", tostring(manager.worker_port()), directory .. "/token" }, {
            tail = 5, max_line_bytes = FRAME_BYTES,
            on_stdout = function(_, text, _, actual_bytes)
              if dead then return end
              local value = maki.json.decode(text)
              if (actual_bytes and actual_bytes > #text) or type(value) ~= "table"
                or value.ready ~= true or value.protocol ~= PROTOCOL or ready then
                channel.close("invalid container worker startup response")
              else ready = true end
            end,
            on_exit = function(_, code)
              channel.close("container file worker exited (exit " .. tostring(code) .. ")", true)
            end,
          }, ctx)
        starting(job, start_err)
        while not ready and not dead do
          local result, wait_err = maki.fn.jobwait(job, 50)
          if result then
            error("container worker failed: " .. (result.stderr or "")
              .. "; the image needs Lua 5.4, LuaFileSystem, LuaSocket, ripgrep and GNU coreutils", 0)
          end
          if not ready and not dead and wait_err ~= "jobwait: timed out" then error(tostring(wait_err), 0) end
        end
        if dead then error(failure, 0) end
        local connect_err
        conn, connect_err = maki.net.connect("127.0.0.1", target.port, { timeout = math.max(1, math.ceil(timeout / 1000)) })
        checked(conn, connect_err)
        if dead then conn:close(); error(failure, 0) end
        send({ id = 0, protocol = PROTOCOL, token = token })
        local hello = frame()
        if hello.id ~= 0 or hello.ok ~= true or hello.protocol ~= PROTOCOL or type(hello.context) ~= "table"
          or type(hello.context.cwd) ~= "string" or hello.context.cwd:sub(1, 1) ~= "/" then
          error("container worker authentication/protocol mismatch", 0)
        end
        channel.context = hello.context
      end)
      creating = false
      stop_timer()
      if not ok then channel.close(tostring(err)); return nil, tostring(err) end

      function channel.rpc(request, accept, context)
        if dead then return nil, failure end
        local permit = channel.gate:acquire()
        local held, active, sent = true, false, false
        local function release()
          if held then held = false; permit:release() end
        end
        maki.async.on_cancel(function()
          if active then channel.close("container file operation cancelled; its outcome may be unknown") end
          release()
        end)
        local success, result = pcall(function()
          if dead then error(failure, 0) end
          if not held or context:cancelled() then error("container file call cancelled", 0) end
          active = true
          deadline()
          channel.sequence = channel.sequence + 1
          request.id = channel.sequence
          sent = true
          send(request)
          while true do
            local value, bytes = frame()
            if value.id ~= request.id then error("container response has the wrong request ID", 0) end
            if value.ok ~= nil then
              if type(value.ok) ~= "boolean" then error("invalid container terminal response", 0) end
              return value
            end
            accept(value, bytes)
          end
        end)
        active = false
        stop_timer()
        if not success and sent then
          channel.close(tostring(result))
          result = tostring(result) .. "; the request was not retried and its outcome may be unknown"
        end
        release()
        if not success then return nil, tostring(result) end
        return result
      end
      return channel
    end)
  end
  return factory
end

return M
