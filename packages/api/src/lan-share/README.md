# api/src/lan-share

Domain types for LAN-based sharing of database configurations and secrets between devices.

This directory contains:
- `index.ts`: domain types: `IShareDatabaseConfig`, `IDatabaseSharePayload`, `ISecretSharePayload`, `IConflictResolution`, `ConflictResolver`, resolved-credential types and the results of the LAN share background tasks.

These types are re-exported from `api` so that consumers import from `api` rather than from `lan-share` directly.
