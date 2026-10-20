#!/usr/bin/env bash
# Live driver: build a busy-home fixture inside one guarded fm-lab-* Herdr
# session, run one variant of bin/fm-herdr-session-cleanup.sh exactly the way
# bin/fm-session-start.sh does (a subprocess with FM_HOME set), then report the
# outcome. All Herdr traffic is routed through bin/fm-herdr-lab.sh run.
#
# Usage: live-cleanup-driver.sh <variant-root> <label> <scale|race> <result-file>
#   <variant-root> is a firstmate tree whose bin/fm-herdr-session-cleanup.sh is
#   the variant under test. The lab helper always comes from the run worktree.
set -u

VARIANT_ROOT=$1
LABEL=$2
MODE=$3
RESULT=$4
WORKTREE=/Users/jean/.no-mistakes/worktrees/8d109a2da9da/01M5C4W10HA5M7TCGTBPYNA2J5
HERDR_LAB_HELPER=$WORKTREE/bin/fm-herdr-lab.sh
REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH

log() { printf '[%s] %s\n' "$LABEL" "$*"; }
die() { log "FATAL: $*"; exit 1; }

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-live-cleanup.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
OTHER_HOME="$TMP_ROOT/other-home"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/config" "$OTHER_HOME"
touch "$HOME_DIR/config/herdr-presentation-spaces"
printf '%s\n' herdr > "$HOME_DIR/config/backend"
HOME_REAL=$(cd "$HOME_DIR" && pwd -P)
STATE="$HOME_DIR/state"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name "$LABEL")
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  log "lab $HERDR_LAB_SESSION torn down (status $status)"
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null || die "provision failed"
log "provisioned lab session $HERDR_LAB_SESSION"

# Same transport shim as tests/fm-herdr-session-cleanup-e2e.test.sh, plus an
# optional one-shot hook fired on the first locked `api snapshot`, which the
# cleanup only reaches after its journal index has already been built.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
if [ -n "${RACE_HOOK:-}" ] && [ "${1:-} ${2:-}" = "api snapshot" ] && [ ! -e "$RACE_HOOK.fired" ]; then
  : > "$RACE_HOOK.fired"
  bash "$RACE_HOOK" >> "$RACE_HOOK.log" 2>&1
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
idle_proof() { # <pane>
  FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY=1 PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    bash -c '. "$1"; fm_backend_herdr_pane_idle_shell_pid "$2" "$3" >/dev/null' \
      _ "$WORKTREE/bin/fm-herdr-session-cleanup.sh" "$HERDR_LAB_SESSION" "$1"
}
focus_snapshot() {
  local list workspace tab
  list=$(lab workspace list) || return 1
  workspace=$(printf '%s' "$list" | jq -er '[.result.workspaces[] | select(.focused == true)] | select(length == 1) | .[0].workspace_id') || return 1
  tab=$(printf '%s' "$list" | jq -er --arg w "$workspace" '[.result.workspaces[] | select(.workspace_id == $w)] | .[0].active_tab_id') || return 1
  printf '%s\t%s' "$workspace" "$tab"
}
label_for() { printf '└ %s · p:%s' "${1#fm-}" "$2"; }
token_for() { printf 'LiveTok%015d' "$1"; }
write_v1() { # <id> <token>
  printf 'version=1\ntask_id=%s\nprojection_id=%s\n' "$1" "$2" > "$STATE/$1.herdr-presentation"
}
write_v2() { # <id> <token> <home> <workspace> <tab> <pane>
  {
    printf 'version=2\ntask_id=%s\nprojection_id=%s\nhome=%s\nsession=%s\n' "$1" "$2" "$3" "$HERDR_LAB_SESSION"
    printf 'workspace_id=%s\ntab_id=%s\npane_id=%s\n' "$4" "$5" "$6"
    printf 'parent_workspace_id=%s\nparent_label=firstmate\nworkspace_label=%s\ntask_label=fm-%s\n' \
      "$ANCHOR_WS" "$(label_for "$1" "$2")" "$1"
  } > "$STATE/$1.herdr-presentation"
}

ANCHOR=$(lab workspace create --cwd "$WORKTREE" --label captain-anchor --focus) || die 'anchor create failed'
ANCHOR_WS=$(printf '%s' "$ANCHOR" | jq -r '.result.workspace.workspace_id')
ANCHOR_TAB=$(printf '%s' "$ANCHOR" | jq -r '.result.tab.tab_id')
ANCHOR_PANE=$(printf '%s' "$ANCHOR" | jq -r '.result.root_pane.pane_id')
lab workspace create --cwd "$WORKTREE" --label scratch-notes --no-focus >/dev/null || die 'plain workspace create failed'

