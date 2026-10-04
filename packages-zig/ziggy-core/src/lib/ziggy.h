// The C interface to the Ziggy core. Every shell includes this one declaration.

#ifndef ZIGGY_H
#define ZIGGY_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Delivers a JSON message from the core to the shell. The message is valid only while the call runs, so the shell
// copies it before returning. It may be called from any thread, so the shell moves to its UI thread before touching
// the web view.
typedef void (*ziggy_deliver_fn)(void *user_data, const char *message, size_t message_len);

// Native host callback: writes the operating system's version, as a JSON string, into the buffer the core gives it, and
// returns the number of bytes written, or a negative number when it cannot answer.
typedef intptr_t (*ziggy_os_version_fn)(void *user_data, char *buffer, size_t capacity);

// Native host callback: asks the shell to quit the application. Called only by the test control connection.
typedef void (*ziggy_quit_fn)(void *user_data);

// Native host callback: does a menu action as if the user had chosen its menu item, by the path the menu item takes in the shell,
// so the shell's own actions (reload, zoom, developer tools, full screen, the editing commands, quit) really happen and any
// other action reaches the page. The core calls it, from the thread of the test control connection, only to let a test choose a
// menu item. The shell does the work on its UI thread and returns at once.
typedef void (*ziggy_menu_action_fn)(void *user_data, const char *action);

// What a shell is asked to show in ziggy_pick_paths_fn.
enum {
    // A dialog to choose one or more existing files to open.
    ZIGGY_PICK_OPEN_FILES = 0,
    // A dialog to choose where to save a file, with a suggested name.
    ZIGGY_PICK_SAVE_FILE = 1,
    // A dialog to choose a folder.
    ZIGGY_PICK_FOLDER = 2
};

// Native host callback: shows a native file or folder dialog, waits for the user, and writes what they chose into the buffer
// the core gives it, as a JSON array of path strings ("[]" when they cancelled). Returns the number of bytes written, or a
// negative number on failure. The title is NUL terminated and may be NULL. The initial name is NUL terminated and may be NULL,
// and is used only to save. The core calls it from a worker thread, never from the one that handles page messages, so the
// shell shows the dialog on its UI thread and waits.
typedef intptr_t (*ziggy_pick_paths_fn)(void *user_data, int32_t kind, const char *title, const char *initial_name, char *buffer, size_t capacity);

// What the shell passes to ziggy_create. Every pointer is copied by the core, so it need only be valid during the call.
typedef struct ziggy_config {
    // The shell's own pointer, passed back on every callback.
    void *user_data;
    // Delivers a message to the page. Required.
    ziggy_deliver_fn deliver;
    // Native host callback: the operating system's version. NULL when the platform has none.
    ziggy_os_version_fn os_version;
    // Native host callback: quit the application. NULL when the platform has none.
    ziggy_quit_fn quit;
    // Native host callback: show a native file or folder dialog. NULL when the platform has none.
    ziggy_pick_paths_fn pick_paths;
    // Native host callback: do a menu action as if its menu item had been chosen. NULL on a platform with no menu. Used only by
    // the test control connection.
    ziggy_menu_action_fn menu_action;
    // The number of worker threads.
    uint32_t worker_threads;
    // The limit on child tasks in flight for any one parent task.
    uint32_t max_concurrent_child_tasks;
    // The URL prefix of the app's own bundled page, such as "file:///path/to/dist/" (NUL terminated).
    const char *app_url_prefix;
    // The app's private data directory (NUL terminated).
    const char *data_dir;
    // Non-zero to start the test control connection. Used only in a test hooks build.
    bool test_mode;
    // The file the test control connection writes its port to, or NULL for none. Used only in a test hooks build.
    const char *test_port_file;
} ziggy_config;

// The result of ziggy_check_url.
enum {
    // The address is the app's own page.
    ZIGGY_URL_ALLOW = 0,
    // The address is an external link, to open in the system browser.
    ZIGGY_URL_OPEN_EXTERNALLY = 1,
    // The address must not be loaded.
    ZIGGY_URL_BLOCK = 2
};

// Creates a core and returns its handle, or NULL on failure (the reason is printed to standard error).
void *ziggy_create(const ziggy_config *config);

// Cancels every running task, waits for the workers to stop and releases everything. No task runs and nothing is
// delivered after it returns.
void ziggy_destroy(void *handle);

// Delivers a JSON message from the page to the core. The message is valid only while the call runs.
void ziggy_post_message(void *handle, const char *message, size_t message_len);

// Decides what to do with an address the web view is about to load: a ZIGGY_URL_ value.
int32_t ziggy_check_url(void *handle, const char *url, size_t url_len);

// The modifier bits of a parsed keyboard shortcut.
enum {
    ZIGGY_MOD_CTRL = 1,
    ZIGGY_MOD_SHIFT = 2,
    ZIGGY_MOD_ALT = 4,
    // Command on MacOS, and the Windows or Super key elsewhere.
    ZIGGY_MOD_META = 8
};

// A keyboard shortcut, parsed.
typedef struct ziggy_accelerator {
    // Which modifier keys are held, as a mix of the ZIGGY_MOD_ bits.
    uint32_t modifiers;
    // The key's name, NUL terminated: a lower case letter or digit, a function key name such as "f12", or a name such as
    // "plus", "minus", "equal", "space", "enter", "tab", "escape", "up", "down", "left", "right", "home", "end", "pageup",
    // "pagedown", "delete" or "backspace".
    char key[16];
} ziggy_accelerator;

// Returns the desktop menu as JSON text, valid until ziggy_destroy: an array of menus, each {"label", "items"}, where an item
// is {"label", "action", "accelerator"} or {"separator": true} and may hold its own "items" for a submenu. Desktop shells
// show it, and a phone's shell never calls this. The length is written to the pointer given.
const char *ziggy_menu_json(void *handle, size_t *length);

// Reads keyboard shortcut text such as "CmdOrCtrl+Shift+I" into the struct given. CmdOrCtrl becomes Command on MacOS and
// Control elsewhere. Returns false, leaving the struct unchanged, when the text is not a shortcut.
bool ziggy_parse_accelerator(const char *text, size_t text_len, ziggy_accelerator *result);

// Returns true when the library was built with the test hooks.
bool ziggy_test_hooks_enabled(void);

#ifdef __cplusplus
}
#endif

#endif
