import { StorageDatabase } from "database";
import { createServer } from "./server";
import { StorageAssetDatabase } from "./services/asset-database";
import { CloudStorage } from "./services/cloud-storage";
import { FileStorage } from "./services/file-storage";

async function main() {

    const PORT = process.env.PORT;
    if (!PORT) {
        throw new Error(`Set environment variable PORT.`);
    }

    console.log(`Running in mode: ${process.env.NODE_ENV} on port ${PORT}.`);

    const storage = process.env.NODE_ENV === "production"
        ? new CloudStorage()
        : new FileStorage();
    const assetDatabase = new StorageAssetDatabase(storage);
    const database = new StorageDatabase(storage);
    const app = await createServer(() => new Date(Date.now()), assetDatabase, database);

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

