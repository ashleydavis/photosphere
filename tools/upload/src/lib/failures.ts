import fs from "fs-extra";

//
// Reads all the failure files and creates a summary.
//
export async function summarizeFailures(path: string): Promise<void> {
    const failures = await fs.readdir(path);
    console.log(`Found ${failures.length} failures.`);

    const failureMap = new Map<string, number>();
    for (const failure of failures) {
        if (failure === "summary.json") {
            continue;
        }

        try {
            const failureData = JSON.parse(await fs.readFile(`${path}/${failure}`, "utf8"));

            let message = failureData.error.message;
            if (message) {
                message = message.replace(/(File size )\(\d+\)( is greater than 2 GiB)/, "$1$2");
            }
            else {
                message = failureData.error.stack;
                if (!message) {
                    message = "no msg";
                }
            }
            
            const numFailures = failureMap.get(message) || 0;
            failureMap.set(message, numFailures + 1);
        }
        catch (error) {
            console.error(`Error reading failure file: ${failure}`);
        }
    }

    await fs.writeFile(`${path}/summary.json`, JSON.stringify(Object.fromEntries(failureMap), null, 2));
}
