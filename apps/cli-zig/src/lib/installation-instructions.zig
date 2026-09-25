const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const pc = @import("picocolors.zig");
const log = &utils.log.log;

//
// True when the list of missing tools contains the tool.
//
fn includes(missingTools: []const []const u8, tool: []const u8) bool {
    for (missingTools) |missingTool| {
        if (std.mem.eql(u8, missingTool, tool)) {
            return true;
        }
    }
    return false;
}


//
// Shows platform-specific installation instructions for missing tools
//
pub fn showInstallationInstructions(allocator: std.mem.Allocator, missingTools: []const []const u8) !void {
    log.info("");
    log.info(try pc.bold(allocator, "Installation Instructions:"));
    log.info("");

    // Check which tools are missing to provide targeted instructions
    const needsImageMagick = includes(missingTools, "ImageMagick");
    const needsFfmpeg = includes(missingTools, "ffmpeg") or includes(missingTools, "ffprobe");

    // Provide platform-specific installation instructions
    const currentPlatform = builtin.os.tag;

    switch (currentPlatform) {
        .windows => {
            try showWindowsInstructions(allocator, needsImageMagick, needsFfmpeg);
        },

        .macos => {
            try showMacOSInstructions(allocator, needsImageMagick, needsFfmpeg);
        },

        .linux => {
            try showLinuxInstructions(allocator, needsImageMagick, needsFfmpeg);
        },

        else => {
            try showGenericInstructions(allocator, needsImageMagick, needsFfmpeg);
        },
    }

    log.info("");
    log.info(try pc.dim(allocator, "After installation, run this command again to verify all tools are available."));
}

//
// Shows the Windows instructions.
//
fn showWindowsInstructions(allocator: std.mem.Allocator, needsImageMagick: bool, needsFfmpeg: bool) !void {
    log.info(try pc.cyan(allocator, "Windows:"));
    log.info("");

    if (needsImageMagick and needsFfmpeg) {
        log.info(try std.mem.concat(allocator, u8, &.{ try pc.bold(allocator, "Using Chocolatey"), " (recommended):" }));
        log.info("  choco install imagemagick ffmpeg");
        log.info("  Chocolatey: https://chocolatey.org/install");
        log.info("");
        log.info(try pc.bold(allocator, "Using Scoop:"));
        log.info("  scoop install imagemagick ffmpeg");
        log.info("  Scoop: https://scoop.sh");
    }
    else if (needsImageMagick) {
        log.info(try std.mem.concat(allocator, u8, &.{ try pc.bold(allocator, "Using Chocolatey"), " (recommended):" }));
        log.info("  choco install imagemagick");
        log.info("  Chocolatey: https://chocolatey.org/install");
        log.info("");
        log.info(try pc.bold(allocator, "Using Scoop:"));
        log.info("  scoop install imagemagick");
        log.info("  Scoop: https://scoop.sh");
    }
    else if (needsFfmpeg) {
        log.info(try std.mem.concat(allocator, u8, &.{ try pc.bold(allocator, "Using Chocolatey"), " (recommended):" }));
        log.info("  choco install ffmpeg");
        log.info("  Chocolatey: https://chocolatey.org/install");
        log.info("");
        log.info(try pc.bold(allocator, "Using Scoop:"));
        log.info("  scoop install ffmpeg");
        log.info("  Scoop: https://scoop.sh");
    }

    log.info("");
    log.info(try pc.bold(allocator, "Manual installation:"));
    if (needsImageMagick) {
        log.info("  • ImageMagick:");
        log.info("    1. Download the Windows installer from https://imagemagick.org/script/download.php#windows");
        log.info("    2. Run the installer and tick \"Add application directory to your system path\"");
        log.info("    3. Also tick \"Install legacy utilities (e.g. convert)\"");
        log.info("    4. Open a new terminal and run \"magick -version\" to verify");
    }
    if (needsFfmpeg) {
        log.info("  • ffmpeg:");
        log.info("    1. Download the \"release essentials\" build from https://www.gyan.dev/ffmpeg/builds/");
        log.info("       (includes ffprobe)");
        log.info("    2. Extract the zip to a folder, e.g. C:\\ffmpeg");
        log.info("    3. Add the bin folder (e.g. C:\\ffmpeg\\bin) to your PATH environment variable");
        log.info("    4. Open a new terminal and run \"ffmpeg -version\" to verify");
    }
}

