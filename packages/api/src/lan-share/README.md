# api/src/lan-share

Domain types and helper functions for LAN-based sharing of database configurations and secrets between devices.

This directory contains:
- `index.ts` — domain types: `IShareDatabaseConfig`, `IDatabaseSharePayload`, `ISecretSharePayload`, `IConflictResolution`, `ConflictResolver`, and resolved-credential types.
- `lan-share-resolve.ts` — builds share payloads by reading vault entries for a database config.
- `lan-share-import.ts` — imports share payloads by writing vault entries and returning a database config.

These types are re-exported from `api` so that consumers import from `api` rather than from `lan-share` directly.
