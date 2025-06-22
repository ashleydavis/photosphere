import { getFileLogger } from "../lib/log";
import { execSync } from "child_process";
import fs from "fs-extra";
import path from "path";
import os from "os";
import open from "open";
import pc from "picocolors";
import { exit } from "node-utils";
import { text, isCancel, intro, outro } from "@clack/prompts";

export interface IBugReportCommandOptions {
    //
    // Enables verbose logging.
    //
    verbose?: boolean;

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
    
    intro(pc.blue("🐛 Photosphere Bug Report"));

    // Get system information
    const systemInfo = getSystemInfo();
    const toolVersions = getToolVersions();
    const photosphereVersion = getPhotosphereVersion();
    
    // Get latest log file
    const latestLogFile = getLatestLogFile();
    const logContent = latestLogFile ? fs.readFileSync(latestLogFile, 'utf8') : 'No log file available';
    
    let bugInfo;
    
    if (!options.yes) {
        // Prompt user for bug report details
        console.log();
        console.log(pc.dim("Please provide details about the bug you encountered:"));
        console.log();
        
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
            outro(pc.gray("Bug report cancelled."));
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
            outro(pc.gray("Bug report cancelled."));
            await exit(0);
        }
        
        const stepsToReproduce = await text({
            message: "Steps to reproduce:",
            placeholder: "1. Run command 'psi add ...' 2. Wait for processing 3. Error occurs",
            validate: (value) => {
                if (!value || value.trim().length === 0) {
                    return "Please provide steps to reproduce the issue";
                }
            }
        });
        
        if (isCancel(stepsToReproduce)) {
            outro(pc.gray("Bug report cancelled."));
            await exit(0);
        }
        
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
            outro(pc.gray("Bug report cancelled."));
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
            outro(pc.gray("Bug report cancelled."));
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
    
    // Generate bug report template (without log content)
    const bugReportTemplate = generateBugReportTemplate(systemInfo, toolVersions, photosphereVersion, bugInfo);
    
    // Create GitHub issue URL
    const githubUrl = createGitHubIssueUrl(bugInfo.title, bugReportTemplate);
    
    console.log();
    console.log(pc.green("✓ Bug report generated successfully!"));
    console.log();
    console.log(pc.bold("Bug Report Details:"));
    console.log(`Title: ${bugInfo.title}`);
    console.log(`Photosphere Version: ${photosphereVersion}`);
    console.log(`System: ${systemInfo.platform} ${systemInfo.arch} (${systemInfo.release})`);
    console.log(`Log File: ${latestLogFile || 'None available'}`);
    console.log();
    
    if (latestLogFile) {
        console.log(pc.blue("📎 Log File Information:"));
        console.log(pc.dim(`The log file path is included in the bug report template.`));
        console.log(pc.dim(`You can attach it to the GitHub issue by dragging and dropping the file.`));
        console.log();
    }
    
    if (options.noBrowser) {
        console.log(pc.yellow("GitHub Issue URL:"));
        console.log(githubUrl);
        console.log();
        console.log(pc.dim("Copy and paste the URL above into your browser to create the issue."));
        outro(pc.green("Bug report ready to submit!"));
    } else {
        console.log(pc.green("Opening GitHub issue page in your browser..."));
        try {
            await open(githubUrl);
            outro(pc.green("Bug report opened in browser!"));
        } catch (error) {
            console.log(pc.red("Failed to open browser. Here's the URL:"));
            console.log(githubUrl);
            outro(pc.yellow("Please copy the URL above to submit the bug report."));
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

function getToolVersions() {
    const versions = {
        imagemagick: 'Not available',
        ffmpeg: 'Not available'
    };
    
    try {
        const imageMagickOutput = execSync('magick -version', { encoding: 'utf8', timeout: 5000 });
        versions.imagemagick = imageMagickOutput.split('\n')[0];
    } catch (error) {
        // ImageMagick not available
    }
    
    try {
        const ffmpegOutput = execSync('ffmpeg -version', { encoding: 'utf8', timeout: 5000 });
        versions.ffmpeg = ffmpegOutput.split('\n')[0];
    } catch (error) {
        // FFmpeg not available
    }
    
    return versions;
}

function getPhotosphereVersion(): string {
    try {
        const packageJsonPath = path.join(__dirname, '../../package.json');
        const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
        return packageJson.version;
    } catch (error) {
        return 'unknown';
    }
}

function getLatestLogFile(): string | null {
    try {
        const logsDir = path.join(os.tmpdir(), 'photosphere', 'logs');
        if (!fs.existsSync(logsDir)) {
            return null;
        }
        
        const logFiles = fs.readdirSync(logsDir)
            .filter(file => file.startsWith('psi-') && file.endsWith('.log'))
            .map(file => ({
                name: file,
                path: path.join(logsDir, file),
                mtime: fs.statSync(path.join(logsDir, file)).mtime
            }))
            .sort((a, b) => b.mtime.getTime() - a.mtime.getTime());
        
        return logFiles.length > 0 ? logFiles[0].path : null;
    } catch (error) {
        return null;
    }
}

function generateBugReportTemplate(systemInfo: any, toolVersions: any, photosphereVersion: string, bugInfo: any): string {
    return `## Bug Description
${bugInfo.description}

## Steps to Reproduce
${bugInfo.stepsToReproduce}

## Expected Behavior
${bugInfo.expectedBehavior}

## Actual Behavior
${bugInfo.actualBehavior}

## System Information
- **Photosphere Version:** ${photosphereVersion}
- **Platform:** ${systemInfo.platform} ${systemInfo.arch}
- **OS Release:** ${systemInfo.release}
- **Node.js Version:** ${systemInfo.nodeVersion}

## Tool Versions
- **ImageMagick:** ${toolVersions.imagemagick}
- **FFmpeg:** ${toolVersions.ffmpeg}

## Log File
Please attach the log file located at:
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