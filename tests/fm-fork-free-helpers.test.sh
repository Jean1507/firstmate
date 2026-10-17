#!/usr/bin/env bash
# tests/fm-fork-free-helpers.test.sh - the pure-bash stand-ins that the
# watcher, drain, and lock paths use instead of forking small external
# commands every cycle. Each case compares the helper with the command it
# replaces on the same input, under every available Bash (stock macOS
# /bin/bash 3.2 included) and under both the C and a UTF-8 locale, so an edge
# case where the two disagree fails here instead of drifting silently.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-free-helpers)

# Every distinct Bash this host offers: the running one, stock /bin/bash, and
# whatever `bash` resolves to on PATH.
test_interpreters() {
  local seen='' candidate version
  for candidate in "${BASH:-bash}" /bin/bash "$(command -v bash 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    # shellcheck disable=SC2016 # Expanded by the candidate interpreter.
    version=$("$candidate" -c 'printf "%s" "$BASH_VERSION"' 2>/dev/null) || continue
    case " $seen " in *" $version "*) continue ;; esac
    seen="$seen $version"
    printf '%s\n' "$candidate"
  done
}

test_locales() {
  printf '%s\n' C
  if locale -a 2>/dev/null | grep -qx 'C.UTF-8'; then
    printf '%s\n' C.UTF-8
  elif locale -a 2>/dev/null | grep -qx 'en_US.UTF-8'; then
    printf '%s\n' en_US.UTF-8
  fi
}

# Run <script> under every interpreter and locale; any output is a mismatch
# report and fails the case.
run_everywhere() {  # <label> <script> [args...]
  local label=$1 script=$2 interpreter loc out
  shift 2
  while IFS= read -r interpreter; do
    while IFS= read -r loc; do
      out=$(LC_ALL=$loc FM_STATE_OVERRIDE="$TMP_ROOT/state" "$interpreter" "$script" "$ROOT" "$@" 2>&1) \
        || fail "$label failed under $interpreter ($loc): $out"
      [ -z "$out" ] || fail "$label differs under $interpreter ($loc):"$'\n'"$out"
    done < <(test_locales)
  done < <(test_interpreters)
}

test_path_helpers_match_dirname_and_basename() {
  local script="$TMP_ROOT/paths.sh" cases="$TMP_ROOT/path-cases"
  # NUL-separated so paths may carry newlines.
  printf '%s\0' '' / // /// a a/ a// /a /a/ //a a/b a/b/ a//b //a//b/ . .. ./ ../x \
    'a b/c d' 'a/-x' $'a\n/b' $'a/b\n' $'x\n' $'a/b\n\n' $'a\n' $'\n' $'/\n' $'a/\n/' \
    'state/crew.status' '/abs/state/.seen-x' 'x.y.z/.status' '*/?' 'a/[b]' \
    $'caf\xc3\xa9/\xc3\xbc.status' $'\xff\xfe/\xc3.x' $'a/\xff/' > "$cases"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
while IFS= read -r -d '' p; do
  fm_dirname_to got "$p"
  want=$(dirname -- "$p")
  [ "$got" = "$want" ] || printf 'dirname %q: helper %q, command %q\n' "$p" "$got" "$want"
  fm_basename_to got "$p"
  want=$(basename -- "$p")
  [ "$got" = "$want" ] || printf 'basename %q: helper %q, command %q\n' "$p" "$got" "$want"
done < "$2"
SH
  run_everywhere "path helpers" "$script" "$cases"
  pass "fm_dirname_to and fm_basename_to match dirname and basename on every edge case"
}

