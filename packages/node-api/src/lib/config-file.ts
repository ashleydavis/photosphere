//
// Reading and writing config.yaml where there is a filesystem: the CLI and the desktop app.
//
// The mobile apps read and write the same document through worker tasks instead (config.worker.ts),
// because a phone's WebView has no filesystem of its own. Both go through config-format.ts, so the
// file means the same thing whichever wrote it. The wiki page "Configuration-File" documents it for
// users.
//

import * as path from "path";
import { getConfigDir, readYaml, updateYaml, writeYaml } from "node-utils";
import {
    configFileToYaml,
    defaultConfigFile,
    yamlToConfigFile,
    type IConfigFile,
    type IYamlConfigFile,
} from "./config-format";

//
// Returns the absolute path of the config file. PHOTOSPHERE_CONFIG_DIR moves it, which is how the
// smoke tests give each run its own settings and how two installations run side by side.
//
export function getConfigPath(): string {
    return path.join(getConfigDir(), "config.yaml");
}

//
// Loads the configuration from disk, returning the defaults when there is no file yet.
//
export async function loadConfigFile(): Promise<IConfigFile> {
    const document = await readYaml<IYamlConfigFile>(getConfigPath());
    return yamlToConfigFile(document);
}

//
// Writes the whole configuration to disk, replacing whatever was there.
//
// Only for a caller that has the complete configuration in hand, which in practice means a test or a
// first write. Everything the app does goes through updateConfigFile instead, for the reason recorded
// there.
//
export async function saveConfigFile(config: IConfigFile): Promise<void> {
    await writeYaml(getConfigPath(), configFileToYaml(config));
}

//
// Changes the configuration on disk. Every edit the app makes goes through here.
//
// The mutator is handed the file's CURRENT contents and changes them in place. updateYaml runs it
// under the update lock beside the file, checks the file has not moved before renaming, and re-runs
// the mutator against the new contents if it has, so two edits arriving together both survive.
//
// A load-then-save pair in its place would silently discard any edit made between the read and the
// write, and the window is not theoretical: a folder picker stays open for as long as the user takes
// to choose, so a config read before the dialog opened is stale by the time it closes.
//
export async function updateConfigFile(mutator: (config: IConfigFile) => void): Promise<void> {
    await updateYaml<IYamlConfigFile>(getConfigPath(), {}, (document) => {
        const config = yamlToConfigFile(document);
        mutator(config);
        return configFileToYaml(config);
    });
}

//
// The configuration a reader falls back to when there is no file. Re-exported so callers that only
// deal with the file do not have to reach into the format module for it.
//
export { defaultConfigFile };
