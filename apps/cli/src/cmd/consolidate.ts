import pc from "picocolors";
import { exit } from "node-utils";
import { log } from "utils";
import { TaskQueue, TaskStatus } from "task-queue";
import { loadDatabaseConfig, updateDatabaseConfig } from "api";
import { merkleTreeExists, replicateDatabase, IConsolidationResult } from "node-api";
import { loadDatabase, IBaseCommandOptions, ICommandContext, configureS3IfNeeded } from "../lib/init-cmd";
import { createStorageForPath } from "../lib/storage-helper";
import { loadMerkleTree } from "node-api";

//
// Options for the connect command.
//
export interface IConsolidateCommandOptions extends IBaseCommandOptions {
    //
    // Path to the encryption key for the remote database.
    //
    destKey?: string;
}

//
// Connects a local database to a remote one, whatever is already there.
//
// There are three cases and the command picks between them by looking, rather than making the user
// say which one they are in:
//
//   * Nothing at the remote path: the remote is created as a copy of the local database.
//   * A database that is not related to the local one: the two are consolidated, which pushes the
//     local content the remote does not have and makes the local database a partial replica of it.
//   * A database that is already related: the origin is simply recorded, because ordinary sync
//     already covers them.
//
export async function consolidateCommand(context: ICommandContext, remotePath: string, options: IConsolidateCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;

    const nonInteractive = options.yes || false;

    const { databaseDir, assetStorage: localStorage, rawAssetStorage: localRawStorage } = await loadDatabase(
        options.db, options, uuidGenerator, timestampProvider, sessionId
    );

    if (remotePath.startsWith("s3:")) {
        await configureS3IfNeeded(nonInteractive);
    }

    const { storage: remoteStorage } = await createStorageForPath(remotePath);
    const remoteExists = await merkleTreeExists(remoteStorage);

    log.info(pc.bold("Connecting to a remote database."));
    log.info(`  Database:  ${pc.cyan(databaseDir)}`);
    log.info(`  Remote:    ${pc.cyan(remotePath)}`);
    log.info("");

    if (!remoteExists) {
        // Nothing there yet, so the remote becomes a copy of what is here. Replication carries the
        // database id across, which is what makes the two related and lets sync run afterwards.
        log.info("There is no database at the remote path, so it is being created as a copy of this one.");

        await replicateDatabase(uuidGenerator, {
            sourcePath: databaseDir,
            destPath: remotePath,
            sourceEncryptionKey: options.key,
            destEncryptionKey: options.destKey,
            destS3Key: undefined,
            partial: false,
            force: false,
            pathFilter: undefined,
        }, progress => {
            log.verbose(progress);
        });
        await updateDatabaseConfig(localRawStorage, { origin: remotePath });

        log.info(pc.green(`✓ Created the remote database and set it as this database's origin.`));
        await exit(0);
        return;
    }

    const localTree = await loadMerkleTree(localStorage);
    const remoteTree = await loadMerkleTree(remoteStorage);
    if (!localTree || !remoteTree) {
        log.error(pc.red("✗ Could not read the merkle tree of one of the databases."));
        await exit(1);
        return;
    }

    if (localTree.id === remoteTree.id) {
        // Already the same database, so nothing has to move: recording the origin is the whole job.
        const existingConfig = await loadDatabaseConfig(localRawStorage);
        if (existingConfig?.origin === remotePath) {
            log.info(pc.green(`✓ Already joined to ${remotePath}.`));
        }
        else {
            await updateDatabaseConfig(localRawStorage, { origin: remotePath });
            log.info(pc.green(`✓ The remote is the same database, so it has been set as this database's origin.`));
        }
        await exit(0);
        return;
    }

    log.info("The remote holds a different database, so the two are being consolidated.");
    log.info("Content the remote already has is not pushed a second time.");
    log.info("");

    const queue = new TaskQueue(uuidGenerator, `consolidate-${sessionId}`);
    try {
        const taskId = queue.addTask("consolidate-database", {
            databasePath: databaseDir,
            remotePath,
            sessionId,
        });
        const taskResult = await queue.awaitTask(taskId);

        if (taskResult === undefined || taskResult.status !== TaskStatus.Succeeded) {
            log.error(pc.red(`✗ Consolidation failed: ${taskResult?.errorMessage ?? "the task did not finish"}`));
            await exit(1);
            return;
        }

        const result = taskResult.outputs as IConsolidationResult;
        log.info(pc.green(`✓ Connected to ${remotePath}.`));
        log.info(`Assets pushed to the remote:      ${result.pushedCount}`);
        log.info(`Assets the remote already had:    ${result.alreadyPresentCount}`);
        log.info("");
        log.info(pc.bold("Next steps:"));
        log.info(`    # Bring down everything the remote has that this database does not`);
        log.info(`    psi sync --db ${databaseDir}`);
    }
    finally {
        queue.shutdown();
    }

    await exit(0);
}
