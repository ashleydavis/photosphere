//
// Reading and writing state.yaml where there is a filesystem: the CLI and the desktop app.
//
// The sibling of config-file.ts, and it works the same way. The mobile apps read and write the same
// document through worker tasks instead (state.worker.ts), because a phone's WebView has no
// filesystem of its own. Both go through state-format.ts, so the file means the same thing whichever
// wrote it.
//
// Unlike config.yaml this file is not documented for users. Nothing in it was chosen by anyone: it is
// what the app remembered so the interface comes back the way it was left.
//

import * as path from "path";
import { getConfigDir, readYaml, updateYaml } from "node-utils";
import {
    stateFileToYaml,
    yamlToStateFile,
    type IStateFile,
    type IYamlStateFile,
} from "./state-format";

//
// Returns the absolute path of the state file. PHOTOSPHERE_CONFIG_DIR moves it, along with
// config.yaml and databases.toml, which is how the smoke tests give each run its own settings and how
// two installations run side by side.
//
export function getStatePath(): string {
    return path.join(getConfigDir(), "state.yaml");
}

//
// Loads the state from disk, returning the defaults when there is no file yet.
//
export async function loadStateFile(): Promise<IStateFile> {
    const document = await readYaml<IYamlStateFile>(getStatePath());
    return yamlToStateFile(document);
}

//
// Changes the state on disk. Every edit goes through here.
//
// The mutator is handed the file's CURRENT contents and changes them in place. updateYaml runs it
// under the update lock beside the file, checks the file has not moved before renaming, and re-runs
// the mutator against the new contents if it has, so two edits arriving together both survive.
//
export async function updateStateFile(mutator: (state: IStateFile) => void): Promise<void> {
    await updateYaml<IYamlStateFile>(getStatePath(), {}, (document) => {
        const state = yamlToStateFile(document);
        mutator(state);
        return stateFileToYaml(state);
    });
}
