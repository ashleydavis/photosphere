import { version } from "config";
import { getLastShownUpdateVersion, setLastShownUpdateVersion } from "node-api";

//
// URL of the GitHub API endpoint that returns the latest non-prerelease release.
//
const LATEST_RELEASE_URL = "https://api.github.com/repos/ashleydavis/photosphere/releases/latest";

//
// Shape of the response object returned by the GitHub releases/latest endpoint.
//
interface IGitHubReleaseResponse {
    //
    // The git tag for the release (e.g. "v1.2.3").
    //
    tag_name: string;
}

//
// Checks GitHub for the latest Photosphere release and returns the version string
// (without leading "v") when it differs from the running version AND has not
// already been notified to the user (per news.yaml's last_shown_update_version).
// Returns undefined when the running version is current, when it is a non-release
// build ("dev" or nightly), when the user has already been notified about this
// version, or when the network/parse step fails.
//
export async function checkForUpdates(): Promise<string | undefined> {
    const currentVersion: string = version;
    if (currentVersion === "dev" || currentVersion.includes("nightly")) {
        return undefined;
    }

    try {
        const response = await fetch(LATEST_RELEASE_URL);
        if (!response.ok) {
            return undefined;
        }
        const data = await response.json() as IGitHubReleaseResponse;
        if (!data.tag_name || typeof data.tag_name !== "string") {
            return undefined;
        }
        const latestVersion = data.tag_name.startsWith("v")
            ? data.tag_name.slice(1)
            : data.tag_name;
        if (latestVersion === currentVersion) {
            return undefined;
        }
        const lastShown = await getLastShownUpdateVersion();
        if (lastShown === latestVersion) {
            return undefined;
        }
        return latestVersion;
    }
    catch (error) {
        return undefined;
    }
}

//
// Records that the user has been notified about the given update version, so
// subsequent checkForUpdates() calls suppress the notification until a newer
// version ships. Persistence failures are swallowed silently.
//
export async function markUpdateAsShown(latestVersion: string): Promise<void> {
    try {
        await setLastShownUpdateVersion(latestVersion);
    }
    catch (error) {
        // Update persistence failures must never block the user.
    }
}

//
// Returns the latest release version reported by GitHub (without the leading "v"),
// or undefined when the running build is dev/nightly or the fetch/parse step fails.
// Unlike checkForUpdates(), this does NOT apply the `last_shown_update_version` dedup,
// does NOT compare to the running version, and does NOT record anything. Used by
// `psi news` to always show the latest available version when known.
//
export async function getLatestVersion(): Promise<string | undefined> {
    const currentVersion: string = version;
    if (currentVersion === "dev" || currentVersion.includes("nightly")) {
        return undefined;
    }
    try {
        const response = await fetch(LATEST_RELEASE_URL);
        if (!response.ok) {
            return undefined;
        }
        const data = await response.json() as IGitHubReleaseResponse;
        if (!data.tag_name || typeof data.tag_name !== "string") {
            return undefined;
        }
        return data.tag_name.startsWith("v")
            ? data.tag_name.slice(1)
            : data.tag_name;
    }
    catch (error) {
        return undefined;
    }
}
