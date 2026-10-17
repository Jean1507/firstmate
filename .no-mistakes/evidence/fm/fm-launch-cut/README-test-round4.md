# Test round 4 evidence: c033d4d (Strip read helper trailing newlines in linear time)

Files written by this round on 2026-10-17 are prefixed `round4.`.

## Targeted suites at head c033d4d
- `round4.fork-free-helpers.macos.head-c033d4d.log`: all 13 cases of tests/fm-fork-free-helpers.test.sh pass under /bin/bash 3.2.57 and Homebrew 5.3.15, in both the C and UTF-8 locales.
- `round4.bash52.head-c033d4d.fast-scripts.log`: in a throwaway Debian bash 5.2.37 container (non-root user), fm-fork-free-helpers, fm-inbox, fm-mail-check and fm-mail pass.
- `round4.bash52.head-c033d4d.fm-watch-triage.log`: fm-watch-triage passes 144/144 on the same bash 5.2.

## Live product runs on disposable lab FM_HOMEs (bin/fm-lab-home.sh create)
- `round4.live-inbox-note.fresh-lab-home.log`: the real `fm-inbox.sh note` runs twice on a fresh lab home with no .wake-queue.seq, under bash 3.2, 5.3 and 5.2. Every run exits 0, the sequence file reads back as 1 and advances to 2, two wake rows are queued, and no lock is left behind.
- `round4.live-watcher.macos.head-c033d4d.log`: the real `fm-watch.sh` on a lab home stays alive for about 20 s, completes 7 poll cycles, and its beacon is never more than 6 s old.
- `round4.live-drain-ab.bash52.300-status-logs.log`: the real `fm-wake-drain.sh` on 300 status logs with a 300-row, 21 KB manifest. Head surfaces the 3 appended notes once and replays none (255 s and 197 s). The 650e448c drain was still on its first pass after 4 min 41 s when the run was stopped to stay within budget.

## Read helper: what the new commit changes
- `round4.read-helper-bench.linear-strip.log`: per-read cost of fm_read_file_to.
  - 50 KB manifest: head 3.3 ms, 650e448c 597 ms.
  - 158 KB manifest: head 7 ms, 650e448c 6.1 s (macOS, UTF-8).
  - A single cat(1) launch on this laptop costs 44-148 ms.
  - Every output equals `$(cat)`.
  - Cost is still O(size x trailing newlines): a file ending in 500 newlines takes about 400 ms.
- `round4.read-helper-fuzz.macos.log`, `round4.read-helper-control-byte-matrix.log`: differential fuzz against `$(cat)`.
  - Every named adversarial input matches: newline runs, NUL bytes, valid and truncated UTF-8, CRLF, manifests, missing paths, directories, symlinks, unreadable files.

## Defect found (pre-existing since 650e448c, not caused by c033d4d)
- `round4.read-helper-ctlesc-repro.log`: under a UTF-8 locale on bash 5.2 and 5.3, the `read -r -d ''` loop drops a `\x01` that follows a truncated multibyte lead byte whenever the same chunk also holds a raw `\x01` or `\x7f`.
  - Minimal input: `printf '\x01a\xe3\x01x'`. The helper returns `01 61 e3 78`, while `$(cat)` returns all five bytes.
  - Base 85942464 (`$(<file)`) matches `$(cat)`.
- `round4.read-helper-fuzz.head-vs-c-locale-fix.log`: random binary files give 68 mismatches on 5.3 and 94-106 on 5.2 at head.
  - A scratch copy with `local LC_ALL=C` in the fork-free branch gives 0 mismatches on both bashes.
  - That copy restores the caller's locale on return.
