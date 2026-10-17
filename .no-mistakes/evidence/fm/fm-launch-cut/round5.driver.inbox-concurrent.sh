#!/bin/bash
# usage: inbox-concurrent.sh <tree> <label> <k> [bash]
# Real fm-inbox.sh note from <tree>, <k> invocations started at once on a fresh lab FM_HOME (no .wake-queue.seq),
# all contending for the wake-queue lock. Expect: every call exits 0, k rows with distinct sequence numbers 1..k,
# .wake-queue.seq == k, and no lock link or owner directory left behind.
tree=$1 label=$2 k=$3 sh=${4:-}
WT=${WT:-/Users/jean/.no-mistakes/worktrees/73d83b691d3f/01M54PFQAC5EP0HSC1PE9Q7MHF}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
s=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
for i in $(seq 1 "$k"); do
  ( env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
      -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_TEST_SEAM -u FM_TEST_NO_LOADABLES \
      FM_HOME="$LAB" $sh "$tree/bin/fm-inbox.sh" note "concurrent note $i" > "$LAB/n$i.out" 2> "$LAB/n$i.err"; echo $? > "$LAB/n$i.rc" ) &
done
wait
e=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
rcs=$(cat "$LAB"/n*.rc | sort | uniq -c | tr '\n' ' ')
seqs=$(cut -f2 "$LAB/state/.wake-queue" 2>/dev/null | sort -n | tr '\n' ' ')
printf '== %s bash=%s k=%s wall=%.2fs\n   exit codes (count rc): %s\n   .wake-queue.seq: %s\n   row seqs: %s\n   distinct row seqs: %s\n' \
  "$label" "${sh:-$(bash -c 'echo $BASH_VERSION')}" "$k" "$(perl -e 'print $ARGV[1]-$ARGV[0]' "$s" "$e")" "$rcs" \
  "$(tr -d '\n' < "$LAB/state/.wake-queue.seq" 2>/dev/null)" "$seqs" "$(cut -f2 "$LAB/state/.wake-queue" | sort -u | wc -l | tr -d ' ')"
printf '   leftover lock/owner entries in state: %s\n' "$(ls -a "$LAB/state" | grep -c -E 'lock' )"
for o in "$LAB"/state/.wake-queue.lock*; do [ -e "$o" ] || [ -L "$o" ] || continue; printf '     %s -> contents: %s\n' "${o##*/}" "$(ls -A "$o" 2>/dev/null | tr '\n' ' ')"; done
cat "$LAB"/n*.err | sort | uniq -c | head -5 | sed 's/^/   stderr: /'
rm -rf "$LAB"
