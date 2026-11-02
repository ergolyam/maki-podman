local M = {}

local function quote(text)
  return "'" .. text:gsub("'", "'\\''") .. "'"
end

-- Each invocation gets its own session/process group. Only a member of
-- that group sends the kill, so cancellation never trusts a reusable PID.
local supervisor = [[
token=$1
shell=$2
command=$3
workdir=${4-}
case "$token" in
  ''|*[!A-Za-z0-9_-]*) printf '%s\n' 'Invalid command token' >&2; exit 125 ;;
esac
command_umask=$(umask)
umask 077
record=/tmp/maki-podman-bash/$token
mkdir -p "$record" || exit 125
if [ -e "$record/cancelled" ]; then
  rm -rf "$record"
  exit 130
fi
mkfifo "$record/control" || exit 125
exec 3<>"$record/control" || exit 125

cancel_group() {
  kill -KILL 0
}

(
  [ ! -e "$record/cancelled" ] || cancel_group
  IFS= read -r action <&3
  [ "$action" != cancel ] || cancel_group
) &

run_command() {
  [ ! -e "$record/cancelled" ] || cancel_group
  case "$workdir" in
    '~'|'~/'*)
      if [ -z "${HOME-}" ]; then
        printf '%s\n' 'Cannot expand workdir: HOME is not set in the container' >&2
        return 125
      fi
      workdir=$HOME${workdir#\~}
      ;;
    -*) workdir=./$workdir ;;
  esac
  if [ -n "$workdir" ]; then
    CDPATH= cd "$workdir" || return 125
  fi
  (umask "$command_umask"; exec "$shell" -c "$command" 3>&-)
}

run_command
status=$?
printf '%s\n' "$status" > "$record/status"
cancel_group
]]

-- /bin/sh -c launch maki-exec TOKEN SHELL COMMAND [WORKDIR]
-- Starting setsid as a background child prevents its BusyBox implementation
-- from forking away from a process-group leader and returning prematurely.
M.launch = [[
token=$1
case "$token" in
  ''|*[!A-Za-z0-9_-]*) printf '%s\n' 'Invalid command token' >&2; exit 125 ;;
esac
record=/tmp/maki-podman-bash/$token
]] .. "setsid /bin/sh -c " .. quote(supervisor)
  .. [[ maki-command "$1" "$2" "$3" "${4-}" &
wait "$!" 2>/dev/null
status=$?
if [ -f "$record/status" ]; then
  IFS= read -r status < "$record/status"
fi
rm -rf "$record"
exit "$status"
]]

-- /bin/sh -c cancel maki-cancel TOKEN
-- The marker also handles cancellation before the launcher creates its FIFO.
-- Opening both ends keeps this helper from blocking after a command exits.
M.cancel = [[
token=$1
case "$token" in
  ''|*[!A-Za-z0-9_-]*) exit 125 ;;
esac
umask 077
record=/tmp/maki-podman-bash/$token
mkdir -p "$record" || exit 125
: > "$record/cancelled" || exit 125
if [ -p "$record/control" ]; then
  exec 3<>"$record/control" || exit 0
  printf 'cancel\n' >&3
fi
]]

-- /bin/sh -c check maki-check SHELL
M.check = [[
for executable in setsid mkfifo mkdir rm "$1"; do
  if ! command -v "$executable" >/dev/null 2>&1; then
    printf 'Container image is missing required executable: %s\n' "$executable" >&2
    exit 125
  fi
done
]]

return M
