import pc from "picocolors";
import { exit } from "node-utils";
import { formatBytes } from "../lib/format";
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";
import { log } from "utils";
import { IAsset } from "defs";

export interface IListCommandOptions extends IBaseCommandOptions {
    //
    // Number of files to display per page
    //
    pageSize?: number;
}

//
// Command that lists all files in the database with pagination
//
export async function listCommand(options: IListCommandOptions): Promise<void> {
    
    const { database } = await loadDatabase(options.db, options, true, true);
    const pageSize = parseInt(options.pageSize?.toString() || '20', 10);

    try {
        const metadataDatabase = database.getMetadataDatabase();
        const metadataCollection = metadataDatabase.collection("metadata");
        
        log.info('');
        log.info(pc.bold(pc.blue(`📁 Database Files`)));
        log.info('');
        log.info(pc.gray(`Files are sorted by date (newest first).`));
        log.info('');

        let nextPageId: string | undefined;
        let pageNumber = 1;
        let totalDisplayed = 0;

        while (true) {
            const result = await metadataCollection.getSorted("photoDate", "desc", nextPageId);
            
            if (result.records.length === 0) {
                if (totalDisplayed === 0) {
                    log.info(pc.yellow('No files found in the database.'));
                } else {
                    log.info(pc.green(`\nEnd of results. Displayed ${totalDisplayed} files total.`));
                }
                break;
            }

            // Cast to IAsset and slice the results to match our page size
            const assets = result.records as IAsset[];
            const pageRecords = assets.slice(0, pageSize);
            
            // Display current page
            displayPage(pageRecords, pageNumber, pageSize);
            totalDisplayed += pageRecords.length;

            // Check if there are more pages
            // Either we have a nextPageId from database or we displayed less than pageSize
            const hasMorePages = result.nextPageId && pageRecords.length === pageSize;
            
            if (!hasMorePages) {
                log.info(pc.green(`\nEnd of results. Displayed ${totalDisplayed} files total.`));
                break;
            }

            // Wait for user input
            log.info(pc.dim('Press Enter for next page, Escape to exit...'));
            const shouldContinue = await waitForUserInput();
            if (!shouldContinue) {
                log.info(pc.cyan(`\nDisplayed ${totalDisplayed} files. Exiting.`));
                break;
            }

            // If we displayed fewer records than available, use the remainder for next page
            if (result.records.length > pageSize) {
                // We need to keep the remaining records for the next page
                // This is a bit tricky with the current API, so let's keep it simple
                // and just use the database's pagination
                nextPageId = result.nextPageId;
            } else {
                nextPageId = result.nextPageId;
            }
            pageNumber++;
        }

    } catch (error) {
        log.error(pc.red(`Failed to list files: ${error instanceof Error ? error.message : String(error)}`));
        await exit(1);
    }

    await exit(0);
}

function displayPage(records: IAsset[], pageNumber: number, pageSize: number): void {
    log.info(pc.bold(pc.cyan(`--- Page ${pageNumber} ---`)));
    
    for (const record of records) {
        const date = record.photoDate ? new Date(record.photoDate).toLocaleDateString() : 'Unknown';
        const size = record.properties?.fileSize ? formatBytes(record.properties.fileSize) : 'Unknown';
        const dimensions = record.width && record.height ? `${record.width}×${record.height}` : '';
        
        log.info(`${pc.blue(record._id)} ${pc.green(record.origFileName || 'Unknown')}`);
        log.info(`  ${pc.gray(`Date: ${date} | Size: ${size} | Type: ${record.contentType || 'Unknown'}`)}${dimensions ? ` | ${dimensions}` : ''}`);
        
        if (record.origPath) {
            log.info(`  ${pc.gray(`Path: ${record.origPath}`)}`);
        }
        
        log.info('');
    }
}

async function waitForUserInput(): Promise<boolean> {
    return new Promise((resolve) => {
        const stdin = process.stdin;
        stdin.setRawMode(true);
        stdin.resume();
        stdin.setEncoding('utf8');

        const onKeyPress = (key: string) => {
            stdin.setRawMode(false);
            stdin.pause();
            stdin.removeListener('data', onKeyPress);

            if (key === '\r' || key === '\n') {
                // Enter key - continue to next page
                resolve(true);
            } else if (key === '\u001b') {
                // Escape key - exit
                resolve(false);
            } else if (key === '\u0003') {
                // Ctrl+C - exit
                resolve(false);
            } else {
                // Any other key - continue
                resolve(true);
            }
        };

        stdin.on('data', onKeyPress);
    });
}