import { JsEngine } from "./js-engine-plugin";

//
// Staging the answer to the next photo library delete request.
//
// Both platforms put a system confirmation in front of deleting media the app did not create, and
// that dialog cannot be tapped by an automated test: its wording and its controls change between
// operating system versions. Staging the answer leaves everything above the dialog under test, which
// is where the decisions are: which photos are confirmed present in the database, batching them into
// one request, and what happens on each answer.
//
// The staged answer is passed through to the native layer so its completion path runs for real,
// exactly as the export sheet's staged outcome does. Nothing stages an answer in production, so the
// real request is issued.
//

//
// What the user is taken to have chosen at the delete confirmation.
//
export type MediaDeleteOutcome = "deleted" | "cancelled";

//
// Test-only: stages the answer to the next photo library delete request. Called by the mobile
// provider on the stage-delete smoke-test window event.
//
export async function setInjectedDeleteOutcome(outcome: MediaDeleteOutcome): Promise<void> {
    await JsEngine.stageMediaDeleteOutcome({ outcome });
}
