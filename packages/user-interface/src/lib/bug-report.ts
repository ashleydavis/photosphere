import { log } from "utils";
import type { ILogDetails } from "utils";

//
// Generates the bug report template for GitHub.
//
export function generateBugReportTemplate(userAgent: string, logDetails: ILogDetails): string {
    return `## Bug Description
<!-- Please describe the bug you encountered -->

## Steps to Reproduce
1.
2.
3.

## Expected Behavior
<!-- What did you expect to happen? -->

## Actual Behavior
<!-- What actually happened? -->

## System Information
- Application: Photosphere
- User Agent: ${userAgent}

## Log Header
\`\`\`
${logDetails.logHeader}
\`\`\`

## Log File
Please attach the full log file located at:
\`${logDetails.logFilePath || 'No log file available'}\`

You can drag and drop the log file into this issue, or copy and paste its contents into a code block.

## Additional Context
<!-- Add any other context about the problem here -->

`;
}

//
// Creates a GitHub issue URL with the bug report template pre-filled.
//
export function createGitHubIssueUrl(title: string, body: string): string {
    const baseUrl = 'https://github.com/ashleydavis/photosphere/issues/new';
    const params = new URLSearchParams({
        title: title,
        body: body,
        labels: 'bug'
    });

    return `${baseUrl}?${params.toString()}`;
}

//
// Opens a bug report in the default browser, pre-filled with system and log details
// acquired from the log interface.
//
export async function openBugReport(): Promise<void> {
    const logDetails = await log.getLogDetails();
    const template = generateBugReportTemplate(navigator.userAgent, logDetails);
    const url = createGitHubIssueUrl('Bug Report', template);
    window.open(url, '_blank');
}
