#!/bin/bash
# usage: cycle-ab.sh <tree> <label> <seconds> <status-logs>
# Runs the real fm-watch.sh from <tree> on a fresh lab FM_HOME holding <status-logs> working status logs and one
# registered custom check that only timestamps each poll cycle (FM_POLL=1, FM_CHECK_INTERVAL=0). One perl process
# samples the liveness beacon's age every 0.25 s. Reports cycles completed and per-cycle work time.
tree=$1 label=$2 secs=$3 n=$4
WT=/Users/jean/.no-mistakes/worktrees/73d83b691d3f/01M54PFQAC5EP0HSC1PE9Q7MHF
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
for i in $(seq 1 "$n"); do
  printf 'working: started task t%s\nworking: step 1\nworking: step 2\nworking: step 3\n' "$i" > "$LAB/state/t$i.status"
done
printf '#!/bin/sh\nperl -MTime::HiRes=time -e '"'"'printf "%%.3f\\n", time'"'"' >> %s/cycles.log\n' "$LAB" > "$LAB/state/cyc.check.sh"
chmod 700 "$LAB/state/cyc.check.sh"
env FM_HOME="$LAB" "$tree/bin/fm-check-register.sh" cyc >/dev/null || { echo "register failed"; exit 1; }
sleep 2
# Seed: let this tree's own watcher surface the fresh logs once (it then records them as seen), so the measured
# run below is a steady-state fleet whose logs carry no new event. The seeding time is itself reported.
seed_start=$(perl -MTime::HiRes=time -e 'printf "%.1f", time')
seed_note=''
for attempt in 1 2 3; do
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_TEST_SEAM -u FM_TEST_NO_LOADABLES \
    FM_HOME="$LAB" FM_POLL=1 FM_CHECK_INTERVAL=0 FM_SIGNAL_GRACE=1 \
    perl -e 'alarm shift; exec @ARGV' 400 "$tree/bin/fm-watch.sh" > "$LAB/seed.out" 2>/dev/null
  seed_end=$(perl -MTime::HiRes=time -e 'printf "%.1f", time')
  seed_note="$seed_note seed$attempt: $(cut -c1-60 "$LAB/seed.out" | head -1) ($(perl -e 'printf "%.1f", $ARGV[1]-$ARGV[0]' "$seed_start" "$seed_end")s since seeding began);"
  grep -q '^signal:' "$LAB/seed.out" && break
done
# A watcher restarted after delivering a wake first re-surfaces that delivery (check: rearm-resurface) and exits;
# take that one restart here so the measured run is the steady-state one.
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_TEST_SEAM -u FM_TEST_NO_LOADABLES \
  FM_HOME="$LAB" FM_POLL=1 FM_CHECK_INTERVAL=0 \
  perl -e 'alarm shift; exec @ARGV' 120 "$tree/bin/fm-watch.sh" > "$LAB/rearm.out" 2>/dev/null
seed_note="$seed_note restart: $(head -1 "$LAB/rearm.out");"
: > "$LAB/cycles.log"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_TEST_SEAM -u FM_TEST_NO_LOADABLES \
  FM_HOME="$LAB" FM_POLL=1 FM_CHECK_INTERVAL=0 \
  perl -e 'alarm shift; exec @ARGV' "$secs" "$tree/bin/fm-watch.sh" > "$LAB/watch.out" 2>"$LAB/watch.err" &
wpid=$!
perl -MTime::HiRes=time,sleep -e '
  my ($beat,$pid,$secs)=@ARGV; my $max=0; my $n=0; my $t0=time;
  while (kill(0,$pid) && time-$t0 < $secs+1) { my @s=stat($beat); if(@s){ my $a=time-$s[9]; $max=$a if $a>$max; $n++ } sleep 0.25 }
  printf "beacon samples=%d max_age=%.1fs\n",$n,$max;' "$LAB/state/.last-watcher-beat" "$wpid" "$secs" > "$LAB/beacon.txt" &
spid=$!
wait "$wpid"; rc=$?
wait "$spid"
perl -e '
  my @t=map{chomp;$_}<STDIN>; my $c=@t; my @d; for my $i(1..$#t){push @d,$t[$i]-$t[$i-1]}
  my $s=0;$s+=$_ for @d; my @sd=sort{$a<=>$b}@d; my $mean=@d?$s/@d:0; my $med=@d?$sd[int(@sd/2)]:0; my $mx=@d?$sd[-1]:0;
  printf "cycles=%d mean_cycle=%.2fs median_cycle=%.2fs max_cycle=%.2fs (each includes the FM_POLL=1 s sleep)\n",$c,$mean,$med,$mx;' < "$LAB/cycles.log" > "$LAB/cycles.txt"
printf '== %s status_logs=%s run=%ss watcher_rc=%s (142 = stopped by the run alarm, i.e. stayed alive)\n   seeding:%s\n   %s\n   %s\n' \
  "$label" "$n" "$secs" "$rc" "$seed_note" "$(cat "$LAB/cycles.txt")" "$(cat "$LAB/beacon.txt")"
[ -s "$LAB/watch.out" ] && printf '   watcher stdout: %s\n' "$(head -3 "$LAB/watch.out")"
[ -s "$LAB/watch.err" ] && printf '   watcher stderr: %s\n' "$(head -3 "$LAB/watch.err")"
rm -rf "$LAB"
