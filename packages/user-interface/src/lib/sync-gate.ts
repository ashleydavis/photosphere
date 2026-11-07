//
// The sync gate, re-exported from where it now lives.
//
// The rule moved to packages/api because the mobile background sync loop asks the same question and
// runs in the embedded worker, which cannot reach this package's React code. One implementation
// answers both, so the loop and the interface cannot decide differently about whether an automatic
// sync is permitted, and the failure when they drift is somebody's mobile data bill.
//
// It is re-exported here rather than every caller being repointed, because this package's barrel
// exports it and the browser build imports it by module path.
//
export { computeSyncAllowed, type ISyncGateInputs, type NetworkConnectionType } from "api/src/lib/sync-gate";