test_epoch_helper_matches_date_and_never_forks_more() {
  local script="$TMP_ROOT/epoch.sh" shim="$TMP_ROOT/epoch-shim" log="$TMP_ROOT/epoch-date.log"
  mkdir -p "$shim"
  cat > "$shim/date" <<SH
#!/bin/sh
printf 'date\n' >> "$log"
exec $(command -v date) "\$@"
SH
  chmod +x "$shim/date"
  # shellcheck disable=SC2016 # Expanded by the child shell.
  printf '%s\n' '. "$1/bin/fm-wake-lib.sh"' \
    'PATH="$2:$PATH"' \
    ': > "$3"' \
    'before=$(/bin/date +%s)' \
    'fm_epoch_seconds_to now' \
    'after=$(/bin/date +%s)' \
    'case "$now" in ""|*[!0-9]*) printf "not epoch seconds: %q\n" "$now" ;; esac' \
    '[ "$now" -ge "$before" ] && [ "$now" -le "$after" ] || printf "%s outside [%s, %s]\n" "$now" "$before" "$after"' \
    'forks=$(grep -c . "$3" || true)' \
    'if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then' \
    '  [ "$forks" -eq 0 ] || printf "bash %s ran date %s times\n" "$BASH_VERSION" "$forks"' \
    'else' \
    '  [ "$forks" -eq 1 ] || printf "bash %s ran date %s times, not exactly once\n" "$BASH_VERSION" "$forks"' \
    'fi' > "$script"
  run_everywhere "epoch helper" "$script" "$shim" "$log"
  pass "fm_epoch_seconds_to reads the clock like date +%s and forks date at most as often"
}

test_signal_seen_path_and_lock_abs_path_are_unchanged() {
  local script="$TMP_ROOT/seen.sh" dir="$TMP_ROOT/lockdir"
  mkdir -p "$dir/sub" "$TMP_ROOT/state"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
state=$2
for f in "$state/crew.status" "$state/a.b.c.status" "state/x.status" ".status" \
  "$state/crew.turn-ended" "$state/dir/" "x" "a.b/" "/" "$state/q.status.bak"; do
  got=$(fm_wake_signal_seen_path "$state" "$f")
  case "$f" in
    *.status)
      task=$(basename "$f"); task=${task%.status}
      want=$(printf '%s/.seen-%s' "$state" "$(printf '%s.status' "$task" | tr '.' '_')")
      ;;
    *) want=$(printf '%s/.seen-%s' "$state" "$(basename "$f" | tr '.' '_')") ;;
  esac
  [ "$got" = "$want" ] || printf 'seen path %q: helper %q, commands %q\n' "$f" "$got" "$want"
done
cd "$3" || exit 1
for p in "$3/x.lock" "$3/sub/x.lock" "$3//sub//x.lock" "sub/x.lock" "x.lock" "sub/x.lock/" "./sub/../x.lock"; do
  got=$(fm_lock_abs_path "$p")
  want="$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
  [ "$got" = "$want" ] || printf 'lock path %q: helper %q, commands %q\n' "$p" "$got" "$want"
done
SH
  run_everywhere "seen and lock paths" "$script" "$TMP_ROOT/state" "$dir"
  pass "signal seen paths and absolute lock paths are byte-identical to the dirname/basename/tr forms"
}

test_recovery_marker_read_accepts_exactly_one_newline() {
  local script="$TMP_ROOT/marker.sh" cases="$TMP_ROOT/marker-cases"
  mkdir -p "$cases"
  printf 'pending:handling:g1\n' > "$cases/one"
  printf 'pending:handling:g1' > "$cases/unterminated"
  printf 'pending:handling:g1\npending:handling:g2\n' > "$cases/two"
  printf 'pending:handling:g1\ntrailing-partial' > "$cases/partial-second"
  : > "$cases/empty"
  printf '\n' > "$cases/blank"
  printf 'announced:downtime:g\0x\n' > "$cases/nul"
  printf 'acked:handling:g1\r\n' > "$cases/crlf"
  printf 'pending:handling:g1\n\n' > "$cases/blank-second"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
for marker in "$2"/*; do
  # The replaced reference: one newline byte by wc -l, then the same token read.
  want=reject
  if [ "$(wc -l < "$marker" | tr -d '[:space:]')" = 1 ] && IFS= read -r line < "$marker"; then
    case "$line" in
      pending:handling:*|pending:downtime:*|announced:handling:*|announced:downtime:*|acked:handling:*|acked:downtime:*)
        case "${line##*:}" in ''|*[!A-Za-z0-9._-]*) ;; *) want="accept:$line" ;; esac ;;
    esac
  fi
  if fm_recovery_marker_read "$marker"; then got="accept:$FM_RECOVERY_MARKER_TOKEN"; else got=reject; fi
  [ "$got" = "$want" ] || printf 'marker %s: helper %q, reference %q\n' "${marker##*/}" "$got" "$want"
