# Photosphere CLI Installation Guide

## Prerequisites

Before installing Photosphere CLI, you need to install the required media processing tools:

### 1. Install FFmpeg

FFmpeg is required for video processing and metadata extraction.

**Windows:**
- Download from [https://ffmpeg.org/download.html#build-windows](https://ffmpeg.org/download.html#build-windows)
- Extract to a folder (e.g., `C:\ffmpeg`)
- Add `C:\ffmpeg\bin` to your PATH environment variable

**macOS:**
```bash
# Using Homebrew (recommended)
brew install ffmpeg

# Using MacPorts
sudo port install ffmpeg
```

**Linux (Ubuntu/Debian):**
```bash
sudo apt update
sudo apt install ffmpeg
```

**Linux (CentOS/RHEL/Fedora):**
```bash
# Fedora
sudo dnf install ffmpeg

# CentOS/RHEL (enable EPEL repository first)
sudo yum install epel-release
sudo yum install ffmpeg
```

### 2. Install ImageMagick

ImageMagick is required for image processing and thumbnail generation.

**Windows:**
- Download from [https://imagemagick.org/script/download.php#windows](https://imagemagick.org/script/download.php#windows)
- Run the installer and ensure "Install development headers and libraries for C and C++" is checked
- Make sure ImageMagick is added to your PATH

**macOS:**
```bash
# Using Homebrew (recommended)
brew install imagemagick

# Using MacPorts
sudo port install ImageMagick
```

**Linux (Ubuntu/Debian):**
```bash
sudo apt update
sudo apt install imagemagick
```

**Linux (CentOS/RHEL/Fedora):**
```bash
# Fedora
sudo dnf install ImageMagick

# CentOS/RHEL
sudo yum install ImageMagick
```

### 3. Verify Installation

Check that both tools are installed and accessible:

```bash
ffmpeg -version
ffprobe -version
magick -version
# or on older systems:
convert -version
```

All commands should return version information without errors.

## Install Photosphere CLI

### Step 1: Download

1. Go to the [Photosphere releases page](https://github.com/your-org/photosphere/releases)
2. Download the appropriate binary for your platform:
   - **Linux**: `psi-linux-x64` or `psi-linux-arm64`
   - **Windows**: `psi-windows-x64.exe`
   - **macOS**: `psi-macos-x64` or `psi-macos-arm64`

### Step 2: Make Executable (Linux/macOS)

After downloading, you need to make the binary executable:

```bash
# Rename for convenience (optional)
mv psi-linux-x64 psi        # Linux
mv psi-macos-x64 psi        # macOS

# Make executable
chmod +x psi

# Verify permissions
ls -la psi
```

You should see permissions like `-rwxr-xr-x`.

### Step 3: Remove Quarantine (macOS Only)

macOS blocks unsigned binaries by default. Remove the quarantine attribute:

```bash
xattr -c ./psi
```

This is safe for trusted software like Photosphere CLI.

### Step 4: Move to PATH (Optional)

For system-wide access, move the binary to a directory in your PATH:

```bash
# Linux/macOS
sudo mv psi /usr/local/bin/

# Or create a local bin directory
mkdir -p ~/bin
mv psi ~/bin/
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

**Windows**: Move `psi.exe` to a folder in your PATH, or add its location to your PATH environment variable.

## Verify Installation

Test that everything works:

```bash
# Check that Photosphere CLI is working
psi --version

# Verify required tools are detected
psi tools
```

The `psi tools` command will check that FFmpeg and ImageMagick are properly installed and accessible.

## Quick Start

Now you're ready to use Photosphere CLI:

```bash
# Create a new photo database
psi init ~/my-photos

# Add some photos
psi add ~/my-photos ~/Pictures/*.jpg

# Launch the web interface
psi ui ~/my-photos
```

## Troubleshooting

### "Command not found"
- Make sure the binary is executable (`chmod +x psi`)
- Check that it's in your PATH or use the full path to the binary

### "Cannot be opened" (macOS)
- Run `xattr -c ./psi` to remove quarantine attributes
- Make sure you downloaded the correct architecture (x64 vs arm64)

### "Tool not found" errors
- Install FFmpeg and ImageMagick using the instructions above
- Make sure they're in your system PATH
- Run `psi tools` to diagnose tool detection issues

### Permission denied
- Make sure you have write permissions to the database directory
- Run with `sudo` only if absolutely necessary

For more detailed usage instructions, see the [Getting Started Guide](cli-getting-started.md).