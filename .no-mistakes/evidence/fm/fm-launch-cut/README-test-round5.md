# Test round 5 evidence: d9a6acb (Read files byte-wise under C locale in fm_read_file_to)

Files written by this round on 2026-10-17 are prefixed `round5.`. Every run used a fresh `bin/fm-lab-home.sh create` home, and every lab home was removed afterwards. Base is ce69740 (the branch base) and the pre-fix tree is c033d4d, both exported with `git archive`.

## Live product runs
- `round5.live-watcher-check-output-bytes.utf8.log`: the real `fm-watch.sh` with a registered custom check that prints `01 61 e3 01 78`, run under `LC_ALL=en_US.UTF-8` with Homebrew bash 5.3.
  - Head's wake line carries all 5 bytes.
  - Pre-fix c033d4d drops the second `\x01` (`01 61 e3 78`).
  - Base carries all 5 bytes, but needed 159 s to deliver the wake versus about 21 s at head.
- `round5.live-watcher-cycle-ab.macos.log`: the real `fm-watch.sh` over 30 working status logs.
  - Head surfaced them in 19-35 s, and its beacon was never older than 10-13 s.
  - Base twice failed to finish that first cycle within 400 s. A third base watcher completed 1 check sweep in 90 s.
  - A steady-state cycle rate at head was not captured: a restarted watcher first re-surfaces its delivered wake (`check: rearm-resurface`) until a drain acknowledges it.
- `round5.live-inbox-concurrent.macos.log`: 8 `fm-inbox.sh note` calls started at once on a fresh home.
  - Every call exits 0, sequences are exactly 1-8, and `.wake-queue.seq` ends at 8.
  - Homebrew bash: 6.9 s at head versus 119 s at base.
- `round5.live-inbox-concurrent.bash32-head-vs-base.macos.log`: the same run under stock `/bin/bash` 3.2.
  - Correct sequences at both commits.
  - Both head and base sometimes leave a `.wake-queue.lock.owner.*` directory that holds a contender's stray `ln -s` link. This is a pre-existing lock race, not caused by this branch.
- `round5.live-drain.macos.log`: the real `fm-wake-drain.sh` on 30 logs at head. The 3 appended `note:` lines, including a multibyte one, surface exactly once and the next drain shows none.
- `round5.bash52-container.log`: Debian bash 5.2.37 in a throwaway container, non-root.
  - `tests/fm-fork-free-helpers.test.sh` passes at head.
  - The same test fails against the c033d4d library on exactly the new `ctl-utf8` and `del-utf8` cases.
  - 8 concurrent notes at head and base: all exit 0, `.wake-queue.seq` = 8, no lock left behind.
  - Drain A/B: both commits surface the 3 notes once and then none. Head 2.95/8.08/7.43 s, base 7.01/9.43/10.17 s.

## Targeted tests on macOS
- `round5.fork-free-helpers.macos.targeted.log`: covers bash 3.2 and 5.3, in the C and UTF-8 locales.
  - At head, the read/rm/ln case, the set -e read and first wake append case, and the lock-release case all pass.
  - Head's test fails against the c033d4d library on the new control-byte cases.

Driver scripts: `round5.driver.*.sh`.
