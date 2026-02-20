import { configureLog } from "../lib/log";
import { existsSync, readdirSync, statSync, readFileSync } from "fs";
import path from "path";
import os from "os";
import open from "open";
import pc from "picocolors";
import { exit } from "node-utils";
import { text, isCancel, intro, outro } from '../lib/clack/prompts';
import { Image, Video } from "tools";
import { version } from "../lib/version";

export interface IBugReportCommandOptions {
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

    //
    // Don't open the browser automatically
    //
    noBrowser?: boolean;
}

//
// Command that generates a bug report for GitHub
//
export async function bugReportCommand(options: IBugReportCommandOptions): Promise<void> {
    
    await configureLog({
        verbose: options.verbose,
        tools: options.tools,
        disableFileLogging: true
    });
    
    intro(pc.blue("🐛 Photosphere Bug Report\n"));

    // Get system information
    const systemInfo = getSystemInfo();
    const toolVersions = await getToolVersions();
    
    // Get latest log file and header
    const latestLogFile = getLatestLogFile();
    const logHeader = getLogHeader(latestLogFile);
    
    let bugInfo;
    
    if (!options.yes) {
        // Prompt user for bug report details
        
        const title = await text({
            message: "Bug title (short summary):",
            placeholder: "e.g., 'CLI crashes when adding large video files'",
            validate: (value) => {
                if (!value || value.trim().length === 0) {
                    return "Please provide a title for the bug report";
                }
                if (value.trim().length > 100) {
                    return "Title should be under 100 characters";
                }
            }
        });
        
        if (isCancel(title)) {
            outro("Bug report cancelled.");
            await exit(0);
        }
        
        const description = await text({
            message: "Bug description (detailed explanation):",
            placeholder: "Describe what happened in detail...",
            validate: (value) => {
                if (!value || value.trim().length === 0) {
                    return "Please provide a description of the bug";
                }
            }
        });
        
        if (isCancel(description)) {
            outro("Bug report cancelled.");
            await exit(0);
        }
        
        // Steps to reproduce
        
        const steps: string[] = [];
        let stepNumber = 1;

        
        while (true) {
            const step = await text({
                message: `Step ${stepNumber}:`,
                placeholder: stepNumber === 1 ? "e.g., Run command 'psi add /path/to/photos'" : "Next step, or press Enter to finish",
                validate: (value) => {
                    if (stepNumber === 1 && (!value || value.trim().length === 0)) {
                        return "Please provide at least one step";
                    }
                }
            });
            
            if (isCancel(step)) {
                outro("Bug report cancelled.");
                await exit(0);
            }

            if (step === undefined && stepNumber > 1) {
                break; // User pressed Enter without input
            }
            
            const stepText = (step as string).trim();
            if (stepText.length === 0 && stepNumber > 1) {
                break; // User finished entering steps
            }
            
            if (stepText.length > 0) {
                steps.push(`${stepNumber}. ${stepText}`);
                stepNumber++;
            }
        }
        
        const stepsToReproduce = steps.join('\n');
        
        const expectedBehavior = await text({
            message: "Expected behavior:",
            placeholder: "What did you expect to happen?",
            validate: (value) => {
                if (!value || value.trim().length === 0) {
                    return "Please describe what you expected to happen";
                }
            }
        });
        
        if (isCancel(expectedBehavior)) {
            outro("Bug report cancelled.");
            await exit(0);
        }
        
        const actualBehavior = await text({
            message: "Actual behavior:",
            placeholder: "What actually happened?",
            validate: (value) => {
                if (!value || value.trim().length === 0) {
                    return "Please describe what actually happened";
                }
            }
        });
        
        if (isCancel(actualBehavior)) {
            outro("Bug report cancelled.");
            await exit(0);
        }
        
        bugInfo = {
            title: title as string,
            description: description as string,
            stepsToReproduce: stepsToReproduce as string,
            expectedBehavior: expectedBehavior as string,
            actualBehavior: actualBehavior as string
        };
    } else {
        // Non-interactive mode - use generic template
        bugInfo = {
            title: "Bug Report",
            description: "<!-- Please describe the bug you encountered -->",
            stepsToReproduce: "1. \n2. \n3. ",
            expectedBehavior: "<!-- What did you expect to happen? -->",
            actualBehavior: "<!-- What actually happened? -->"
        };
    }
    
    // Generate bug report template (with log header)
    const bugReportTemplate = generateBugReportTemplate(systemInfo, toolVersions, version, bugInfo, logHeader);
    
    // Create GitHub issue URL
    const githubUrl = createGitHubIssueUrl(bugInfo.title, bugReportTemplate);
    
    // Prepare summary information
    const summaryInfo = [
        `Title: ${bugInfo.title}`,
        `Photosphere Version: ${version}`,
        `System: ${systemInfo.platform} ${systemInfo.arch} (${systemInfo.release})`,
        `Log File: ${latestLogFile || 'None available'}`
    ].join('\n');
    
    const logInfo = latestLogFile 
        ? `\n\n${pc.blue("📎 Log File Information:")}\n${pc.dim(`The log file path is included in the bug report template.\nYou can attach it to the GitHub issue by dragging and dropping the file.`)}`
        : '';
    
    if (options.noBrowser) {
        outro(`${pc.green("✓ Bug report generated successfully!")}\n\n${summaryInfo}${logInfo}\n\n${pc.yellow("GitHub Issue URL:")}\n${githubUrl}\n\n${pc.dim("Copy and paste the URL above into your browser to create the issue.")}`);
    } else {
        try {
            await open(githubUrl);
            outro(`${pc.green("✓ Bug report opened in browser!")}\n\n${summaryInfo}${logInfo}`);
        } catch (error) {
            outro(`${pc.green("✓ Bug report generated successfully!")}\n\n${summaryInfo}${logInfo}\n\n${pc.red("Failed to open browser. Here's the URL:")}\n${githubUrl}\n\n${pc.yellow("Please copy the URL above to submit the bug report.")}`);
        }
    }
    
    await exit(0);
}

