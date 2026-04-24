import { scanPaths, IFileStat } from "api";
import { ICommandContext, IBaseCommandOptions, loadDatabase } from "../lib/init-cmd";
import { configureLog } from "../lib/log";
import pc from "picocolors";
import { exit } from "node-utils";
import { getFileInfo, AssetInfo } from "tools";
import path from "path";
import { ensureMediaProcessingTools } from '../lib/ensure-tools';
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { computeHash } from "api";
import { createReadStream } from "fs";
import { formatBytes } from "../lib/format";
import { log } from "utils";
import mime from "mime";
import type { IAsset } from "defs";

export interface IInfoCommandOptions extends IBaseCommandOptions {
    //
    // Enables verbose logging.
    //
    verbose?: boolean;

    //
    // Enables tool output logging.
    //
    tools?: boolean;

    //
    // Non-interactive mode - use defaults and command line arguments.
    //
    yes?: boolean;
}

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HASH_REGEX = /^[0-9a-f]{64}$/i;

type InputKind = "path" | "assetId" | "hash";

function classifyInput(input: string): InputKind {
    if (UUID_REGEX.test(input)) {
        return "assetId";
    }
    if (HASH_REGEX.test(input)) {
        return "hash";
    }
    return "path";
}

interface FileAnalysis {
    path: string;
    fileStat?: IFileStat;
    assetInfo?: AssetInfo;
    hash?: string;
    error?: string;
    logicalPath: string;
    asset?: IAsset; // Set when result is from database lookup
}

//
// Command that displays detailed information about media files, or about assets in the database by ID or hash.
//
export async function infoCommand(context: ICommandContext, inputs: string[], options: IInfoCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionTempDir, sessionId } = context;

    await ensureMediaProcessingTools(options.yes || false);

    const pathInputs = inputs.filter((p) => classifyInput(p) === "path");
    const dbInputs = inputs.filter((p) => {
        const kind = classifyInput(p);
        return kind === "assetId" || kind === "hash";
    });

    const results: FileAnalysis[] = [];

    if (pathInputs.length > 0) {
        writeProgress(`Searching for files...`);
        let fileCount = 0;
        await scanPaths(pathInputs, async (fileResult) => {
            try {
                const analysis = await analyzeFile(fileResult.filePath, fileResult.contentType, fileResult.fileStat, fileResult.logicalPath);
                results.push(analysis);
                fileCount++;
            } catch (error) {
                results.push({
                    path: fileResult.filePath,
                    fileStat: fileResult.fileStat,
                    logicalPath: fileResult.logicalPath,
                    error: error instanceof Error ? error.message : String(error)
                });
                fileCount++;
            }
        }, (currentlyScanning) => {
            let progressMessage = `Analyzed: ${pc.green(fileCount.toString())} files`;
            if (currentlyScanning) {
                progressMessage += ` | Scanning ${pc.cyan(currentlyScanning)}`;
            }
            progressMessage += " | Abort with Ctrl-C";
            writeProgress(progressMessage);
        }, { ignorePatterns: [/\.db/] }, sessionTempDir, uuidGenerator);
        clearProgressMessage();
    }

    if (dbInputs.length > 0) {
        const { bsonDatabase } = await loadDatabase(options.db, options, uuidGenerator, timestampProvider, sessionId);
        const metadataCollection = bsonDatabase.collection<IAsset>("metadata");
        for (const input of dbInputs) {
            const kind = classifyInput(input);
            if (kind === "assetId") {
                const asset = await metadataCollection.getOne(input);
                if (asset) {
                    results.push(assetToFileAnalysis(asset, input));
                }
                else {
                    results.push({
                        path: "",
                        logicalPath: `Asset ID: ${input}`,
                        error: "Asset not found in database"
                    });
                }
            }
            else {
                const assets = await metadataCollection.sortIndex("hash", "asc").findByValue(input);
                if (assets.length === 0) {
                    results.push({
                        path: "",
                        logicalPath: `Hash: ${input}`,
                        error: "No asset with this hash found in database"
                    });
                }
                else {
                    const total = assets.length;
                    assets.forEach((asset, index) => {
                        const label = total > 1 ? `Hash: ${input} (${index + 1} of ${total})` : `Hash: ${input}`;
                        results.push(assetToFileAnalysis(asset, label));
                    });
                }
            }
        }
    }

    const totalCount = results.length;
    log.info(`\nInfo for ${totalCount} item(s):\n`);

    for (const result of results) {
        displayFileInfo(result, options);
        log.info('');
    }

    log.info(pc.green(`\nDisplayed info for ${totalCount} item(s).`));
    log.info('');

    await exit(0);
}

