#!/bin/bash
# usage: check-bytes.sh <tree> <label>  -- runs the real fm-watch.sh from <tree> on a fresh lab home with a
# registered custom check that prints raw bytes, under a UTF-8 locale, and dumps the wake reason bytes.
tree=$1 label=$2
WT=/Users/jean/.no-mistakes/worktrees/73d83b691d3f/01M54PFQAC5EP0HSC1PE9Q7MHF
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
# check prints: \x01 a \xe3 \x01 x  (control byte, ascii, truncated UTF-8 lead, control byte, ascii)
printf '#!/bin/sh\nprintf '"'"'\\001a\\343\\001x'"'"'\n' > "$LAB/state/bytes.check.sh"
chmod 700 "$LAB/state/bytes.check.sh"
env FM_HOME="$LAB" "$tree/bin/fm-check-register.sh" bytes >/dev/null || { echo "register failed"; exit 1; }
out="$LAB/watch.out"
start=$(date +%s)
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_TEST_SEAM -u FM_TEST_NO_LOADABLES \
  LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 FM_HOME="$LAB" FM_POLL=1 FM_CHECK_INTERVAL=0 \
  perl -e 'alarm shift; exec @ARGV' "${ALARM:-90}" "$tree/bin/fm-watch.sh" > "$out" 2>"$LAB/watch.err"
rc=$?
end=$(date +%s)
printf '== %s (%s) bash=%s rc=%s elapsed=%ss\n' "$label" "$tree" "$(bash -c 'echo $BASH_VERSION')" "$rc" "$((end-start))"
printf -- '-- check stdout bytes (direct): '; sh "$LAB/state/bytes.check.sh" | od -An -tx1
printf -- '-- watcher wake line bytes (tail of reason after "bytes.check.sh: "):\n'
LC_ALL=C sed -n 's/.*bytes\.check\.sh: //p' "$out" | od -An -tx1
printf -- '-- watcher stdout (cat -v): '; cat -v "$out"
[ -s "$LAB/watch.err" ] && { printf -- '-- stderr (first 5 lines):\n'; head -5 "$LAB/watch.err"; }
rm -rf "$LAB"