done
SH
  run_everywhere "recovery marker read" "$script" "$cases"
  pass "recovery marker reads accept exactly the one-line records wc -l accepted"
}

test_window_to_task_matches_the_meta_pipeline() {
  local script="$TMP_ROOT/window.sh" state="$TMP_ROOT/window-state"
  mkdir -p "$state"
  printf 'window=sess:w1\nbackend=tmux\n' > "$state/alpha.meta"
  printf 'window=old\nwindow=sess:w2\n' > "$state/beta.meta"
  printf 'terminal=term-3\nwindow=\n' > "$state/gamma.meta"
  printf 'window=a=b=c' > "$state/delta.meta"
  printf 'window=sess:w5\r\n' > "$state/eps.meta"
  printf ' window=sess:w6\nwindow= sess:w6 \n' > "$state/zeta.meta"
  printf 'terminal=t7\nterminal=\n' > "$state/eta.meta"
  mkdir -p "$state/dir.meta"
  printf 'window=sess:w9\n' > "$state/theta.meta"
  chmod 000 "$state/theta.meta"
  cat > "$script" <<'SH'
. "$1/bin/fm-classify-lib.sh"
state=$2
reference() {  # the replaced grep | tail -1 | cut -d= -f2- lookup
  local w=$1 meta mw mt t
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
    t=$(basename "$meta"); printf '%s' "${t%.meta}"; return 0
  done
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}
for w in sess:w1 old sess:w2 term-3 '' a=b=c a sess:w5 $'sess:w5\r' ' sess:w6 ' sess:w6 t7 sess:w9 sess:fm-fallback-x unknown; do
  got=$(window_to_task "$w" "$state")
  want=$(reference "$w")
  [ "$got" = "$want" ] || printf 'window %q: helper %q, pipeline %q\n' "$w" "$got" "$want"
done
SH
  run_everywhere "window_to_task" "$script" "$state"
  chmod 600 "$state/theta.meta"
  pass "window_to_task resolves every recorded window exactly as the grep/tail/cut pipeline did"
}

test_classify_stat_helpers_read_the_kernel_name_once() {
  local script="$TMP_ROOT/uname.sh" shim="$TMP_ROOT/uname-shim" log="$TMP_ROOT/uname.log" file="$TMP_ROOT/sized"
  mkdir -p "$shim"
  cat > "$shim/uname" <<SH
#!/bin/sh
printf 'uname\n' >> "$log"
exec $(command -v uname) "\$@"
SH
  chmod +x "$shim/uname"
  printf 'caf\303\251 bytes\n' > "$file"
  cat > "$script" <<'SH'
PATH="$2:$PATH"
: > "$3"
. "$1/bin/fm-classify-lib.sh"
for _ in 1 2 3 4 5; do
  size=$(_fm_status_file_size "$4")
  [ "$size" = "$(LC_ALL=C wc -c < "$4" | tr -d ' ')" ] || printf 'size %q\n' "$size"
  mtime=$(_fm_status_file_mtime "$4")
  case "$mtime" in ''|*[!0-9]*) printf 'mtime %q\n' "$mtime" ;; esac
  _fm_open_decisions_file_ident "$4" >/dev/null || printf 'identity unreadable\n'
done
calls=$(grep -c . "$3" || true)
[ "$calls" -eq 1 ] || printf 'uname ran %s times for 15 stat reads\n' "$calls"
SH
  run_everywhere "classify stat helpers" "$script" "$shim" "$log" "$file"
  pass "classify stat helpers resolve the kernel name once per process"
}

