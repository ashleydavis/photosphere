import { verifyTools } from "tools";
import { Image } from "tools";
import pc from "picocolors";
import { log } from "utils";
import { version } from "config";
import { buildMetadata } from "config";
import { join } from "path";
import { getCacheDir, getConfigDir, getProcessTmpDir } from "node-utils";
import { CURRENT_DATABASE_VERSION } from "merkle-tree";

//
// Command that displays version information for psi and its dependencies.
//
export async function versionCommand(): Promise<void> {

    log.info('');
    log.info(pc.bold('📋 Version Information\n'));
    
    // Show psi version
    log.info(`${pc.bold('Photosphere')}: ${pc.green(version)}`);
    
    // Show database version
    log.info(`${pc.bold('Database version')}: ${pc.green(CURRENT_DATABASE_VERSION.toString())}`);
       
    // Show build information if available
    if (buildMetadata.commitHash !== "dev") {
        log.info(`${pc.bold('Commit')}: ${pc.cyan(buildMetadata.commitHash.substring(0, 8))}`);
        if (buildMetadata.buildDate !== "development") {
            log.info(`${pc.bold('Built')}: ${pc.dim(buildMetadata.buildDate)}`);
        }
        if (buildMetadata.isNightly) {
            log.info(`${pc.bold('Type')}: ${pc.yellow('Nightly Build')}`);
        }
    }
    
    // Get tool versions
    const toolsStatus = await verifyTools();
    
    // Get ImageMagick type to display the correct name
    // Initialize ImageMagick first to ensure we have the correct type
    await Image.verifyImageMagick();
    const imageMagickType = Image.getImageMagickType();
    let imageMagickName = 'ImageMagick';
    
    if (imageMagickType === 'legacy') {
        imageMagickName = 'ImageMagick (convert/identify)';
    } else if (imageMagickType === 'modern') {
        imageMagickName = 'ImageMagick (magick)';
    }
    
    // Display dependency versions
    log.info('');
    log.info(pc.bold('Dependencies:'));
    
    // ImageMagick
    if (toolsStatus.magick.available && toolsStatus.magick.version) {
        log.info(`  ${pc.bold(imageMagickName)}: ${pc.green(toolsStatus.magick.version)}`);
    } else {
        log.info(`  ${pc.bold(imageMagickName)}: ${pc.red('Not found')}`);
    }
    
    // FFmpeg
    if (toolsStatus.ffmpeg.available && toolsStatus.ffmpeg.version) {
        log.info(`  ${pc.bold('ffmpeg')}: ${pc.green(toolsStatus.ffmpeg.version)}`);
    } else {
        log.info(`  ${pc.bold('ffmpeg')}: ${pc.red('Not found')}`);
    }
    
    // FFprobe
    if (toolsStatus.ffprobe.available && toolsStatus.ffprobe.version) {
        log.info(`  ${pc.bold('ffprobe')}: ${pc.green(toolsStatus.ffprobe.version)}`);
    } else {
        log.info(`  ${pc.bold('ffprobe')}: ${pc.red('Not found')}`);
    }
    
    log.info('');
    
    log.info(pc.bold('Directories:'));
    const configDir = getConfigDir();
    log.info(`  ${pc.bold('Config')}: ${pc.cyan(configDir)}`);
    log.info(`  ${pc.bold('Temp')}: ${pc.cyan(join(getProcessTmpDir(), 'photosphere'))}`);
    log.info(`  ${pc.bold('Log files')}: ${pc.cyan(join(getProcessTmpDir(), 'photosphere', 'logs'))}`);
    // Where this machine keeps what it has worked out about each database, the hash caches among
    // them. A directory per database rather than one file, and this command has no database in hand
    // to name a single one, so it names the root they all sit under.
    log.info(`  ${pc.bold('Cache')}: ${pc.cyan(getCacheDir())}`);
    log.info('');
    
    // Show overall status
    if (toolsStatus.allAvailable) {
        log.info(pc.green('✅ All dependencies are available'));
    } else {
        log.info(pc.yellow(`⚠️  Some dependencies are missing: ${toolsStatus.missingTools.join(', ')}`));
        log.info(pc.dim('Run "psi tools" for installation instructions'));
    }
}