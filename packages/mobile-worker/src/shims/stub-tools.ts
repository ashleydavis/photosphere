//
// Build-time stub for the `tools` package in the mobile worker bundle.
//
// `media-file-database` and the node-api image/video helpers import `Image`, `Video`, and
// `getFileInfo` from `tools`, which shell out to ImageMagick/ffmpeg via `child_process`. The
// load-assets read path imports these modules but never constructs or calls them (it only iterates
// already-stored metadata). This stub satisfies the imports; any real use throws the loud
// NOT IMPLEMENTED error. Native media tools on mobile are a later layer.
//

//
// Builds the NOT IMPLEMENTED error for a media-tool use.
//
function notImplemented(name: string): Error {
    return new Error(`NOT IMPLEMENTED: media tool ("${name}") is not available in the mobile worker. Implement it ASAP.`);
}

//
// Stub image tool. Constructing it throws because ImageMagick is unavailable in the engine.
//
export class Image {
    //
    // Throws on construction: image tooling is not available in the mobile worker.
    //
    constructor() {
        throw notImplemented("Image");
    }
}

//
// Stub video tool. Constructing it throws because ffmpeg is unavailable in the engine.
//
export class Video {
    //
    // Throws on construction: video tooling is not available in the mobile worker.
    //
    constructor() {
        throw notImplemented("Video");
    }
}

//
// Stub file-info probe; using it throws because it relies on native media tools.
//
export function getFileInfo(): never {
    throw notImplemented("getFileInfo");
}
