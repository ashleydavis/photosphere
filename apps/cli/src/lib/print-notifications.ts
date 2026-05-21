import pc from "picocolors";
import { log } from "utils";
import { type INewsItem } from "node-api";
import { checkForUpdates, markUpdateAsShown } from "./check-for-updates";
import { checkForNews } from "./check-for-news";

//
// Prints a single news item to stdout in the standard CLI presentation: a bold "📰 News:"
// heading, the message body, and the optional inline link and CTA action printed as
// label/URL pairs. Shared by printNotifications() and the `psi news` command so both
// surfaces look identical.
//
export function printNewsItem(item: INewsItem): void {
    log.info('');
    log.info(pc.bold('📰 News:'));
    log.info(`   ${item.message}`);
    if (item.link) {
        log.info(pc.dim(`   ${item.link.label}: ${item.link.url}`));
    }
    if (item.action) {
        log.info(pc.dim(`   ${item.action.label}: ${item.action.url}`));
    }
}

//
// Prints any available update notification followed by the next unseen news item.
// Invoked as a commander preAction hook so that every CLI command surfaces these
// notifications before doing its own work. Network and parse errors are swallowed by
// the underlying check functions, so this call never blocks the user.
//
// The `psi news` command skips this hook and renders its own (always-on, full-feed)
// listing instead (see cmd/news.ts).
//
export async function printNotifications(): Promise<void> {
    const updateVersion = await checkForUpdates();
    if (updateVersion) {
        log.info('');
        log.info(pc.bold(pc.green(`📦 A new version is available: v${updateVersion}`)));
        log.info(pc.dim('   https://github.com/ashleydavis/photosphere/releases/latest'));
        await markUpdateAsShown(updateVersion);
    }

    const news = await checkForNews();
    if (news) {
        printNewsItem(news);
    }
}