function getSystemInfo() {
    return {
        platform: os.platform(),
        arch: os.arch(),
        release: os.release(),
        nodeVersion: process.version,
        workingDirectory: process.cwd()
    };
}

async function getToolVersions() {
    const versions = {
        imagemagick: 'Not available',
        ffmpeg: 'Not available',
        ffprobe: 'Not available'
    };
    
    try {
        const imageMagickStatus = await Image.verifyImageMagick();
        if (imageMagickStatus.available && imageMagickStatus.version) {
            versions.imagemagick = `ImageMagick v${imageMagickStatus.version} (${imageMagickStatus.type || 'unknown'})`;
        }
    } catch (error) {
        // ImageMagick not available
    }
    
    try {
        const ffmpegStatus = await Video.verifyFfmpeg();
        if (ffmpegStatus.available && ffmpegStatus.version) {
            versions.ffmpeg = `ffmpeg v${ffmpegStatus.version}`;
        }
    } catch (error) {
        // FFmpeg not available
    }
    
    try {
        const ffprobeStatus = await Video.verifyFfprobe();
        if (ffprobeStatus.available && ffprobeStatus.version) {
            versions.ffprobe = `ffprobe v${ffprobeStatus.version}`;
        }
    } catch (error) {
        // FFprobe not available
    }
    
    return versions;
}

function getLatestLogFile(): string | null {
    try {
        const logsDir = path.join(os.tmpdir(), 'photosphere', 'logs');
        if (!existsSync(logsDir)) {
            return null;
        }
        
        const logFiles = readdirSync(logsDir)
            .filter(file => file.startsWith('psi-') && file.endsWith('.log'))
            .map(file => ({
                name: file,
                path: path.join(logsDir, file),
                mtime: statSync(path.join(logsDir, file)).mtime
            }))
            .sort((a, b) => b.mtime.getTime() - a.mtime.getTime());
        
        return logFiles.length > 0 ? logFiles[0].path : null;
    } catch (error) {
        return null;
    }
}

function getLogHeader(logFilePath: string | null): string {
    if (!logFilePath || !existsSync(logFilePath)) {
        return 'No log file available';
    }
    
    try {
        const logContent = readFileSync(logFilePath, 'utf8');
        const logStartIndex = logContent.indexOf('--- Log Start ---');
        
        if (logStartIndex === -1) {
            // If no "--- Log Start ---" marker found, return first 50 lines
            const lines = logContent.split('\n');
            return lines.slice(0, 50).join('\n');
        }
        
        // Return everything up to (and including) the "--- Log Start ---" line
        const headerContent = logContent.substring(0, logStartIndex + '--- Log Start ---'.length);
        return headerContent;
    } catch (error) {
        return `Error reading log file: ${error instanceof Error ? error.message : 'Unknown error'}`;
    }
}

function generateBugReportTemplate(systemInfo: any, toolVersions: any, photosphereVersion: string, bugInfo: any, logHeader: string): string {
    return `## Bug Description
${bugInfo.description}

## Steps to Reproduce
${bugInfo.stepsToReproduce}

## Expected Behavior
${bugInfo.expectedBehavior}

## Actual Behavior
${bugInfo.actualBehavior}

## System Information
- Photosphere Version: ${photosphereVersion}
- Platform: ${systemInfo.platform} ${systemInfo.arch}
- OS Release: ${systemInfo.release}
- Node.js Version: ${systemInfo.nodeVersion}

## Tool Versions
- ImageMagick: ${toolVersions.imagemagick}
- FFmpeg: ${toolVersions.ffmpeg}
- FFprobe: ${toolVersions.ffprobe}

## Log Header
\`\`\`
${logHeader}
\`\`\`

## Log File
Please attach the full log file located at:
\`${getLatestLogFile() || 'No log file available'}\`

You can drag and drop the log file into this issue, or copy and paste its contents into a code block.

## Additional Context
<!-- Add any other context about the problem here -->

`;
}

function createGitHubIssueUrl(title: string, body: string): string {
    const baseUrl = 'https://github.com/ashleydavis/photosphere/issues/new';
    const params = new URLSearchParams({
        title: title,
        body: body,
        labels: 'bug'
    });
    
    return `${baseUrl}?${params.toString()}`;
}