declare -A WS TAB PANE KIND
make_child() { # <n> <kind> <id>
  local n=$1 kind=$2 id=$3 token out
  token=$(token_for "$n")
  out=$(lab workspace create --cwd "$WORKTREE" --label "$(label_for "$id" "$token")" --no-focus) || die "create $id failed"
  WS[$id]=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id')
  TAB[$id]=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty')
  PANE[$id]=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')
  [ -n "${TAB[$id]}" ] || TAB[$id]=$(lab tab list --workspace "${WS[$id]}" | jq -r '.result.tabs[0].tab_id')
  KIND[$id]=$kind
  case "$kind" in
    clean-v1) write_v1 "$id" "$token" ;;
    clean-v2) write_v2 "$id" "$token" "$HOME_REAL" "${WS[$id]}" "${TAB[$id]}" "${PANE[$id]}" ;;
    duplicate) write_v1 "$id" "$token"; write_v1 "fm-$id" "$token" ;;
    cross-home) write_v2 "$id" "$token" "$OTHER_HOME" "${WS[$id]}" "${TAB[$id]}" "${PANE[$id]}" ;;
    bound-mismatch) write_v2 "$id" "$token" "$HOME_REAL" "${WS[$id]}" "${TAB[$id]}" "$ANCHOR_PANE" ;;
    busy-shell) write_v1 "$id" "$token" ;;
    live-task) write_v2 "$id" "$token" "$HOME_REAL" "${WS[$id]}" "${TAB[$id]}" "${PANE[$id]}"; : > "$STATE/$id.meta" ;;
    no-journal) ;;
  esac
}

if [ "$MODE" = scale ]; then
  make_child 1 clean-v1 stale-a
  make_child 2 clean-v2 stale-b
  make_child 3 duplicate dup-c
  make_child 4 cross-home xhome-d
  make_child 5 bound-mismatch bind-e
  make_child 6 busy-shell busy-f
  n=7; while [ "$n" -le 24 ]; do make_child "$n" live-task "live-$n"; n=$((n + 1)); done
  n=25; while [ "$n" -le 30 ]; do make_child "$n" no-journal "nojournal-$n"; n=$((n + 1)); done
  # Orphan journals for tasks with no restored workspace: half still live.
  n=31; while [ "$n" -le 70 ]; do
    id="orphan-$n"
    write_v2 "$id" "$(token_for "$n")" "$HOME_REAL" "w-gone-$n" "w-gone-$n:t1" "w-gone-$n:p1"
    [ $((n % 2)) -eq 0 ] && : > "$STATE/$id.meta"
    n=$((n + 1))
  done
  EXPECT_CLOSED="stale-a stale-b"
else
  make_child 1 clean-v1 race-dup
  make_child 2 clean-v2 race-rebind
  make_child 3 clean-v1 race-gone
  make_child 4 clean-v2 race-meta
  make_child 5 clean-v1 race-control
  n=6; while [ "$n" -le 15 ]; do make_child "$n" live-task "live-$n"; n=$((n + 1)); done
  EXPECT_CLOSED="race-control"
  RACE_HOOK="$TMP_ROOT/race-hook.sh"
  cat > "$RACE_HOOK" <<EOF
# Fired once, after the index is built and before any revalidation.
set -u
STATE='$STATE'
printf 'version=1\ntask_id=fm-race-dup\nprojection_id=%s\n' '$(token_for 1)' > "\$STATE/fm-race-dup.herdr-presentation"
sed -i '' 's/^pane_id=.*/pane_id=$ANCHOR_PANE/' "\$STATE/race-rebind.herdr-presentation"
rm -f "\$STATE/race-gone.herdr-presentation"
: > "\$STATE/race-meta.meta"
echo "race hook mutated: duplicate race-dup, rebound race-rebind, deleted race-gone, meta race-meta"
EOF
  export RACE_HOOK