# Status-file fixtures covering every object kind a status path can hold.
make_status_fixtures() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  printf 'working: one\nneeds-decision [key=a]: two\n' > "$dir/full.status"
  : > "$dir/empty.status"
  printf 'sticky\n' > "$dir/sticky.status"; chmod 1644 "$dir/sticky.status"
  printf 'setuid\n' > "$dir/setuid.status"; chmod 4755 "$dir/setuid.status"
  printf 'hidden\n' > "$dir/unreadable.status"; chmod 000 "$dir/unreadable.status"
  ln -s full.status "$dir/link.status"
  ln -s missing-target "$dir/dangling.status"
  mkdir -p "$dir/dir.status"
  mkfifo "$dir/fifo.status" 2>/dev/null || true
}

# The reference below is the per-field stat(1) reading these helpers replaced:
# three launches for the identity, one each for size, mtime and path state, and
# od | tr for the signature encoding. Every helper must agree with it on every
# fixture, with and without the bash `stat` builtin, and when the one-launch
# format is unavailable (forced here by an unparseable format).
test_status_stat_helpers_match_the_per_field_stat_reads() {
  local script="$TMP_ROOT/status-stat.sh" dir="$TMP_ROOT/status-stat"
  make_status_fixtures "$dir"
  cat > "$script" <<'SH'
. "$1/bin/fm-classify-lib.sh"
[ "${FM_TEST_NO_LOADABLES:-}" != 1 ] || ! fm_loadable_ready stat || printf 'stat builtin still loaded under FM_TEST_NO_LOADABLES\n'
[ "${3:-}" != legacy-format ] || _FM_STATUS_STAT_FORMAT='%d'
ref_ident() {
  local f=$1 epoch birth ident
  if [ "$(uname -s)" = Darwin ]; then
    ident=$(LC_ALL=C /usr/bin/stat -f '%d:%i' "$f" 2>/dev/null) || return 1
    epoch=$(LC_ALL=C /usr/bin/stat -f '%B' "$f" 2>/dev/null) || epoch=0
    if [ "$epoch" != 0 ]; then birth=$(LC_ALL=C /usr/bin/stat -f '%FB' "$f" 2>/dev/null) || birth=''; else birth=''; fi
  else
    ident=$(LC_ALL=C stat -c '%d:%i' "$f" 2>/dev/null) || return 1
    epoch=$(LC_ALL=C stat -c '%W' "$f" 2>/dev/null) || epoch=0
    if [ "$epoch" != 0 ]; then birth=$(LC_ALL=C stat -c '%w' "$f" 2>/dev/null) || birth=''; else birth=''; fi
  fi
  case "$ident$birth" in *$'\t'*|*$'\n'*|'') return 1 ;; esac
  if [ -n "$birth" ]; then printf 'strong:%s:%s' "$ident" "$birth"; else printf 'weak:%s' "$ident"; fi
}
ref_field() {  # <darwin-format> <gnu-format> <file>
  if [ "$(uname -s)" = Darwin ]; then LC_ALL=C /usr/bin/stat -f "$1" "$3" 2>/dev/null
  else LC_ALL=C stat -c "$2" "$3" 2>/dev/null; fi
}
ref_signature() {
  local f=$1 size ident path_state link_target=- access kind
  path_state=$(ref_field '%HT:%p' '%F:%f' "$f") || path_state=stat-error
  if [ -L "$f" ]; then
    link_target=$(readlink "$f" 2>/dev/null) || link_target=readlink-error
    kind=symlink
  elif [ ! -e "$f" ]; then kind=absent
  elif [ ! -f "$f" ]; then kind=nonregular
  elif [ -r "$f" ]; then kind=readable
  else kind=unreadable
  fi
  size=$(ref_field '%z' '%s' "$f") || size='size-error'
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) size='size-error' ;; esac
  ident=$(ref_ident "$f") || ident=identity-error
  [ -n "$ident" ] || ident=identity-error
  if [ -r "$f" ]; then access=readable; else access=unreadable; fi
  printf 'r1:%s' "$(printf '%s\0%s\0%s\0%s\0%s\0%s' "$size" "$ident" "$path_state" "$link_target" "$access" "$kind" \
    | LC_ALL=C od -An -v -tx1 | tr -d ' \n')"
}
compare() {  # <label> <helper-output> <helper-rc> <reference-output> <reference-rc>
  [ "$2:$3" = "$4:$5" ] || printf '%s: helper %q rc=%s, reference %q rc=%s\n' "$1" "$2" "$3" "$4" "$5"
}
status_stat_cache_refresh "$2"/*.status "$2/missing.status"
for f in "$2"/*.status "$2/missing.status"; do
  got=$(_fm_open_decisions_file_ident "$f"); grc=$?
  want=$(ref_ident "$f"); wrc=$?
  compare "identity ${f##*/}" "$got" "$grc" "$want" "$wrc"
  got=$(_fm_status_file_size "$f"); grc=$?
  want=$(ref_field '%z' '%s' "$f"); wrc=$?
  compare "size ${f##*/}" "$got" "$grc" "$want" "$wrc"
  got=$(_fm_status_file_mtime "$f"); grc=$?
  want=$(ref_field '%m' '%Y' "$f"); wrc=$?
  compare "mtime ${f##*/}" "$got" "$grc" "$want" "$wrc"
  got=$(status_observed_signature "$f"); grc=$?
  want=$(ref_signature "$f"); wrc=$?
  compare "signature ${f##*/}" "$got" "$grc" "$want" "$wrc"
