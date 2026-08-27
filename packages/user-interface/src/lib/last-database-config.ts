//
// The config key naming the database to open again next time the app starts.
//
// Defined here rather than written as a string at each of its three uses (the app writes it when a
// database is opened, clears it when one is closed, and reads it on startup) so a platform that
// keeps it somewhere of its own can recognise it. Mobile does: local storage belongs to the WebView
// and is flushed to disk whenever the WebView gets round to it, which is not before Android kills
// the app, so mobile routes this key to a file instead.
//
export const LAST_DATABASE_KEY = "lastDatabase";