fi
JOURNALS_BEFORE=$(cd "$STATE" && ls -1 ./*.herdr-presentation | sed 's#^\./##' | sort)
log "fixture: $(printf '%s\n' "${!KIND[@]}" | wc -l | tr -d ' ') token workspaces, $(printf '%s\n' "$JOURNALS_BEFORE" | wc -l | tr -d ' ') journals, $(ls "$STATE"/*.meta 2>/dev/null | wc -l | tr -d ' ') live-task metas"

# Restart the named lab so every child is a restored one-pane shell with no
# registered agent, exactly like a session start after a Herdr restart.
"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || die 'lab stop failed'
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null || die 'lab restore failed'
lab tab focus "$ANCHOR_TAB" >/dev/null || die 'anchor refocus failed'
for id in "${!KIND[@]}"; do
  case "${KIND[$id]}" in
    clean-v1|clean-v2|busy-shell)
      a=0; until idle_proof "${PANE[$id]}"; do a=$((a + 1)); [ "$a" -lt 100 ] || die "$id never became an idle shell"; sleep 0.1; done ;;
  esac
done
for id in "${!KIND[@]}"; do
  [ "${KIND[$id]}" = busy-shell ] || continue
  lab pane run "${PANE[$id]}" "sleep 900" >/dev/null || die "could not start a child in $id"
  a=0; while idle_proof "${PANE[$id]}"; do a=$((a + 1)); [ "$a" -lt 100 ] || die "$id never started its child"; sleep 0.1; done
  log "$id pane now runs a child process (not an idle shell)"
done
BEFORE_FOCUS=$(focus_snapshot) || die 'focus capture failed'
[ "$BEFORE_FOCUS" = "$ANCHOR_WS"$'\t'"$ANCHOR_TAB" ] || die "focus is not on the anchor: $BEFORE_FOCUS"
log "restored layout ready; focus on anchor $BEFORE_FOCUS"

start=$EPOCHREALTIME
FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" \
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" "$VARIANT_ROOT/bin/fm-herdr-session-cleanup.sh" \
  > "$TMP_ROOT/cleanup.out" 2>&1
cleanup_status=$?
end=$EPOCHREALTIME
ELAPSED=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.1f", e - s }')
log "cleanup exit=$cleanup_status elapsed=${ELAPSED}s"
sed 's/^/    cleanup: /' "$TMP_ROOT/cleanup.out"
[ ! -f "${RACE_HOOK:-/nonexistent}.log" ] || sed 's/^/    hook: /' "$RACE_HOOK.log"

AFTER_FOCUS=$(focus_snapshot) || AFTER_FOCUS=unreadable
CLOSED=""
for id in $(printf '%s\n' "${!KIND[@]}" | sort); do
  if lab pane get "${PANE[$id]}" >/dev/null 2>&1; then state=present; else state=closed; CLOSED="$CLOSED $id"; fi
  log "  $id (${KIND[$id]}): pane $state, journal $(if [ "${KIND[$id]}" = no-journal ]; then echo none; elif [ -e "$STATE/$id.herdr-presentation" ]; then echo kept; else echo retired; fi)"
done
CLOSED=${CLOSED# }
JOURNALS_AFTER=$(cd "$STATE" && ls -1 ./*.herdr-presentation 2>/dev/null | sed 's#^\./##' | sort)
RETIRED=$(comm -23 <(printf '%s\n' "$JOURNALS_BEFORE") <(printf '%s\n' "$JOURNALS_AFTER") | tr '\n' ' ' | sed 's/ $//')
ANCHOR_OK=no; lab pane get "$ANCHOR_PANE" >/dev/null 2>&1 && ANCHOR_OK=yes
verdict=pass
[ "$cleanup_status" = 0 ] || verdict=fail
[ "$CLOSED" = "$EXPECT_CLOSED" ] || verdict=fail
[ "$AFTER_FOCUS" = "$BEFORE_FOCUS" ] || verdict=fail
[ "$ANCHOR_OK" = yes ] || verdict=fail
expected_retired=$(for id in $EXPECT_CLOSED; do printf '%s.herdr-presentation\n' "$id"; done | sort | tr '\n' ' ' | sed 's/ $//')
if [ "$MODE" = race ]; then
  # race-gone's journal was deleted by the hook, not by cleanup.
  expected_retired=$(printf '%s\n' race-control.herdr-presentation race-gone.herdr-presentation | sort | tr '\n' ' ' | sed 's/ $//')
fi
[ "$RETIRED" = "$expected_retired" ] || verdict=fail
log "closed panes: [$CLOSED] expected [$EXPECT_CLOSED]"
log "retired journals: [$RETIRED] expected [$expected_retired]"
log "journals before=$(printf '%s\n' "$JOURNALS_BEFORE" | wc -l | tr -d ' ') after=$(printf '%s\n' "$JOURNALS_AFTER" | grep -c . )"
log "focus before=[$BEFORE_FOCUS] after=[$AFTER_FOCUS] anchor-pane-intact=$ANCHOR_OK"
log "verdict=$verdict"
printf 'label=%s\nmode=%s\nelapsed=%s\nclosed=%s\nretired=%s\nfocus_preserved=%s\nverdict=%s\n' \
  "$LABEL" "$MODE" "$ELAPSED" "$CLOSED" "$RETIRED" "$([ "$AFTER_FOCUS" = "$BEFORE_FOCUS" ] && echo yes || echo no)" "$verdict" > "$RESULT"
[ "$verdict" = pass ]
