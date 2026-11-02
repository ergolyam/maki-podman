local M = {}
local configured = false

function M.setup(opts)
  assert(not configured, "maki-podman: setup() must only be called once per plugin load")
  local options = require("maki_podman.config").resolve(opts)
  local resources, register_rules = require("maki_podman.resources").new()
  options.resources = resources
  local containers = require("maki_podman.containers").new(options)
  require("maki_podman.tool").register(containers, options)
  local write_tools = require("maki_podman.files").register(containers, options)
  register_rules(write_tools)
  require("maki_podman.memory_picker").register()
  containers.setup()
  configured = true
end

return M
