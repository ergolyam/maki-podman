# maki-podman

A Lua plugin for [Maki](https://github.com/tontinton/maki) that runs Bash commands and file tools inside Podman containers instead of on the host. Each chat gets its own container with the working directory mounted at the same path.

## Initial Setup

Requires **Linux**, **Maki 0.7.0+**, **Podman**, **Git**, and **GNU coreutils** on the host.

### Build

- Build the container image with the dependencies needed by the file tools:
    ```bash
    git clone https://github.com/ergolyam/maki-podman.git
    cd maki-podman
    podman build -t localhost/maki-podman:latest .
    ```

### Install

- Add the plugin to `~/.config/maki/init.lua`:
    ```lua
    maki.pack.add({ "https://github.com/ergolyam/maki-podman" })

    local plugins = {
      ["maki-podman"] = {
        image = "localhost/maki-podman:latest",
        volume_options = "z",
      },
    }

    for _, name in ipairs({
      "bash", "read", "write", "edit", "list", "glob", "grep", "index",
      "view_image", "code_execution", "memory", "skill",
    }) do
      plugins[name] = { enabled = false }
    end

    maki.setup({ plugins = plugins })
    ```
    - Start Maki and approve the plugin installation and requested permissions.
    - The bundled tools must be disabled because `maki-podman` replaces them.

## Configuration

Set options under `plugins["maki-podman"]` in `init.lua`.

| Option | Default | Description |
|---|---|---|
| `image` | `localhost/maki-podman:latest` | Container image |
| `shell` | `/bin/bash` | Shell used for agent commands |
| `volume_options` | `z` | SELinux mount option (`z`, `Z`, or `""`) |
| `timeout_secs` | `120` | Default Bash command timeout in seconds |
| `operation_timeout_ms` | `120000` | Podman and file operation timeout in milliseconds |

Custom images must provide Bash (or the configured shell), Lua 5.4, LuaFileSystem, ripgrep, and GNU coreutils. See [`Containerfile`](Containerfile).

## Features

- **Per-chat containers**: Create a container for each chat, restart it when reopened, and stop it when closed.
- **Workspace mounting**: Mount the current working directory at the same absolute path; recreate the container after `/cd`.
- **Container-based tools**: Run `bash`, `read`, `write`, `edit`, `list`, `glob`, `grep`, `index`, `view_image`, and related tools against the container filesystem.
- **Original tool behavior**: Preserve tool interfaces, permission checks, editing safeguards, background commands, memory, and skills.
- **Persistent project files**: Changes to mounted project files remain on the host.
