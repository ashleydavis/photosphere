# Automatic Import Tests

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Manual tests covering automatic photo backup. Two of them are whole flows that differ only in which side existed first, and either one on its own covers importing and syncing end to end:

- [auto-import-new-remote](auto-import-new-remote.md) - the phone's database comes first and an empty remote is created to match it, so everything travels up.
- [auto-import-existing-remote](auto-import-existing-remote.md) - a database already in a bucket is replicated down onto the phone, which then imports into that copy.

The rest cover one thing each: the permission being refused, and deleting a photo from the device once it is backed up.