done
SH
  run_everywhere "status stat helpers" "$script" "$dir"
  FM_TEST_NO_LOADABLES=1 run_everywhere "status stat helpers without builtins" "$script" "$dir"
  run_everywhere "status stat helpers on the per-field fallback" "$script" "$dir" legacy-format
  chmod 600 "$dir/unreadable.status"
  pass "status identity, size, mtime and signature match the per-field stat reads on every path kind and fallback"
}

# The birth cache only pays off when a primed, unchanged file is read with no
# stat(1) launch, and it is only safe when every change to the path forces a
# fresh read. External reads are counted by wrapping the one helper that
# launches stat(1).
test_status_stat_cache_serves_unchanged_files_and_rereads_changed_ones() {
  local script="$TMP_ROOT/stat-cache.sh" dir="$TMP_ROOT/stat-cache" out
  mkdir -p "$dir"
  printf 'working: a\n' > "$dir/a.status"
  printf 'working: b\n' > "$dir/b.status"
  printf 'working: c\n' > "$dir/c.status"
  # Cached records need a ctime more than a second before the refresh.
  sleep 2.2
  cat > "$script" <<'SH'
. "$1/bin/fm-classify-lib.sh"
d=$2
if [ "$_FM_STATUS_STAT_BUILTIN" != loaded ]; then
  printf 'skip: no bash stat builtin\n'
  exit 0
fi
eval "_fm_counted_$(declare -f _fm_status_stat_external)"
_fm_status_stat_external() { printf 'x' >> "$d/.external"; _fm_counted__fm_status_stat_external "$@"; }
external() { local n=0; [ ! -e "$d/.external" ] || n=$(wc -c < "$d/.external"); : > "$d/.external"; printf '%s' "$((n))"; }
ref() { LC_ALL=C /usr/bin/stat -f 'strong:%d:%i:%FB' "$1"; }
check() {  # <label> <file> <expected-external-reads>
  local got want n
  got=$(_fm_open_decisions_file_ident "$2"); want=$(ref "$2")
  [ "$got" = "$want" ] || printf '%s: identity %q, want %q\n' "$1" "$got" "$want"
  status_observed_signature "$2" >/dev/null
  n=$(external)
  [ "$n" = "$3" ] || printf '%s: %s stat(1) reads, want %s\n' "$1" "$n" "$3"
}
: > "$d/.external"
status_stat_cache_refresh "$d"/*.status
n=$(external); [ "$n" = 0 ] || printf 'refresh used the per-file reader %s times\n' "$n"
check "unchanged a" "$d/a.status" 0
check "unchanged b" "$d/b.status" 0
printf 'working: more\n' >> "$d/a.status"
check "appended a" "$d/a.status" 2
chmod 600 "$d/b.status"
got=$(status_observed_signature "$d/b.status")
_FM_STATUS_STAT_CACHE_PATHS=(); _FM_STATUS_STAT_CACHE_RECORDS=()
want=$(status_observed_signature "$d/b.status")
[ "$got" = "$want" ] || printf 'chmod b: signature kept the cached path state\n'
external >/dev/null
status_stat_cache_refresh "$d"/*.status
printf 'working: replaced\n' > "$d/c.new"; mv -f "$d/c.new" "$d/c.status"
check "replaced c" "$d/c.status" 2
printf 'working: fresh\n' > "$d/new.status"
status_stat_cache_refresh "$d"/*.status
check "created in the refresh second" "$d/new.status" 2
SH
  out=$("${BASH:-bash}" "$script" "$ROOT" "$dir" 2>&1) || fail "stat cache script failed: $out"
  case "$out" in
    'skip: no bash stat builtin')
      printf 'skip: no bash stat builtin; the birth cache is exercised only where bash ships its stat loadable\n'
      return 0
      ;;
  esac
  [ -z "$out" ] || fail "stat cache:"$'\n'"$out"
  pass "the birth cache serves unchanged status files with no stat(1) launch and rereads every changed one"
}

# Each fork-free file stand-in must leave the same result and status as the
# command it replaces, and must run a command placed first on PATH instead of
# its fork-free route, so tests and callers that interpose their own tool keep
# that seam.
test_fork_free_file_commands_match_and_keep_path_overrides() {
  local script="$TMP_ROOT/file-commands.sh" dir="$TMP_ROOT/file-commands" shim="$TMP_ROOT/file-shim" log="$TMP_ROOT/file-shim.log"
  mkdir -p "$dir/d" "$shim"
  printf 'one\n\n\n' > "$dir/trailing"
  : > "$dir/empty"
  printf 'x' > "$dir/plain"
  printf 'no' > "$dir/unreadable"; chmod 000 "$dir/unreadable"
  ln -s /abs/target "$dir/abs-link"
  ln -s rel/target "$dir/rel-link"
  ln -s plain "$dir/file-link"
  for tool in cat readlink rm; do
    cat > "$shim/$tool" <<SH
#!/bin/sh
printf '%s\n' "$tool" >> "$log"
exec $(command -v "$tool") "\$@"
SH
    chmod +x "$shim/$tool"
  done
  cat > "$script" <<'SH'
. "$1/bin/fm-path-lib.sh"
d=$2
if [ "${FM_TEST_NO_LOADABLES:-}" = 1 ]; then
  for b in stat rm rmdir ln mktemp chmod; do
    ! fm_loadable_ready "$b" || printf '%s builtin still loaded under FM_TEST_NO_LOADABLES\n' "$b"
  done
fi
for f in trailing empty plain unreadable missing d abs-link; do
  want=$(cat "$d/$f" 2>/dev/null); wrc=$?
  got=; fm_read_file_to got "$d/$f"; grc=$?
  [ "$got:$grc" = "$want:$wrc" ] || printf 'read %s: helper %q rc=%s, cat %q rc=%s\n' "$f" "$got" "$grc" "$want" "$wrc"
  got=$(fm_read_file "$d/$f"); grc=$?
  [ "$got:$grc" = "$want:$wrc" ] || printf 'read stdout %s: helper %q rc=%s, cat %q rc=%s\n' "$f" "$got" "$grc" "$want" "$wrc"
done
for f in abs-link rel-link file-link plain missing d; do
  want=$(readlink "$d/$f" 2>/dev/null); wrc=$?
  got=; fm_readlink_to got "$d/$f" 2>/dev/null; grc=$?
  [ "$got:$grc" = "$want:$wrc" ] || printf 'readlink %s: helper %q rc=%s, readlink %q rc=%s\n' "$f" "$got" "$grc" "$want" "$wrc"
done
mkdir -p "$d/ops"
owner=$(fm_loadable_run mktemp -d "$d/ops/lock.owner.XXXXXX") || printf 'mktemp -d failed\n'
case "$owner" in "$d/ops/lock.owner."??????) ;; *) printf 'mktemp -d named %q\n' "$owner" ;; esac
[ -d "$owner" ] || printf 'mktemp -d created no directory\n'
fm_loadable_run ln -s "$owner" "$d/ops/lock" || printf 'ln -s failed\n'
[ "$(readlink "$d/ops/lock")" = "$owner" ] || printf 'ln -s pointed elsewhere\n'
fm_loadable_run ln -s "$owner" "$d/ops/lock" 2>/dev/null
[ -L "$owner/${owner##*/}" ] || printf 'ln -s through an existing directory link did not link inside it, as ln does\n'
f=$(fm_loadable_run mktemp "$d/ops/marker.tmp.XXXXXX") || printf 'mktemp failed\n'
fm_loadable_run chmod 0600 "$f" || printf 'chmod failed\n'
[ "$(ls -l "$f" | cut -c1-10)" = '-rw-------' ] || printf 'chmod 0600 left %s\n' "$(ls -l "$f" | cut -c1-10)"
fm_loadable_run rm -f -- "$f" "$d/ops/never-there" || printf 'rm -f failed on a missing operand\n'
[ ! -e "$f" ] || printf 'rm -f left the file\n'
fm_loadable_run rm -f "$owner/${owner##*/}" "$d/ops/lock"
fm_loadable_run rmdir "$owner" || printf 'rmdir failed\n'
[ ! -e "$owner" ] && [ ! -L "$d/ops/lock" ] || printf 'rm/rmdir left lock state behind\n'
: > "$4"
PATH="$3:$PATH"
fm_read_file_to got "$d/plain"; fm_readlink_to got "$d/abs-link"; fm_loadable_run rm -f "$d/ops/none"
[ "$(sort "$4" | tr '\n' ' ')" = 'cat readlink rm ' ] || printf 'PATH override not honored: ran %q\n' "$(sort "$4" | tr '\n' ' ')"
shim_log=$4
rm() { printf 'function\n' >> "$shim_log"; }
: > "$4"
fm_loadable_run rm -f "$d/ops/none"
unset -f rm
IFS= read -r ran < "$shim_log" || ran=
[ "$ran" = function ] || printf 'shell function override not honored: ran %q\n' "$ran"
rm -rf "$d/ops"
SH
  run_everywhere "fork-free file commands" "$script" "$dir" "$shim" "$log"
  FM_TEST_NO_LOADABLES=1 run_everywhere "fork-free file commands without builtins" "$script" "$dir" "$shim" "$log"
  chmod 600 "$dir/unreadable"
  pass "fork-free read, readlink, rm, rmdir, ln, mktemp and chmod match the commands and keep PATH and function overrides"
}

