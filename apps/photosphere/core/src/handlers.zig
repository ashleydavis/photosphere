//
// Everything Photosphere gives Ziggy's core: its channels, task types, menu and page query (from the photosphere-core package) and its
// page.
//

const ziggy = @import("ziggy-core");
const photosphere_core = @import("photosphere-core");
const page = @import("page-files");

//
// Photosphere's channels, task types, menu and page.
//
pub const app: ziggy.core.AppHandlers = photosphere_core.handlers.appHandlers(photosphere_core.menu.menu_json, &page.files);
