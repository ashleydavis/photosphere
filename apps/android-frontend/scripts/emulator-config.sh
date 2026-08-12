#!/bin/bash

# Names shared between the emulator lifecycle script (emulator.sh) and the smoke-test harness
# (apps/smoke-tests/lib/android.sh).
#
# These live here, in one file both sides source, because the harness has to recognise a pool
# emulator to know it should leave a hand-testing one alone. A copy of the prefix in each place would
# silently stop matching the day it was renamed, and the tests would quietly start reinstalling over
# somebody's own emulator.

# How many emulators the pool brings up. Only `pool-up` creates them; `up` is always a single
# emulator. It lives here rather than in emulator.sh because the smoke-test harness reads it too, to
# say how many of the pool's emulators are missing when a run starts on a reduced pool.
#
# Five. The comment that used to sit above this said it had been reduced to three to lighten the load
# on the development machine, while the value said five, and the value is what runs: five emulators
# were up when the pool collapsed on 2026-08-09 and five is what the memory limits in
# psphere-pool.slice were measured against. The count and the account of it now agree.
#
# Override with the environment variable, for example
# PHOTOSPHERE_EMULATOR_COUNT=3 bun run emu:and:pool:up
PHOTOSPHERE_EMULATOR_COUNT="${PHOTOSPHERE_EMULATOR_COUNT:-5}"

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

#
# Prints the path of the lock file held for the whole of one test while that test is using the device
# with the given adb serial. The smoke-test harness takes it in apps/smoke-tests/lib/runner.sh, and
# the emulator repair path takes it non-blocking before it touches an emulator, which is what stops a
# repair restarting a device out from under a running test.
#
# One definition rather than one literal per caller, because two copies that drifted apart would
# leave the repair locking a path nobody else respects, and the failure that produced would be a test
# dying mid-run with nothing to say why.
#
# The name says android for the same reason the literal it replaces did: it was written for the
# emulator pool. The harness uses it for an iOS simulator too, which is a name that reads oddly rather
# than a second lock.
# Usage: android_device_lock_path <serial>
#
android_device_lock_path() {
    echo "/tmp/photosphere-android-device-$1.lock"
}