test_pending_reply_record_reads_match_the_pipelines() {
  local script="$TMP_ROOT/pending-reply.sh" dir="$TMP_ROOT/pending-reply"
  mkdir -p "$dir/status"
  printf 'phase=a\ntask_id=t1\nphase=b=c\nempty=\n delivered_epoch=1\ndelivered_epoch=2\nphase_x=no\nlast=unterminated' > "$dir/record"
  printf 'x\r\nphase=crlf\r\n' > "$dir/crlf"
  printf 'one\n' > "$dir/status/a.status"
  ln -s a.status "$dir/status/link.status"
  printf 'two\n' > "$dir/status/b.status"; chmod 000 "$dir/status/b.status"
  cat > "$script" <<'SH'
. "$1/bin/fm-pending-reply-lib.sh"
d=$2
[ "${FM_TEST_NO_LOADABLES:-}" != 1 ] || ! fm_loadable_ready stat || printf 'stat builtin still loaded under FM_TEST_NO_LOADABLES\n'
for rec in record crlf missing status; do
  for key in phase task_id empty delivered_epoch last phase_x absent; do
    want=$(grep "^${key}=" "$d/$rec" 2>/dev/null | tail -1 | cut -d= -f2- || true; printf .)
    got=$(fm_pending_reply_get "$d/$rec" "$key"; printf .)
    [ "$got" = "$want" ] || printf 'get %s %s: helper %q, pipeline %q\n' "$rec" "$key" "$got" "$want"
  done
done
for f in "$d"/status/*.status "$d/status/missing.status" "$d/record"; do
  if [ ! -f "$f" ]; then want=missing
  elif [ "$(uname -s)" = Darwin ]; then want=$(LC_ALL=C /usr/bin/stat -f '%d:%i:%z:%m:%c' "$f" 2>/dev/null || printf 'unreadable')
  else want=$(LC_ALL=C stat -c '%d:%i:%s:%Y:%Z' "$f" 2>/dev/null || printf 'unreadable'); fi
  got=$(fm_pending_reply_file_signature "$f")
  [ "$got" = "$want" ] || printf 'signature %s: helper %q, stat %q\n' "${f##*/}" "$got" "$want"
