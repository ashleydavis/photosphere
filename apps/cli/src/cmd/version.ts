import { verifyTools } from "tools";
import { Image } from "tools";
import pc from "picocolors";
import { version as packageVersion } from '../../package.json';
import { log } from "utils";
import { configureLog } from "../lib/log";

//
// Command that displays version information for psi and its dependencies.
//
export async function versionCommand(): Promise<void> {

    log.info('');
    log.info(pc.bold('📋 Version Information\n'));
    
    // Show psi version
    log.info(`${pc.bold('psi')}: ${pc.green(packageVersion)}`);
    
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
    
    // Show overall status
    if (toolsStatus.allAvailable) {
        log.info(pc.green('✅ All dependencies are available'));
    } else {
        log.info(pc.yellow(`⚠️  Some dependencies are missing: ${toolsStatus.missingTools.join(', ')}`));
        log.info(pc.dim('Run "psi tools" for installation instructions'));
    }
}