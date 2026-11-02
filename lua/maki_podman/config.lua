local M = {}

local specs = {
  podman = { default = "podman", desc = "Podman executable on the host." },
  image = { default = "localhost/maki-podman:latest", desc = "Container image with the file-tool dependencies installed." },
  shell = { default = "/bin/bash", desc = "Absolute shell path inside the container." },
  lua = { default = "lua5.4", desc = "Lua executable inside the container." },
  volume_options = { default = "z", desc = "SELinux bind-mount option: z, Z, or an empty string." },
  operation_timeout_ms = { default = 120000, type = "integer", min = 1, desc = "Timeout for Podman management and file operations, in milliseconds." },
  timeout_secs = { default = 120, type = "integer", min = 5, desc = "Default bash command timeout, in seconds." },
  background_on_timeout = { default = false, desc = "Move eligible bash commands to the background on timeout." },
  background_log_bytes = { default = 32 * 1024 * 1024, type = "integer", min = 1024, desc = "Bash output log rotation size; capped at 1 GiB." },
  max_output_lines = { type = "integer", desc = "Override agent.max_output_lines for bash." },
  max_output_bytes = { type = "integer", desc = "Override agent.max_output_bytes for bash." },
}

local function validate(name, value, spec)
  local expected = spec.type or type(spec.default)
  local actual = type(value)
  local label = "maki-podman: " .. name
  assert(actual == expected or (expected == "integer" and actual == "number" and value % 1 == 0),
    label .. " must be " .. expected)
  if actual == "number" then
    assert(value == value and value ~= math.huge and value ~= -math.huge, label .. " must be finite")
    assert(not spec.min or value >= spec.min, label .. " must be at least " .. tostring(spec.min))
  elseif actual == "string" then
    assert(not value:find("\0", 1, true), label .. " must not contain NUL bytes")
    assert(name == "volume_options" or value ~= "", label .. " must not be empty")
  end
end

function M.resolve(overrides)
  if overrides == nil then overrides = {} end
  assert(type(overrides) == "table", "maki-podman: setup options must be a table")
  for name in pairs(overrides) do
    assert(specs[name] or name == "files" or name == "instruction_files",
      "maki-podman: unknown setup option " .. tostring(name))
  end

  local options = maki.api.register_options(specs)
  for name, value in pairs(overrides) do options[name] = value end
  for name, spec in pairs(specs) do
    if options[name] ~= nil then validate(name, options[name], spec) end
  end
  assert(options.shell:sub(1, 1) == "/", "maki-podman: shell must be an absolute container path")
  assert(options.image:sub(1, 1) ~= "-", "maki-podman: image must not start with '-'")
  assert(options.volume_options == "z" or options.volume_options == "Z" or options.volume_options == "",
    "maki-podman: volume_options must be 'z', 'Z', or ''")

  if options.files ~= nil then
    assert(type(options.files) == "table", "maki-podman: files must be a table")
    local known = {}
    for _, name in ipairs(require("maki_podman.upstream").names) do known[name] = true end
    for name, value in pairs(options.files) do
      assert(known[name], "maki-podman: unknown file plugin " .. tostring(name))
      assert(type(value) == "table", "maki-podman: files." .. name .. " must be a table")
    end
  end
  if options.instruction_files ~= nil then
    assert(type(options.instruction_files) == "table", "maki-podman: instruction_files must be a list")
    local count = 0
    for key, name in pairs(options.instruction_files) do
      assert(type(key) == "number" and key >= 1 and key % 1 == 0,
        "maki-podman: instruction_files must be a list")
      validate("instruction_files entry", name, { type = "string" })
      count = count + 1
    end
    for i = 1, count do
      assert(options.instruction_files[i] ~= nil, "maki-podman: instruction_files must be a dense list")
    end
  end
  return options
end

return M