done
SH
  run_everywhere "pending-reply record reads" "$script" "$dir"
  FM_TEST_NO_LOADABLES=1 run_everywhere "pending-reply record reads without builtins" "$script" "$dir"
  chmod 600 "$dir/status/b.status"
  pass "pending-reply field reads and file signatures match the grep/tail/cut and stat pipelines"
}

test_wake_clean_field_matches_tr() {
  local script="$TMP_ROOT/clean-field.sh" cases="$TMP_ROOT/clean-field-cases"
  printf '%s\0' '' plain $'a\tb' $'x\r\ny\n' $'caf\xc3\xa9\tz\n\n' $'\xff\t\xfe\n' $'\n\n' > "$cases"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
while IFS= read -r -d '' t; do
  want=$(printf '%s' "$t" | LC_ALL=C tr '\t\r\n' '   ')
  fm_wake_clean_field_to got "$t"
  [ "$got" = "$want" ] || printf 'clean %q: helper %q, tr %q\n' "$t" "$got" "$want"
  got=$(printf '%s' "$t" | fm_wake_clean_field)
  [ "$got" = "$want" ] || printf 'clean filter %q: helper %q, tr %q\n' "$t" "$got" "$want"
done < "$2"
SH
  run_everywhere "wake clean field" "$script" "$cases"
  pass "wake row fields are cleaned exactly as tr did"
}

