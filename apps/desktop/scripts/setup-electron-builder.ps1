# Setup winCodeSign cache to avoid symlink extraction errors on Windows
# This script downloads and extracts the winCodeSign archive to the location
# electron-builder expects, so it will skip the download/extraction step.
# Run this once before building on Windows.

$ErrorActionPreference = "Stop"

Write-Host "Setting up winCodeSign cache..." -ForegroundColor Cyan

$cacheBaseDir = "$env:LOCALAPPDATA\electron-builder\Cache\winCodeSign"
$version = "2.6.0"
$targetDir = Join-Path $cacheBaseDir "winCodeSign-$version"
$archiveUrl = "https://github.com/electron-userland/electron-builder-binaries/releases/download/winCodeSign-$version/winCodeSign-$version.7z"
$tempArchive = Join-Path $env:TEMP "winCodeSign-$version.7z"

# Check if already extracted
if (Test-Path $targetDir) {
    Write-Host "winCodeSign cache already exists at: $targetDir" -ForegroundColor Green
    Write-Host "Skipping download and extraction." -ForegroundColor Yellow
    exit 0
}

# Create cache directory if it doesn't exist
if (-not (Test-Path $cacheBaseDir)) {
    New-Item -ItemType Directory -Path $cacheBaseDir -Force | Out-Null
    Write-Host "Created cache directory: $cacheBaseDir" -ForegroundColor Cyan
}

# Find 7za.exe - search in multiple possible locations
$rootDir = Join-Path $PSScriptRoot "..\.."
$rootDir = Resolve-Path $rootDir -ErrorAction SilentlyContinue
if (-not $rootDir) {
    $rootDir = Join-Path $PSScriptRoot "..\.."
}

