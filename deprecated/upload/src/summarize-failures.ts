import { summarizeFailures } from "./lib/failures";

async function main() {
    //
    // Summarize the failures.
    //
    const path = "./log.7/failures";
    await summarizeFailures(path);
}

main().catch(console.error);

