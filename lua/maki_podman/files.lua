local upstream = require("maki_podman.upstream")
local M = {}
local INSTRUCTIONS = { "AGENTS.md", "CLAUDE.md", ".github/copilot-instructions.md", "COPILOT.md", ".cursorrules",
  ".windsurfrules", ".clinerules", "CONVENTIONS.md", "GEMINI.md", "CODING_AGENT.md", "AGENTS.local.md" }

local function copy(value)
  local result = {}
  for key, item in pairs(value) do result[key] = item end
  return result
end
local function inside(path, root) return path == root or path:sub(1, #root + 1) == root .. "/" end
local function checked(value, err)
  if value == nil then error(tostring(err or "container filesystem unavailable"), 0) end
  return value
end

function M.register(manager, options)
  options = options or {}
  local factory = require("maki_podman.fs").new(manager, options)
  local tool_options = options.files or {}
  local histories, locks, sinks, write_tools = {}, {}, {}, {}

  local function task_key(ctx)
    return tostring(ctx:session_id()) .. ":" .. tostring(ctx:task_id())
  end
  local function history(ctx, state)
    local key = task_key(ctx)
    local value = histories[key]
    if not value or value.id ~= state.id then
      value = { id = state.id, versions = {}, aliases = {}, instructions = {} }
      histories[key] = value
    end
    return value
  end

  local function make_proxy(fs, ctx, instructions)
    local proxy = setmetatable({ fs = fs }, { __index = maki })
    proxy.uv = setmetatable({
      cwd = function() return fs and fs.state().cwd or nil end,
      os_homedir = function() return fs and fs.state().home or nil end,
    }, { __index = maki.uv })
    proxy.env = setmetatable({
      state_dir = function() return "/tmp/maki-podman-state" end,
      podman_memory_dir = function(legacy)
        local resources = fs and fs.state().resources or {}
        return legacy and resources.legacy_memory_dir or resources.memory_dir
      end,
      podman_skill_dirs = function() return fs and (fs.state().resources.skill_dirs or {}) or {} end,
    }, { __index = maki.env })
    if not ctx then return proxy end
    local wrapped = {}
    setmetatable(wrapped, { __index = function(_, name)
      local member = ctx[name]
      if type(member) == "function" then return function(_, ...) return member(ctx, ...) end end
      return member
    end })
    function wrapped:record_read(path)
      local state = checked(fs.state())
      local version = fs.observed(path) or checked(fs.version(path))
      local absolute = fs.abspath(path)
      local ok, err = ctx:record_read(path)
      if not ok then error(tostring(err or "cannot record file read"), 0) end
      if absolute ~= path then
        ok, err = ctx:record_read(absolute)
        if not ok then error(tostring(err or "cannot record file read"), 0) end
      end
      local h = history(ctx, state)
      h.versions[version.canonical] = version
      h.aliases[absolute] = version
      return true
    end
    function wrapped:load_instructions(directory)
      local state = checked(fs.state())
      local root, dir = fs.normalize(state.cwd), fs.normalize(directory)
      if not inside(dir, root) then return true end
      local dirs = {}
      while inside(dir, root) do
        table.insert(dirs, 1, dir)
        if dir == root then break end
        dir = fs.dirname(dir)
      end
      local h = history(ctx, state)
      for _, parent in ipairs(dirs) do
        local names, seen = {}, {}
        for _, name in ipairs(options.instruction_files or INSTRUCTIONS) do
          if ctx:is_instruction_file(name) or ctx:is_instruction_file(fs.basename(name)) then
            names[#names + 1], seen[name] = name, true
          end
        end
        -- Also honour custom instruction filenames present directly here.
        for _, entry in ipairs(fs.dir(parent) or {}) do
          if not seen[entry[1]] and ctx:is_instruction_file(entry[1]) then names[#names + 1] = entry[1] end
        end
        for _, name in ipairs(names) do
          local path = fs.joinpath(parent, name)
          local meta = not h.instructions[path] and fs.metadata(path)
          if meta and meta.is_file then
            local content = checked(fs.read(path))
            local block = { path = path, text = "\n\nContainer instructions from " .. path .. ":\n" .. content }
            instructions[path] = block
            for _, sink in pairs(sinks[task_key(ctx)] or {}) do sink[path] = block end
          end
        end
      end
      return true
    end
    proxy.agent = setmetatable({
      callable_tools = function(value, ...) return maki.agent.callable_tools(value == wrapped and ctx or value, ...) end,
      call_tool = function(value, ...) return maki.agent.call_tool(value == wrapped and ctx or value, ...) end,
    }, { __index = maki.agent })
    return proxy, wrapped
  end

  local function with_write(fs, ctx, path, callback, memory_root)
    local state = checked(fs.state())
    local version = checked(fs.version(path))
    if memory_root then
      local root = checked(fs.version(memory_root)).canonical
      if not inside(version.canonical, root) or version.canonical == root then
        return { llm_output = "memory path resolves outside its container memory directory", is_error = true }
      end
    end
    -- Native guards see host symlinks. Require an existing permission for a
    -- different container target, otherwise ask the agent to call its real path.
    if memory_root or version.canonical ~= fs.normalize(path) or path:sub(1, 1) == "~" then
      local allowed, err = ctx:can_write(version.canonical)
      if not allowed then
        return { llm_output = tostring(err) .. "; use the absolute container path " .. version.canonical .. " with the write/edit tool so Maki can check permission", is_error = true }
      end
    end
    local key = state.id .. ":" .. version.canonical
    if inside(version.canonical, state.cwd) then key = "bind:" .. version.canonical end
    for _, mount in ipairs((state.resources or {}).mounts or {}) do
      if not mount.readonly and inside(version.canonical, mount.destination) then key = "bind:" .. version.canonical end
    end
    local lock = locks[key]
    if not lock then lock = { gate = maki.async.semaphore(1), users = 0 }; locks[key] = lock end
    lock.users = lock.users + 1
    local permit
    local held = true
    local function release()
      if not held then return end
      held = false
      if permit then permit:release() end
      lock.users = lock.users - 1
      if lock.users == 0 then locks[key] = nil end
    end
    maki.async.on_cancel(release)
    permit = lock.gate:acquire()
    if not held then
      permit:release()
      return { llm_output = "container edit cancelled while waiting for the file lock", is_error = true }
    end
    local ok, result = pcall(function()
      local now = checked(fs.version(path))
      if now.canonical ~= version.canonical then
        return { llm_output = "file target changed; re-read using read before editing", is_error = true }
      end
      local h = history(ctx, state)
      local alias = h.aliases[fs.abspath(path)]
      local old = h.versions[now.canonical]
      if ctx:config("stale_read_check", true) and now.exists
        and ((alias and alias.canonical ~= now.canonical) or (old and old.fingerprint ~= now.fingerprint)) then
        return { llm_output = "file changed since last read: " .. path .. " - re-read using read tool before editing", is_error = true }
      end
      fs.expect(path, now)
      local value = callback()
      if type(value) ~= "table" or not value.is_error then
        local after = checked(fs.version(path))
        h.versions[after.canonical], h.aliases[fs.abspath(path)] = after, after
      end
      return value
    end)
    release()
    if not ok then error(result, 0) end
    return result
  end

  for _, plugin in ipairs(upstream.names) do
    local template = upstream.load(plugin, make_proxy(nil), tool_options[plugin])
    for _, hint in ipairs(template.hints) do maki.api.register_prompt_hint(hint) end
    for name, original in pairs(template.tools) do
      local spec = copy(original)
      spec.description = (spec.description or "") .. "\n\nFile paths and file contents belong to this chat's Podman container."
      spec.handler = function(input, ctx)
        local fs = factory.for_context(ctx)
        local instructions = {}
        local key = task_key(ctx)
        if name == "code_execution" then
          sinks[key] = sinks[key] or {}
          sinks[key][instructions] = instructions
          maki.async.on_cancel(function()
            if sinks[key] then
              sinks[key][instructions] = nil
              if next(sinks[key]) == nil then sinks[key] = nil end
            end
          end)
        end
        local ok, result = pcall(function()
          checked(fs.state())
          local proxy, wrapped = make_proxy(fs, ctx, instructions)
          local loaded = upstream.load(plugin, proxy, tool_options[plugin])
          local callback = function() return loaded.tools[name].handler(input, wrapped) end
          if original.mutable_path then return with_write(fs, ctx, input[original.mutable_path], callback) end
          if name == "memory" and (input.command == "write" or input.command == "delete") then
            local root = checked(proxy.env.podman_memory_dir(false), "memory directory unavailable")
            local path = input.path
            if type(path) ~= "string" or path == "" or path:find("\0", 1, true) or path:sub(1, 1) == "/" then
              return { llm_output = "memory path must be a nonempty relative path", is_error = true }
            end
            return with_write(fs, ctx, fs.joinpath(root, path), callback, root)
          end
          return callback()
        end)
        if sinks[key] then sinks[key][instructions] = nil; if next(sinks[key]) == nil then sinks[key] = nil end end
        if ok and next(instructions) then
          if type(result) == "string" then result = { llm_output = result } end
          if type(result) == "table" then
            local h = history(ctx, checked(fs.state()))
            local paths = {}
            for path in pairs(instructions) do paths[#paths + 1] = path end
            table.sort(paths)
            for _, path in ipairs(paths) do
              result.llm_output = (result.llm_output or "") .. instructions[path].text
              h.instructions[path] = true
            end
          end
        end
        if fs.close then fs.close() end
        if not ok then return { llm_output = "container file tool error: " .. tostring(result), is_error = true } end
        return result
      end
      maki.api.register_tool(spec)
      if spec.mutable_path then write_tools[#write_tools + 1] = name end
    end
  end
  maki.api.register_prompt_hint({ slot = "tool_usage", content = [[
- bash and all file tools use the same chat's Podman container. Use absolute container paths; ~/ means the container HOME.
- Host OS/environment facts in Maki's initial prompt describe Maki itself. Inspect the container with bash or read when choosing commands.
- code_execution orchestrates these container tools. Direct Python os/pathlib metadata is unavailable; use list, glob or bash.
]] })
  if maki.api.create_autocmd then
    maki.api.create_autocmd("SessionEnd", { callback = function(ev)
      local prefix = ev.data.session_id .. ":"
      for key in pairs(histories) do if key:sub(1, #prefix) == prefix then histories[key] = nil end end
      for key in pairs(sinks) do if key:sub(1, #prefix) == prefix then sinks[key] = nil end end
    end })
  end
  return write_tools
end

return M
