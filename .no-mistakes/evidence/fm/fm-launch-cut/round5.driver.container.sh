#!/bin/bash
# Runs inside a throwaway python:3.12-slim-trixie container (Debian, bash 5.2.37) as non-root user fm.
set -u
cd /home/fm
echo "bash $BASH_VERSION uid=$(id -u) loadables-dir=$(ls /usr/lib/bash 2>/dev/null | wc -l) entries"
locale -a | tr '\n' ' '; echo
export WT=/home/fm/head
s=$(date +%s); bash head/tests/fm-fork-free-helpers.test.sh > ffh.log 2>&1; rc=$?
echo "tests/fm-fork-free-helpers.test.sh (head) exit=$rc elapsed=$(( $(date +%s)-s ))s ok=$(grep -c '^ok' ffh.log) notok=$(grep -c '^not ok' ffh.log)"
grep '^not ok' ffh.log | head
cp head/tests/fm-fork-free-helpers.test.sh c033/tests/fm-fork-free-helpers.test.sh
s=$(date +%s); bash c033/tests/fm-fork-free-helpers.test.sh > ffh-c033.log 2>&1; rc=$?
echo "head's tests/fm-fork-free-helpers.test.sh against pre-fix c033d4d lib: exit=$rc elapsed=$(( $(date +%s)-s ))s ok=$(grep -c '^ok' ffh-c033.log) notok=$(grep -c '^not ok' ffh-c033.log)"
grep -A4 '^not ok' ffh-c033.log | head -12
bash drivers/inbox-concurrent.sh /home/fm/head head-d9a6acb 8
bash drivers/inbox-concurrent.sh /home/fm/base base-ce69740 8
bash drivers/drain-ab.sh /home/fm/head head-d9a6acb 30
bash drivers/drain-ab.sh /home/fm/base base-ce69740 30
