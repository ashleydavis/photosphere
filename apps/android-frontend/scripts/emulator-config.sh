#!/bin/bash

# Names shared between the emulator lifecycle script (emulator.sh) and the smoke-test harness
# (apps/smoke-tests/lib/android.sh).
#
# These live here, in one file both sides source, because the harness has to recognise a pool
# emulator to know it should leave a hand-testing one alone. A copy of the prefix in each place would
# silently stop matching the day it was renamed, and the tests would quietly start reinstalling over
# somebody's own emulator.

# Prefix of the cloned AVDs the emulator pool runs on. Each pool instance gets its own clone, because
# an AVD's disk images are single-writer and every pool emulator has to be writable.
POOL_AVD_PREFIX="psphere-pool"

# Name of the AVD created automatically when the machine has none, so `up` and `pool-up` work on a fresh
# machine without anyone opening Android Studio first. An AVD made by hand is preferred over this one
# when it exists.
DEFAULT_BASE_AVD="psphere-base"

# Name of the AVD the single hand-testing emulator runs on, cloned from the base AVD the same way
# the pool's are. It has its own name so it can be identified by that name alone. It used to be
# identified as "the attached emulator that is not one of the pool's", which meant a running pool
# looked exactly like a running hand-testing emulator, and `up` would report success having started
# nothing at all.
SINGLE_AVD_NAME="psphere-single"

# Prefix of the tap interfaces. The single hand-testing emulator and the pool use separate prefixes,
# so bringing either up or down never disturbs the other.
NETCARD_PREFIX="emu-netcard"
POOL_NETCARD_PREFIX="emu-pool"
