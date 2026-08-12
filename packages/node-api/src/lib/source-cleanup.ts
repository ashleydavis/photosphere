//
// Source cleanup moved into `packages/api` so the mobile frontend can reach it. See the comment in
// `media-source.ts` beside this file for why. It deletes through the IMediaSource it is handed, so
// nothing in it was Node-specific either.
//
export * from "api/src/lib/source-cleanup";