function assetToFileAnalysis(asset: IAsset, logicalPath: string): FileAnalysis {
    return {
        path: asset.origPath ?? asset.origFileName,
        logicalPath,
        hash: asset.hash,
        asset
    };
}

async function analyzeFile(filePath: string, contentType: string, fileInfo: IFileStat, logicalPath: string): Promise<FileAnalysis> {
    // filePath is either the temporary unpacked file path or the original source file path
    let fileAnalysis: FileAnalysis = {
        path: filePath,
        fileStat: fileInfo,
        logicalPath, // Include logical path if provided (shows location in zip files)
    };
    
    try {
        // Calculate file hash
        try {
            const fileStream = createReadStream(filePath);
            const hashBuffer = await computeHash(fileStream);
            fileAnalysis.hash = hashBuffer.toString("hex");
        } 
        catch (error) {
            log.verbose(`Failed to calculate hash for ${filePath}: ${error}`);
        }

        // Analyze file content using the unified getFileInfo function
        // Files are already unpacked, so we can use the file path directly
        try {
            const assetInfo = await getFileInfo(filePath, contentType);        
            if (assetInfo) {
                fileAnalysis.assetInfo = assetInfo;
            }
        } 
        catch (error) {
            fileAnalysis.error = `Failed to analyze file: ${error}`;
        }
    } catch (error) {
        fileAnalysis.error = `Failed to analyze file: ${error instanceof Error ? error.message : String(error)}`;
    }

    return fileAnalysis;
}

function displayFileInfo(analysis: FileAnalysis, options: IInfoCommandOptions) {
    const { path, fileStat: fileInfo, assetInfo, hash, error, logicalPath, asset } = analysis;

    log.info(pc.bold(pc.blue(`📁 ${logicalPath}`)));

    if (error) {
        log.info(`   ${pc.red(`Error: ${error}`)}`);
        return;
    }

    if (asset) {
        displayAssetInfo(asset);
        return;
    }

    if (!fileInfo) {
        return;
    }

    const mimeType = fileInfo.contentType || mime.getType(path) || 'application/octet-stream';
    log.info(`   Type: ${mimeType}`);
    if (hash) {
        log.info(`   Hash: ${hash}`);
    }
    log.info(`   Size: ${formatBytes(fileInfo.length)}`);
    log.info(`   Modified: ${fileInfo.lastModified.toLocaleString()}`);
    if (assetInfo?.dimensions) {
        log.info(`   Dimensions: ${assetInfo.dimensions.width} × ${assetInfo.dimensions.height}`);
    }
    if (analysis.error) {
        log.info(`   ${pc.yellow(`Analysis Error: ${analysis.error}`)}`);
    }
}

function displayAssetInfo(asset: IAsset) {
    log.info(`   Asset ID: ${asset._id}`);
    log.info(`   Original file: ${asset.origFileName}`);
    if (asset.origPath) {
        log.info(`   Original path: ${asset.origPath}`);
    }
    log.info(`   Type: ${asset.contentType}`);
    log.info(`   Hash: ${asset.hash}`);
    log.info(`   Dimensions: ${asset.width} × ${asset.height}`);
    log.info(`   File date: ${asset.fileDate}`);
    if (asset.photoDate) {
        log.info(`   Photo date: ${asset.photoDate}`);
    }
    log.info(`   Upload date: ${asset.uploadDate}`);
    if (asset.duration !== undefined) {
        log.info(`   Duration: ${asset.duration}s`);
    }
    if (asset.location) {
        log.info(`   Location: ${asset.location}`);
    }
    if (asset.coordinates) {
        log.info(`   Coordinates: ${asset.coordinates.lat}, ${asset.coordinates.lng}`);
    }
    if (asset.labels?.length) {
        log.info(`   Labels: ${asset.labels.join(", ")}`);
    }
    if (asset.description) {
        log.info(`   Description: ${asset.description}`);
    }
}
