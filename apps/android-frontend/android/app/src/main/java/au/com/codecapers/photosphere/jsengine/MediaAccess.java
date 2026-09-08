package au.com.codecapers.photosphere.jsengine;

//
// How much of the device photo library the app is allowed to see.
//
// Android 14 added a third answer to the photo permission, between allow and deny: the user picks
// individual photos and the app sees only those. That is not enough for automatic import, which
// exists to back the library up, so the three answers have to be told apart rather than folded into
// granted and denied.
//
public enum MediaAccess {

    //
    // Every photo and video in the library. What "Allow all" gives, and the only answer automatic
    // import can work with.
    //
    FULL,

    //
    // Only the photos and videos the user picked, on Android 14 and later.
    //
    PARTIAL,

    //
    // Nothing. Either the user refused, or they have not been asked yet.
    //
    NONE
}
