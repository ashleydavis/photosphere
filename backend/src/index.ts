import { MongoClient } from "mongodb";
import { createServer } from "./server";
import { CloudStorage } from "storage";
import { FileStorage } from "storage";

async function main() {

    const dbName = "photosphere";

    const PORT = process.env.PORT;
    if (!PORT) {
        throw new Error(`Set environment variable PORT.`);
    }

    const DB_CONNECTION_STRING = process.env.DB_CONNECTION_STRING;
    if (DB_CONNECTION_STRING === undefined) {
        throw new Error(`Set environment variable DB_CONNECTION_STRING.`);
    }

    const client = new MongoClient(DB_CONNECTION_STRING);
    await client.connect();

    const db = client.db(dbName);
    
    console.log(`Running in mode: ${process.env.NODE_ENV} on port ${PORT}.`);

    const storage = process.env.NODE_ENV === "production"
        ? new CloudStorage()
        : new FileStorage();
    const app = await createServer(() => new Date(Date.now()), db, storage);
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

