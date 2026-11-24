# Onboarding Tests

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Manual tests covering a new user's first run of the app, done entirely in the app, from the welcome screen to their photos being backed up to S3. Each one runs on the mobile app and on the desktop app:

- [onboard-existing-remote](onboard-existing-remote.md) - the user already has a Photosphere database in a bucket and connects the app to it.
- [onboard-new-remote](onboard-new-remote.md) - the user has a bucket and creates a new Photosphere database in it from the app.
