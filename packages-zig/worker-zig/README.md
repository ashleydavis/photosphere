# worker-zig

The worker half of the background work every platform shares. It holds the task handlers the core's background loop asks each pass for what automatic import, syncing and prefetch should do, the device photo library as an import media source (registered at app startup), and typed access to the native connection-type call the sync and prefetch planning read.

## Name

`worker-zig` is too generic to be useful. It names the workers without saying what they do or where they run, so a reader learns nothing from the name. This package should later be renamed to something descriptive, or merged into the package that owns this code.
