local host_require = require
local M = {}

M.names = { "read", "write", "edit", "list", "glob", "grep", "index", "view_image", "code_execution", "memory", "skill" }

local helpers = {
  ["maki.dir_listing"] = "dir_listing",
  ["list_helpers"] = "list_helpers",
  ["maki.shorten_path"] = "shorten_path",
  ["memory_helpers"] = "memory_helpers",
  ["skill_helpers"] = "skill_helpers",
}

local function option_values(plugin, specs, overrides)
  local values = {}
  for key in pairs(overrides) do
    assert(specs[key], "maki-podman files." .. plugin .. ": unknown option " .. tostring(key))
  end
  for key, spec in pairs(specs) do
    local value = overrides[key]
    if value == nil then
      value = spec.default
    end
    if value ~= nil then
      local expected = spec.type or type(spec.default)
      local actual = type(value)
      local valid = actual == expected or (expected == "integer" and actual == "number" and value % 1 == 0)
      local label = "maki-podman files." .. plugin .. "." .. key
      assert(valid, label .. " must be " .. expected)
      if actual == "number" then
        assert(value == value and value ~= math.huge and value ~= -math.huge, label .. " must be finite")
        assert(not spec.min or value >= spec.min, label .. " is below its minimum")
        assert(not spec.max or value <= spec.max, label .. " is above its maximum")
      end
      values[key] = value
    end
  end
  return values
end

-- Instantiate the original tool closures against one call's filesystem and
-- context. No global maki/package.loaded mutation is used, so simultaneous
-- chats cannot accidentally share a container through these adapters.
function M.load(name, proxy, overrides)
  local known = false
  for _, item in ipairs(M.names) do
    known = known or item == name
  end
  assert(known, "unknown container file plugin: " .. tostring(name))
  overrides = overrides or {}
  assert(type(overrides) == "table", "file plugin options must be a table")

  local result = { tools = {}, hints = {}, options = {} }
  local api = setmetatable({}, { __index = proxy.api })
  function api.register_tool(spec)
    assert(not result.tools[spec.name], "duplicate container tool: " .. spec.name)
    result.tools[spec.name] = spec
  end
  function api.register_prompt_hint(hint)
    result.hints[#result.hints + 1] = hint
  end
  function api.register_options(specs)
    result.options = specs
    return option_values(name, specs, overrides)
  end

  local scoped = setmetatable({ api = api }, { __index = proxy })
  local cache = {}
  local function scoped_require(module)
    if cache[module] ~= nil then
      return cache[module]
    end
    local helper = helpers[module]
    if not helper then
      return host_require(module)
    end
    local value = host_require("maki_podman.upstream." .. helper)(scoped, scoped_require)
    cache[module] = value
    return value
  end

  host_require("maki_podman.upstream." .. name)(scoped, scoped_require)
  if next(result.options) == nil then
    option_values(name, {}, overrides)
  end
  return result
end

return M
