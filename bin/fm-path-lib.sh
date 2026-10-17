#!/usr/bin/env bash
# fm-path-lib.sh - fork-free pathname and file helpers with no source-time side
# effects, so read-only callers can load them without any library's state setup.
#
# fm_dirname_to and fm_basename_to assign <output-variable> exactly what
# `$(dirname -- <path>)` or `$(basename -- <path>)` would: POSIX component rules,
# and the command substitution's removal of trailing newlines.
#
# The remaining helpers stand in for single external commands on the watcher,
# drain, and lock hot paths, where a host whose endpoint agent inspects every
# process launch pays tens to hundreds of milliseconds per launch. Each takes its
# fork-free route only on Bash 4 or newer and only when the command name resolves
# through the caller's PATH to the platform's own /bin or /usr/bin tool and no
# shell function of that name exists, so a caller or test that interposes its
# own command or function runs it exactly as before; otherwise, and on stock
# macOS Bash 3.2, it runs the command by that name.
#
#   fm_loadable_ready <name>
#       0 when the running bash's own loadable builtin <name> is loaded. Homebrew
#       bash 5 installs these in <prefix>/lib/bash. A builtin is loaded on first
#       use and kept disabled, so the name still resolves to the external tool
#       everywhere else. Test seam: FM_TEST_NO_LOADABLES=1 disables every
#       builtin when FM_TEST_SEAM=1, so a suite can run the external-tool
#       fallback on a host that has them (tests/lib.sh arms the marker).
#   fm_loadable_run <rm|rmdir|ln|mktemp|chmod> [args...]
#       Runs the command through its builtin, re-enabled for that one call, or
#       through the external tool. Those builtins match the external tools for
#       the options firstmate passes: rm -f, rmdir, ln -s, mktemp -d, and an
#       octal chmod.
#   fm_lstat_to <assoc-array> <path>
#       Fills the caller's associative array from one lstat(2) through the
#       `stat` builtin: device, inode, size, mtime, ctime, perms, type, and
#       link (the symlink target). Returns 1 when lstat fails and 2 when the
#       builtin is unavailable.
#   fm_readlink_to <output-variable> <path>
#       Assigns what `$(readlink <path>)` would, with its exit status.
#   fm_read_file_to <output-variable> <path>
#       Assigns what `$(cat <path> 2>/dev/null)` would, with its exit status.
#   fm_read_file <path>
#       The same read printed for a command substitution: `$(fm_read_file p)`
#       forks a subshell but launches no cat(1).

fm_dirname_to() {  # <output-variable> <path>
  local fm_path=$2
  case "$fm_path" in
    '') fm_path=. ;;
    *[!/]*)
      fm_path=${fm_path%"${fm_path##*[!/]}"}
      case "$fm_path" in
        */*)
          fm_path=${fm_path%/*}
          fm_path=${fm_path%"${fm_path##*[!/]}"}
          [ -n "$fm_path" ] || fm_path=/
          ;;
        *) fm_path=. ;;
      esac
      ;;
    *) fm_path=/ ;;
  esac
  while [ "${fm_path%$'\n'}" != "$fm_path" ]; do fm_path=${fm_path%$'\n'}; done
  printf -v "$1" '%s' "$fm_path"
}

fm_basename_to() {  # <output-variable> <path>
  local fm_path=$2
  case "$fm_path" in
    '') ;;
    *[!/]*) fm_path=${fm_path%"${fm_path##*[!/]}"}; fm_path=${fm_path##*/} ;;
    *) fm_path=/ ;;
  esac
  while [ "${fm_path%$'\n'}" != "$fm_path" ]; do fm_path=${fm_path%$'\n'}; done
  printf -v "$1" '%s' "$fm_path"
}

# 0 when <name> is no shell function and resolves through PATH to the
# platform's own tool.
_fm_system_tool() {  # <name>
  local fm_tool
  [ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || return 1
  ! declare -F "$1" >/dev/null || return 1
  hash "$1" 2>/dev/null || return 1
  fm_tool=${BASH_CMDS[$1]-}
  [ "$fm_tool" = "/bin/$1" ] || [ "$fm_tool" = "/usr/bin/$1" ]
}

fm_loadable_ready() {  # <name>
  local fm_state_var="_FM_LOADABLE_STATE_$1" fm_lib
  case "${!fm_state_var-}" in
    loaded) return 0 ;;
    absent) return 1 ;;
  esac
  printf -v "$fm_state_var" '%s' absent
  [ "${FM_TEST_SEAM:-}" != 1 ] || [ "${FM_TEST_NO_LOADABLES:-}" != 1 ] || return 1
  [ "${BASH_VERSINFO[0]:-0}" -ge 5 ] || return 1
  [ "$(type -t "$1")" != builtin ] || return 1
  fm_lib=${BASH%/bin/*}/lib/bash/$1
  [ -f "$fm_lib" ] || return 1
  enable -f "$fm_lib" "$1" 2>/dev/null || return 1
  enable -n "$1" 2>/dev/null || return 1
  printf -v "$fm_state_var" '%s' loaded
}

fm_loadable_run() {  # <rm|rmdir|ln|mktemp|chmod> [args...]
  local fm_rc
  case "$1" in
    rm|rmdir|ln|mktemp|chmod)
      if _fm_system_tool "$1" && fm_loadable_ready "$1"; then
        enable "$1"
        builtin "$@" && fm_rc=0 || fm_rc=$?
        enable -n "$1"
        return "$fm_rc"
      fi
      ;;
  esac
  "$@"
}

fm_lstat_to() {  # <assoc-array> <path>
  local fm_rc
  fm_loadable_ready stat || return 2
  enable stat
  builtin stat -L -A "$1" -- "$2" 2>/dev/null && fm_rc=0 || fm_rc=1
  enable -n stat
  return "$fm_rc"
}

fm_readlink_to() {  # <output-variable> <path>
  local fm_target
  if _fm_system_tool readlink && fm_loadable_ready stat; then
    local -A fm_link_st=()
    fm_lstat_to fm_link_st "$2" && [ "${fm_link_st[type]-}" = l ] || return 1
    fm_target=${fm_link_st[link]-}
    while [ "${fm_target%$'\n'}" != "$fm_target" ]; do fm_target=${fm_target%$'\n'}; done
  else
    fm_target=$(readlink "$2") || return 1
  fi
  printf -v "$1" '%s' "$fm_target"
}

fm_read_file_to() {  # <output-variable> <path>
  local fm_content
  if _fm_system_tool cat; then
    # A directory opens without error but cat still fails reading it.
    [ ! -d "$2" ] || return 1
    { fm_content=$(<"$2"); } 2>/dev/null || return 1
  else
    fm_content=$(cat "$2" 2>/dev/null) || return 1
  fi
  printf -v "$1" '%s' "$fm_content"
}

fm_read_file() {  # <path>
  local fm_file_content
  fm_read_file_to fm_file_content "$1" || return 1
  printf '%s' "$fm_file_content"
}