//
// Shows the macOS instructions.
//
fn showMacOSInstructions(allocator: std.mem.Allocator, needsImageMagick: bool, needsFfmpeg: bool) !void {
    log.info(try pc.cyan(allocator, "macOS:"));
    log.info("");

    if (needsImageMagick and needsFfmpeg) {
        log.info(try std.mem.concat(allocator, u8, &.{ try pc.bold(allocator, "Using Homebrew"), " (recommended):" }));
        log.info("  brew install imagemagick ffmpeg");
        log.info("  Homebrew: https://brew.sh");
        log.info("");
        log.info(try pc.bold(allocator, "Using MacPorts:"));
        log.info("  sudo port install ImageMagick +universal");
        log.info("  sudo port install ffmpeg +universal");
        log.info("  MacPorts: https://www.macports.org/install.php");
    }
    else if (needsImageMagick) {
        log.info(try std.mem.concat(allocator, u8, &.{ try pc.bold(allocator, "Using Homebrew"), " (recommended):" }));
        log.info("  brew install imagemagick");
        log.info("  Homebrew: https://brew.sh");
        log.info("");
        log.info(try pc.bold(allocator, "Using MacPorts:"));
        log.info("  sudo port install ImageMagick +universal");
        log.info("  MacPorts: https://www.macports.org/install.php");
    }
    else if (needsFfmpeg) {
        log.info(try std.mem.concat(allocator, u8, &.{ try pc.bold(allocator, "Using Homebrew"), " (recommended):" }));
        log.info("  brew install ffmpeg");
        log.info("  Homebrew: https://brew.sh");
        log.info("");
        log.info(try pc.bold(allocator, "Using MacPorts:"));
        log.info("  sudo port install ffmpeg +universal");
        log.info("  MacPorts: https://www.macports.org/install.php");
    }

    log.info("");
    log.info(try pc.bold(allocator, "Manual installation:"));
    if (needsImageMagick) {
        log.info("  • ImageMagick:");
        log.info("    1. Download the macOS build from https://imagemagick.org/script/download.php#macosx");
        log.info("    2. Extract it and move the contents to a folder, e.g. /usr/local/imagemagick");
        log.info("    3. Add the bin folder to your PATH, e.g. add this to ~/.zshrc:");
        log.info("       export PATH=\"/usr/local/imagemagick/bin:$PATH\"");
        log.info("    4. Open a new terminal and run \"magick -version\" to verify");
    }
    if (needsFfmpeg) {
        log.info("  • ffmpeg:");
        log.info("    1. Download ffmpeg and ffprobe from https://evermeet.cx/ffmpeg/");
        log.info("    2. Extract the archives and move both binaries to /usr/local/bin");
        log.info("    3. Open a new terminal and run \"ffmpeg -version\" to verify");
    }
}

//
// Shows the Linux instructions.
//
fn showLinuxInstructions(allocator: std.mem.Allocator, needsImageMagick: bool, needsFfmpeg: bool) !void {
    log.info(try pc.cyan(allocator, "Linux:"));
    log.info("");

    if (needsImageMagick and needsFfmpeg) {
        log.info(try pc.bold(allocator, "Ubuntu/Debian:"));
        log.info("  sudo apt update");
        log.info("  sudo apt install imagemagick ffmpeg");
        log.info("");
        log.info(try pc.bold(allocator, "Fedora/RHEL/CentOS:"));
        log.info("  sudo dnf install ImageMagick ffmpeg");
        log.info("");
        log.info(try pc.bold(allocator, "Arch Linux:"));
        log.info("  sudo pacman -S imagemagick ffmpeg");
        log.info("");
        log.info(try pc.bold(allocator, "Alpine Linux:"));
        log.info("  sudo apk add imagemagick ffmpeg");
    }
    else if (needsImageMagick) {
        log.info(try pc.bold(allocator, "Ubuntu/Debian:"));
        log.info("  sudo apt update");
        log.info("  sudo apt install imagemagick");
        log.info("");
        log.info(try pc.bold(allocator, "Fedora/RHEL/CentOS:"));
        log.info("  sudo dnf install ImageMagick");
        log.info("");
        log.info(try pc.bold(allocator, "Arch Linux:"));
        log.info("  sudo pacman -S imagemagick");
        log.info("");
        log.info(try pc.bold(allocator, "Alpine Linux:"));
        log.info("  sudo apk add imagemagick");
    }
    else if (needsFfmpeg) {
        log.info(try pc.bold(allocator, "Ubuntu/Debian:"));
        log.info("  sudo apt update");
        log.info("  sudo apt install ffmpeg");
        log.info("");
        log.info(try pc.bold(allocator, "Fedora/RHEL/CentOS:"));
        log.info("  sudo dnf install ffmpeg");
        log.info("");
        log.info(try pc.bold(allocator, "Arch Linux:"));
        log.info("  sudo pacman -S ffmpeg");
        log.info("");
        log.info(try pc.bold(allocator, "Alpine Linux:"));
        log.info("  sudo apk add ffmpeg");
    }

    log.info("");
    log.info(try pc.bold(allocator, "Manual/Binary installation:"));
    if (needsImageMagick) {
        log.info("  • ImageMagick:");
        log.info("    1. Download the AppImage from https://imagemagick.org/script/download.php#linux");
        log.info("    2. Make it executable and place it on your PATH:");
        log.info("       chmod +x ImageMagick-*.AppImage && sudo mv ImageMagick-*.AppImage /usr/local/bin/magick");
        log.info("    3. Run \"magick -version\" to verify");
    }
    if (needsFfmpeg) {
        log.info("  • ffmpeg:");
        log.info("    1. Download a static build from https://github.com/BtbN/FFmpeg-Builds/releases");
        log.info("       (linked from https://ffmpeg.org/download.html - includes ffprobe)");
        log.info("    2. Extract the archive and copy ffmpeg and ffprobe to /usr/local/bin");
        log.info("    3. Run \"ffmpeg -version\" to verify");
    }
}

//
// Shows the instructions for other platforms.
//
fn showGenericInstructions(allocator: std.mem.Allocator, needsImageMagick: bool, needsFfmpeg: bool) !void {
    log.info("Please install the following tools for your system:");
    log.info("");

    if (needsImageMagick) {
        log.info(try pc.bold(allocator, "ImageMagick:"));
        log.info("  Official site: https://imagemagick.org");
        log.info("  Downloads: https://imagemagick.org/script/download.php");
        log.info("  (Provides both modern \"magick\" and legacy \"convert/identify\" commands)");
        log.info("");
    }
    if (needsFfmpeg) {
        log.info(try pc.bold(allocator, "ffmpeg (includes ffprobe):"));
        log.info("  Official site: https://ffmpeg.org");
        log.info("  Downloads: https://ffmpeg.org/download.html");
    }
}