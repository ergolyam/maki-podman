local M = {}

function M.new()
  local state = assert(maki.env.state_dir(), "Maki state directory is unavailable")
  local legacy = maki.env.legacy_dir()
  local cache = {}
  local function host_run(argv, stdout)
    local job, err = maki.fn.jobstart(argv, { cwd = "/", stdout = stdout })
    if not job then return nil, "cannot start host " .. argv[1] .. " for data mount: " .. tostring(err) end
    local result, wait_err = maki.fn.jobwait(job, 30000)
    if not result then
      maki.fn.jobstop(job)
      return nil, "data mount " .. argv[1] .. " did not finish: " .. tostring(wait_err)
    end
    if result.exit_code ~= 0 then
      return nil, "data mount " .. argv[1] .. " failed: " .. tostring(result.stderr or "unknown error")
    end
    return result
  end
  local function canonical_source(path)
    local made, make_err = host_run({ "mktemp", "-d", "/tmp/maki-podman-mount.XXXXXXXXXX" })
    if not made then return nil, make_err end
    local staging = (made.stdout or ""):match("^%s*(.-)%s*$")
    if made.truncated or not staging:match("^/tmp/maki%-podman%-mount%.[A-Za-z0-9]+$") then
      return nil, "invalid private data mount staging path"
    end
    local pending = true
    local function cleanup()
      if pending then
        maki.fn.jobstart({ "rm", "-rf", "--", staging }, { cwd = "/", scope = "plugin", tail = 0 })
      end
    end
    maki.async.on_cancel(cleanup)
    local ok, resolved = pcall(function()
      local output = staging .. "/source"
      local written, write_err = maki.fs.write(output, "")
      assert(written, "cannot prepare data mount response: " .. tostring(write_err))
      local result, run_err = host_run({ "realpath", "-z", "--", path }, output)
      assert(result, run_err)
      -- Maki's process callbacks normalize CRLF. Redirect only this private
      -- response file, then read it verbatim so unusual path bytes survive.
      local raw, read_err = maki.fs.read(output)
      assert(raw, "cannot read data mount response: " .. tostring(read_err))
      assert(raw:sub(-1) == "\0", "invalid realpath output for data mount; host GNU realpath with -z support is required")
      local source = raw:sub(1, -2)
      assert(source:sub(1, 1) == "/" and not source:find("[:%z]"),
        "data mount source must resolve to an absolute path without ':' or NUL")
      return source
    end)
    local removed = maki.fs.rm(staging, { recursive = true, force = true })
    if not removed then cleanup() end
    pending = false
    if not ok then return nil, tostring(resolved) end
    return resolved
  end
  local function directory(path)
    local meta = path and maki.fs.metadata(path)
    return meta and meta.is_dir
  end
  local function create(path)
    local ok, err = maki.fs.mkdir(path, { parents = true })
    assert(ok, "cannot prepare Maki data mount: " .. tostring(err))
  end
  local function prepare(sid, cwd)
    local key = sid .. ":" .. cwd
    if cache[key] then return cache[key] end
    local root = maki.fs.root(cwd, ".git") or cwd
    local suffix = "projects/" .. require("memory_helpers").project_id(root) .. "/memories"
    local result = { mounts = {}, skill_dirs = {}, memory_dir = maki.fs.joinpath(state, suffix) }
    local seen = {}
    local function mount(path, readonly)
      assert(type(path) == "string" and path:sub(1, 1) == "/" and not path:find("[:%z]"), "data mount needs an absolute path without ':' or NUL")
      if not seen[path] then
        seen[path] = true
        local source, source_err = canonical_source(path)
        assert(source, source_err)
        result.mounts[#result.mounts + 1] = { source = source, destination = path, readonly = readonly }
      end
    end
    local logs = maki.fs.joinpath(state, "tasks", sid)
    create(logs)
    mount(logs, true)
    create(result.memory_dir)
    mount(result.memory_dir, false)
    local old = legacy and maki.fs.joinpath(legacy, suffix)
    if old and old ~= result.memory_dir and directory(old) then
      result.legacy_memory_dir = old
      mount(old, false)
    end
    local dirs = {}
    local config = maki.env.config_dir()
    if config then dirs[#dirs + 1] = maki.fs.joinpath(config, "skills") end
    local home = maki.uv.os_homedir()
    if home then
      for _, rel in ipairs({ ".claude/skills", ".config/opencode/skills", ".agents/skills" }) do
        dirs[#dirs + 1] = maki.fs.joinpath(home, rel)
      end
    end
    for _, dir in ipairs(dirs) do
      if directory(dir) then
        result.skill_dirs[#result.skill_dirs + 1] = dir
        mount(dir, true)
      end
    end
    table.sort(result.mounts, function(a, b) return a.source < b.source end)
    cache[key] = result
    return result
  end
  local function register_rules(write_tools)
    for _, base in ipairs(legacy and { state, legacy } or { state }) do
      for _, tool in ipairs(write_tools) do
        maki.api.register_permission_rule({ tool = tool, scope = base .. "/projects/*/memories/**" })
      end
    end
  end
  return prepare, register_rules
end

return M
