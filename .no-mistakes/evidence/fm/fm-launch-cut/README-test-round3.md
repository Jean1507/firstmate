# Test round 3 evidence: 85942464..650e448c (Fix bash 5.2 set -e read and watcher cycle wait)

Files written by this round, 2026-10-17, from 10:12 PDT on. The `.ff-*`, `.tr-*` and other 08:xx/09:xx files were left by earlier rounds and are not this round's.

## Live product scenarios
- `inbox-note.bash52.log`: real `bin/fm-inbox.sh note` on a freshly minted lab FM_HOME (no `.wake-queue.seq`) under Debian bash 5.2.15 in a throwaway container.
  Base 85942464 exits 1 with no output, writes no wake, and leaves `.wake-queue.lock` plus its owner dir behind. Head 650e448c exits 0, queues the note, writes `.wake-queue.seq`=1 and one `check` wake row.
- `inbox-note.macos.log`: the same scenario at head on stock /bin/bash 3.2.57 and Homebrew bash 5.3.15. Both exit 0, seq=1, one wake row.
- `watcher-cycle-seam.macos.log`: real `bin/fm-watch.sh` on a lab home for about 12 s.
  With FM_TEST_SEAM=1 and FM_TEST_WATCH_CYCLES=1: 24 cycle tops recorded and 55 distinct beacon mtimes, so the beacon beats several times per cycle and the counter is the real cycle boundary.
  Without FM_TEST_SEAM, or without FM_TEST_WATCH_CYCLES: no `.test-watch-cycles` file is written. The production watcher never writes it.

## Regression tests
- `fork-free-helpers.bash52.base-with-new-test.log` vs `fork-free-helpers.bash52.head.log`: the new set -e case fails on base code ("set -e file read and first wake append failed under /usr/bin/bash") and passes at head on bash 5.2.
- `fork-free-helpers.macos.log`: the full file at head passes under /bin/bash 3.2 and Homebrew 5.3, both locales.
- `regressed8.bash52.{base-85942464,head-650e448c}.log`, `regressed-jq.bash52.*.log`, `bash52-per-script/`: the 8 scripts that regressed, on bash 5.2 with git, procps, tmux and jq installed in the throwaway container.
  Base fails all 8 (watch-triage fails at "provably-working signal did not advance its .seen-* suppressor"). Head passes inbox, mail-check, mail, voice-relay, secondmate-safety, pr-check-security, and watch-triage (all 144 cases).
  fm-contributions also fails at head in this container (6 cases, 13 at base). Head's 6 are exactly the branch base ce697402's 6 in the same container (`regressed-jq.bash52.branch-base-ce697402.log`), so they come from the container. It passes at this head on jean-dev-3.
- `jean-dev-3.sharded-head650.summary.log`: the sharded portable run at this exact head on jean-dev-3 (bash 5.2.21). The snapshot is byte-identical to 650e448c for the changed files.
  All 8 regressed scripts and fork-free-helpers exit 0. 49 of 244 scripts are non-zero; that set is a strict subset of the earlier sharded run's failures, mostly missing node, ruby, tasks-axi or a C compiler. No base-commit sharded run exists on that host.

## Performance check (intent: monitoring must never slow the work down)
- `read-helper-bench.macos.log`, `read-helper-bench-manifest.log`, `read-helper-strip-loop-profile.log`: the new `fm_read_file_to` costs the same as base on pid-sized files.
  Its trailing-newline strip loop is quadratic in file size: 5 KB takes 5.5 ms against 0.5 ms; 44 KB takes about 351 ms per read under UTF-8 against 4-26 ms for base's `$(<file)` (the bench log labels this 43890-byte file "54KB"; it is 44 KB).
  A last-character check (`while [ "${x: -1}" = $'\n' ]; do x=${x%?}; done`) gives byte-identical output at about 1.7 ms.

## macOS targeted runs at head (SentinelOne laptop)
- fm-inbox, fm-mail-check, fm-mail and fm-secondmate-safety pass (`*.macos.par.log`).
- `watch-triage.macos.log`: the full file stops at its first failure, "a mixed authoritative-and-churn batch was not absorbed" (a fixed 10 s wait budget).
  `watch-triage.mixed-batch.repeat.macos.log` re-runs that case alone: head passes 2/3, base 3/3, so it is a timing flake.
  `watch-triage.wait-poll-cycle-cases.macos.log`: 8 cases that use the changed `wait_poll_cycle` helper all pass on macOS. All 144 cases pass on bash 5.2 and on jean-dev-3.
- The remaining macOS failures recur at base 85942464 too, so they are laptop timing, not this commit:
  - fm-contributions: `fm-contributions.macos-failed-cases.head-vs-base.log`, 4 of the 6 timing cases fail on both head and base.
  - fm-pr-check-security: `fm-pr-check-security.merge-outcome-case.head-vs-base.macos.log`, the 60 s watcher bound is exceeded on both.
  - fm-voice-relay: `fm-voice-relay.macos.head-vs-base.repeat.log`, the 1.6 s first-audio bound fails intermittently on both.
