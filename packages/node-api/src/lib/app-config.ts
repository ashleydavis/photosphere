//
// The config store the shared UI reads and writes through, backed by config.yaml.
//
// `IConfig` in user-interface offers get, set, add, remove and clear over a string key, and this is
// what backs it: the settings the user chose. What the app remembered is the sibling store in
// app-state.ts, reached through its own context, so nothing anywhere has to work out which of the two
// a key belongs to.
//
// What the keys mean is not decided here. app-config-format.ts owns that, and is where the flat view
// and its conversions live, so the phone's worker can be handed the same definition without dragging
// the filesystem in with it. This module is the file half: loading it, and changing it. Everything
// there is re-exported from here so a caller that wants both does not have to know they are two
// modules.
//

import { readYaml, updateYaml } from "node-utils";
import { getConfigPath } from "./config-file";
import { yamlToAppConfig, appConfigToYaml, type IAppConfig } from "./app-config-format";
import type { IConfigTheme, IYamlConfigFile } from "./config-format";

export * from "./app-config-format";

//
// Loads the whole store from disk.
// Returns an empty config when the file does not exist, so every setting falls to its own default.
//
export async function loadAppConfig(): Promise<IAppConfig> {
    const document = await readYaml<IYamlConfigFile>(getConfigPath());
    return yamlToAppConfig(document);
}

//
// Changes the store on disk. Every edit goes through here.
//
// The mutator is handed the file's CURRENT contents and changes them in place. updateYaml runs it
// under the update lock beside the file, checks the file has not moved before renaming, and re-runs
// the mutator against the new contents if it has, so two edits arriving together both survive.
//
// This is the only way to write the file. A saveDesktopConfig that took a whole config and wrote it
// used to sit beside this, and its callers were all load-then-save, so an edit made between their
// read and their write was silently discarded. Windows made the same overlap visible on the sibling
// databases.toml, where it refuses to rename over a file another handle still holds.
//
export async function updateAppConfig(mutator: (config: IAppConfig) => void): Promise<void> {
    await updateYaml<IYamlConfigFile>(getConfigPath(), {}, (document) => {
        const config = yamlToAppConfig(document);
        mutator(config);
        return appConfigToYaml(config, document);
    });
}

//
// Gets the theme preference.
//
export async function getTheme(): Promise<IConfigTheme> {
    const config = await loadAppConfig();
    return config.theme || 'system';
}

//
// Sets the theme preference.
//
export async function setTheme(theme: IConfigTheme): Promise<void> {
    await updateAppConfig(config => {
        config.theme = theme;
    });
}
