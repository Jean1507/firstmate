#!/bin/bash
# usage: drain-ab.sh <tree> <label> <status-logs> [bash]
# Real fm-wake-drain.sh from <tree> on a fresh lab FM_HOME with <status-logs> working status logs:
# drain#1 primes the presentation cursors, then three `note:` lines are appended to three logs,
# drain#2 must surface exactly those three once, drain#3 must surface none. Each drain is timed.
tree=$1 label=$2 n=$3 sh=${4:-}
WT=${WT:-/Users/jean/.no-mistakes/worktrees/73d83b691d3f/01M54PFQAC5EP0HSC1PE9Q7MHF}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
for i in $(seq 1 "$n"); do
  printf 'working: started task t%s\nworking: step 1\nworking: step 2\n' "$i" > "$LAB/state/t$i.status"
done
sleep 2
drain() {
  local s e
  s=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_TEST_SEAM -u FM_TEST_NO_LOADABLES \
    FM_HOME="$LAB" $sh "$tree/bin/fm-wake-drain.sh" > "$LAB/drain$1.out" 2> "$LAB/drain$1.err"
  DRC=$?
  e=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  DT=$(perl -e 'printf "%.2f", $ARGV[1]-$ARGV[0]' "$s" "$e")
}
drain 1; r1="rc=$DRC ${DT}s"
printf 'note: answer for t3 is ready\n' >> "$LAB/state/t3.status"
printf 'note: café décision prête – t7\n' >> "$LAB/state/t7.status"
printf 'note: t11 picked option B\n' >> "$LAB/state/t11.status"
drain 2; r2="rc=$DRC ${DT}s"
drain 3; r3="rc=$DRC ${DT}s"
printf '== %s status_logs=%s bash=%s\n   drain#1 %s | drain#2 %s note-lines=%s | drain#3 %s note-lines=%s\n' "$label" "$n" "${sh:-PATH bash $(bash -c 'echo $BASH_VERSION')}" \
  "$r1" "$r2" "$(grep -c 'note:' "$LAB/drain2.out")" "$r3" "$(grep -c 'note:' "$LAB/drain3.out")"
printf '   drain#2 note lines:\n'; grep 'note:' "$LAB/drain2.out" | sed 's/^/     /'
for k in 1 2 3; do [ -s "$LAB/drain$k.err" ] && printf '   drain#%s stderr: %s\n' "$k" "$(head -3 "$LAB/drain$k.err")"; done
[ -n "${KEEP_OUT:-}" ] && cp "$LAB/drain2.out" "$KEEP_OUT"
rm -rf "$LAB"
