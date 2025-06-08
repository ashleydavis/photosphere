// This file is deprecated as we now rely on system-installed tools
// Tools should be installed using package managers:
// - Linux: apt, dnf, pacman, etc.
// - macOS: Homebrew, MacPorts
// - Windows: Chocolatey, Scoop

export function getToolsDirectory(): string {
    // No longer used - keeping for backward compatibility
    return '';
}

export async function promptAndDownloadTools(missingTools: string[], nonInteractive: boolean = false): Promise<boolean> {
    // No longer supported - tools must be installed via system package managers
    console.error('Automatic tool download is no longer supported.');
    console.error('Please install the required tools using your system package manager.');
    return false;
}