import { createServer } from "./server";
import { CloudStorage } from "./services/cloud-storage";
import { Database } from "./services/database";
import { FileStorage } from "./services/file-storage";

async function main() {

    const dbName = "photosphere";

    const PORT = process.env.PORT;
    if (!PORT) {
        throw new Error(`Set environment variable PORT.`);
    }

    const storage = process.env.NODE_ENV === "production"
        ? new CloudStorage()
        : new FileStorage();
    const database = new Database(storage);
    const app = await createServer(() => new Date(Date.now()), database, storage);

    app.listen(PORT, () => {
        console.log(`Photosphere listening on port ${PORT}`);
    });
}

main()
    .catch(err => {
        console.error(`Something went wrong.`);
        console.error(err);
        process.exit(1);
    });

