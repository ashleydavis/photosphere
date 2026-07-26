#!/usr/bin/env bash
# Tests android-lock.sh: basic verdicts and a concurrency stress test that proves mutual exclusion.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="$HERE/android-lock.sh"

WORK="$(mktemp -d)"
export PHOTOSPHERE_ANDROID_LOCK_FILE="$WORK/lock"
export PHOTOSPHERE_ANDROID_LOCK_TIMEOUT=60

fails=0
cleanup() {
    # Kill anything still holding our isolated lock, then remove the scratch dir.
    for pid in $(fuser "$PHOTOSPHERE_ANDROID_LOCK_FILE" 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT

check() { # <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "ok   - $1"
    else
        echo "FAIL - $1 (expected '$2', got '$3')"
        fails=$((fails + 1))
    fi
}

# 1. Nothing held -> free.
check "status is free when nothing holds the lock" "free" "$("$LOCK" status)"

# 2. unlock with no lock file must be a harmless no-op (exit 0), not an error.
"$LOCK" unlock >/dev/null 2>&1
check "unlock with no lock file exits 0" "0" "$?"

# 3. run executes its command under the lock and releases it afterwards.
"$LOCK" run true
check "run releases the lock afterwards" "free" "$("$LOCK" status)"

# 4. While a run holds the lock: status is locked and unlock refuses.
"$LOCK" run sleep 3 &
holder=$!
locked=""
for _ in $(seq 1 80); do
    if [[ "$("$LOCK" status)" == locked* ]]; then locked=yes; break; fi
    sleep 0.05
done
check "status is locked while a run holds it" "yes" "$locked"
"$LOCK" unlock >/dev/null 2>&1
check "unlock refuses while a run holds it" "1" "$?"
wait "$holder" 2>/dev/null
check "lock is free after the run ends" "free" "$("$LOCK" status)"

# 5. Waiting for a held lock gives up after the timeout instead of hanging forever.
#    PHOTOSPHERE_ANDROID_LOCK_TIMEOUT is the knob that makes the wait short here (and in CI) rather
#    than the 30-minute default.
"$LOCK" hold >/dev/null 2>&1 &
timeout_holder=$!
for _ in $(seq 1 80); do [[ "$("$LOCK" status)" == locked* ]] && break; sleep 0.05; done
start=$(date +%s)
PHOTOSPHERE_ANDROID_LOCK_TIMEOUT=2 "$LOCK" run true >/dev/null 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))
check "acquire gives up (exit 1) when the lock stays held" "1" "$rc"
[ "$elapsed" -le 8 ] && prompt=yes || prompt=no
check "acquire gives up promptly (~2s, elapsed ${elapsed}s), not the long default" "yes" "$prompt"
kill -TERM "$timeout_holder" 2>/dev/null
wait "$timeout_holder" 2>/dev/null

# 6. Stress: 25 concurrent runs each do a non-atomic read-modify-write of a counter under the lock.
#    If the lock serializes them the final count is exactly 25; a broken lock loses updates.
counter="$WORK/counter"
echo 0 > "$counter"
workers=25
for _ in $(seq 1 "$workers"); do
    PHOTOSPHERE_ANDROID_LOCK_TIMEOUT=120 "$LOCK" run bash -c 'n=$(cat "'"$counter"'"); sleep 0.01; echo $((n + 1)) > "'"$counter"'"' 2>/dev/null &
done
wait
check "concurrent runs are mutually exclusive (no lost updates)" "$workers" "$(cat "$counter")"

echo ""
if [ "$fails" -eq 0 ]; then
    echo "All lock tests passed."
    exit 0
fi
echo "$fails lock test(s) failed."
exit 1