$possiblePaths = @(
    # Root node_modules (monorepo)
    Join-Path $rootDir "node_modules\7zip-bin\win\x64\7za.exe"
    # electron-builder's node_modules
    Join-Path $rootDir "node_modules\electron-builder\node_modules\7zip-bin\win\x64\7za.exe"
    # Search recursively in node_modules
    (Get-ChildItem -Path (Join-Path $rootDir "node_modules") -Filter "7za.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
)

$sevenZipPath = $null
foreach ($path in $possiblePaths) {
    if ($path -and (Test-Path $path)) {
        $sevenZipPath = $path
        Write-Host "Found 7za.exe at: $path" -ForegroundColor Green
        break
    }
}

if (-not $sevenZipPath) {
    Write-Host "Could not find 7za.exe in node_modules." -ForegroundColor Yellow
    Write-Host "Searching for system-installed 7-Zip..." -ForegroundColor Cyan
    
    # Try to find system 7-Zip
    $systemPaths = @(
        "${env:ProgramFiles}\7-Zip\7z.exe"
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
        "${env:ProgramFiles}\7-Zip\7za.exe"
        "${env:ProgramFiles(x86)}\7-Zip\7za.exe"
    )
    
    foreach ($sysPath in $systemPaths) {
        if (Test-Path $sysPath) {
            $sevenZipPath = $sysPath
            Write-Host "Found system 7-Zip at: $sysPath" -ForegroundColor Green
            break
        }
    }
}

if (-not $sevenZipPath) {
    Write-Host ""
    Write-Host "Could not find 7za.exe. Downloading standalone 7za.exe..." -ForegroundColor Yellow
    
    # Download standalone 7za.exe (single executable, no installation needed)
    $sevenZipTempDir = Join-Path $env:TEMP "7zip-standalone"
    $sevenZipStandaloneExe = Join-Path $sevenZipTempDir "7za.exe"
    
    # Check if already downloaded
    if (-not (Test-Path $sevenZipStandaloneExe)) {
        Write-Host "Downloading 7za.exe..." -ForegroundColor Cyan
        
        # Download from a reliable source that hosts standalone 7za.exe
        $sevenZipStandaloneUrl = "https://github.com/develar/7zip-bin/raw/master/win/x64/7za.exe"
        
        try {
            New-Item -ItemType Directory -Path $sevenZipTempDir -Force | Out-Null
            Invoke-WebRequest -Uri $sevenZipStandaloneUrl -OutFile $sevenZipStandaloneExe -UseBasicParsing
            Write-Host "Downloaded 7za.exe." -ForegroundColor Green
            $sevenZipPath = $sevenZipStandaloneExe
        }
        catch {
            Write-Host "Failed to download 7za.exe: $_" -ForegroundColor Red
            Write-Host ""
            Write-Host "Please install 7-Zip from https://www.7-zip.org/ and run this script again." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Or manually extract:" -ForegroundColor Yellow
            Write-Host "  - Download: $archiveUrl" -ForegroundColor Gray
            Write-Host "  - Extract to: $targetDir" -ForegroundColor Gray
            Write-Host "  - Skip symlinks during extraction" -ForegroundColor Gray
            exit 1
        }
    }
    else {
        $sevenZipPath = $sevenZipStandaloneExe
        Write-Host "Using cached 7za.exe." -ForegroundColor Green
    }
}

# Download the archive
Write-Host "Downloading winCodeSign archive..." -ForegroundColor Cyan
Write-Host "URL: $archiveUrl" -ForegroundColor Gray
Write-Host "Destination: $tempArchive" -ForegroundColor Gray

try {
    Invoke-WebRequest -Uri $archiveUrl -OutFile $tempArchive -UseBasicParsing
    Write-Host "Download complete." -ForegroundColor Green
}
catch {
    Write-Host "Failed to download archive: $_" -ForegroundColor Red
    exit 1
}

# Extract the archive (skip symlinks to avoid permission errors)
Write-Host "Extracting archive..." -ForegroundColor Cyan
Write-Host "Extracting to: $cacheBaseDir" -ForegroundColor Gray

# Extract to a temp location first to see the structure
$tempExtractDir = Join-Path $env:TEMP "winCodeSign-extract"
if (Test-Path $tempExtractDir) {
    Remove-Item -Recurse -Force $tempExtractDir -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $tempExtractDir -Force | Out-Null

# Use -snl flag to skip symlinks (no admin needed)
# Extract to temp location first
$process = Start-Process -FilePath $sevenZipPath -ArgumentList "x", "-y", "-snl", "-bd", "`"$tempArchive`"", "-o`"$tempExtractDir`"" -Wait -NoNewWindow -PassThru

if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 2) {
    # Exit code 2 means warnings (like symlink skips) but extraction continued
    Write-Host "Extraction complete (some symlinks may have been skipped)." -ForegroundColor Green
    
    # Check what was extracted - the archive might contain winCodeSign-2.6.0 folder or just files
    $extractedItems = Get-ChildItem -Path $tempExtractDir
    
    if ($extractedItems.Count -eq 1 -and $extractedItems[0].PSIsContainer -and $extractedItems[0].Name -eq "winCodeSign-$version") {
        # Archive contains winCodeSign-2.6.0 folder - move it to the right place
        Write-Host "Archive contains winCodeSign-$version folder, moving to cache location..." -ForegroundColor Cyan
        Move-Item -Path (Join-Path $tempExtractDir "winCodeSign-$version") -Destination $targetDir -Force
    }
    else {
        # Archive contains files directly - create the folder and move contents
        Write-Host "Archive contains files directly, creating winCodeSign-$version folder..." -ForegroundColor Cyan
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        Move-Item -Path "$tempExtractDir\*" -Destination $targetDir -Force
    }
    
    # Remove macOS-specific darwin folder (not needed for Windows builds and contains problematic symlinks)
    $darwinPath = Join-Path $targetDir "darwin"
    if (Test-Path $darwinPath) {
        Write-Host "Removing macOS-specific darwin folder (not needed for Windows builds)..." -ForegroundColor Cyan
        Remove-Item -Recurse -Force $darwinPath -ErrorAction SilentlyContinue
    }
    
    # Clean up temp extraction directory
    Remove-Item -Recurse -Force $tempExtractDir -ErrorAction SilentlyContinue
    
    # Verify the target directory exists and has content
    if (Test-Path $targetDir) {
        $fileCount = (Get-ChildItem -Path $targetDir -Recurse -File).Count
        Write-Host ""
        Write-Host "Success! winCodeSign cache is now set up at:" -ForegroundColor Green
        Write-Host "  $targetDir" -ForegroundColor Gray
        Write-Host "  ($fileCount files extracted)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "You can now run 'bun run build' without symlink extraction errors." -ForegroundColor Green
    }
    else {
        Write-Host "Error: Target directory not found after extraction." -ForegroundColor Red
        Write-Host "Expected: $targetDir" -ForegroundColor Gray
        exit 1
    }
}
else {
    Write-Host "Failed to extract archive (exit code: $($process.ExitCode))" -ForegroundColor Red
    Write-Host "You may need to extract manually:" -ForegroundColor Yellow
    Write-Host "  1. Download: $archiveUrl" -ForegroundColor Gray
    Write-Host "  2. Extract to: $targetDir" -ForegroundColor Gray
    Write-Host "  3. Skip symlinks during extraction" -ForegroundColor Gray
    exit 1
}

# Clean up temporary archive
if (Test-Path $tempArchive) {
    Remove-Item $tempArchive -Force -ErrorAction SilentlyContinue
    Write-Host "Cleaned up temporary archive." -ForegroundColor Gray
}
