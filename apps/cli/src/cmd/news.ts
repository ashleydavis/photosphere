import pc from "picocolors";
import { log } from "utils";
import { version } from "config";
import { getLatestVersion, markUpdateAsShown } from "../lib/check-for-updates";
import { getAllNews, markNewsAsShown } from "../lib/check-for-news";

//
// Command that always prints the latest update notification (if any) and the full news
// feed, regardless of which items have already been seen. After rendering, every shown
// item is recorded so the standard pre-command notification (oldest unseen news) does
// not re-display the same items on subsequent commands.
//
export async function newsCommand(): Promise<void> {
    log.info('');
    log.info(pc.bold('📋 Photosphere News\n'));

    log.info(`${pc.bold('Running version')}: ${pc.green(`v${version}`)}`);
    const latestVersion = await getLatestVersion();
    if (latestVersion !== undefined) {
        if (latestVersion === version) {
            log.info(`${pc.bold('Latest release')}:  ${pc.green(`v${latestVersion}`)} ${pc.dim('(up to date)')}`);
        }
        else {
            log.info(`${pc.bold('Latest release')}:  ${pc.green(`v${latestVersion}`)} ${pc.bold(pc.green('(update available)'))}`);
            log.info(pc.dim('   https://github.com/ashleydavis/photosphere/releases/latest'));
            await markUpdateAsShown(latestVersion);
        }
    }
    log.info('');

    const allNews = await getAllNews();
    if (allNews.length === 0) {
        log.info(pc.dim('No news items available.'));
        return;
    }

    // Render newest-first so the most recent items are seen first; news.yaml is ordered
    // oldest-first by publishing convention so we reverse here for display only.
    const ordered = [...allNews].reverse();
    for (const entry of ordered) {
        const marker = entry.seen ? pc.dim('•') : pc.green('★');
        const tag = entry.seen ? '' : pc.green(' (new)');
        log.info(`${marker} ${entry.item.message}${tag}`);
        if (entry.item.link) {
            log.info(pc.dim(`     ${entry.item.link.label}: ${entry.item.link.url}`));
        }
        if (entry.item.action) {
            log.info(pc.dim(`     ${entry.item.action.label}: ${entry.item.action.url}`));
        }
    }

    const unseenIds = allNews
        .filter(entry => !entry.seen)
        .map(entry => entry.item.id);
    await markNewsAsShown(unseenIds);
}