test_lock_release_keeps_the_owner_when_the_link_survives() {
  local script="$TMP_ROOT/lock-release.sh" dir="$TMP_ROOT/lock-release"
  if [ "$(id -u)" = 0 ]; then
    pass "lock release owner retention skipped as root (directory permissions do not block root)"
    return
  fi
  mkdir -p "$dir"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
d=$(mktemp -d "$2/run.XXXXXX") || exit 1
lock="$d/q.lock"
fm_lock_try_acquire "$lock" || { printf 'acquire failed\n'; exit 0; }
owner=$(fm_lock_link_owner "$lock")
chmod 555 "$d"
fm_lock_release "$lock"
chmod 755 "$d"
[ -L "$lock" ] || printf 'lock link was unlinked from a read-only directory\n'
[ -f "$owner/pid" ] || printf 'release discarded the owner record while the lock link still names it\n'
fm_lock_release "$lock"
[ ! -L "$lock" ] && [ ! -e "$owner" ] || printf 'release in a writable directory left the lock link or owner behind\n'
SH
  run_everywhere "lock release with a surviving link" "$script" "$dir"
  pass "lock release keeps the owner record while an unlink failure leaves the lock link in place"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
else
  test_path_helpers_match_dirname_and_basename
  test_epoch_helper_matches_date_and_never_forks_more
  test_signal_seen_path_and_lock_abs_path_are_unchanged
  test_recovery_marker_read_accepts_exactly_one_newline
  test_window_to_task_matches_the_meta_pipeline
  test_classify_stat_helpers_read_the_kernel_name_once
  test_status_stat_helpers_match_the_per_field_stat_reads
  test_status_stat_cache_serves_unchanged_files_and_rereads_changed_ones
  test_fork_free_file_commands_match_and_keep_path_overrides
  test_wake_clean_field_matches_tr
  test_pending_reply_record_reads_match_the_pipelines
  test_lock_release_keeps_the_owner_when_the_link_survives
fi
