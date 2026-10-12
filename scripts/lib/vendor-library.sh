#!/usr/bin/env bash
# Shared by the update-*.sh scripts that take a library's upstream source into vendor/. See vendor-library.md.

# Prints a message to stderr.
vendor_log() {
    printf '[vendor] %s\n' "$1" >&2
}

# Fetches a source tarball and unpacks it into vendor/<name>, leaving out the paths given as extra arguments (each is
# relative to the tarball's top directory). The tarball is never edited or patched. When vendor/<name> already holds a
# copy, it is moved to vendor/<name>.previous (which must not exist) and not deleted, so the new copy can be compared
# with it; the human deletes it.
#   $1 repository root, $2 name, $3 url, $4 version, then the paths to leave out.
vendor_library() {
    local repo_root="$1"
    local name="$2"
    local url="$3"
    local version="$4"
    shift 4

    local vendor_dir="$repo_root/vendor"
    local destination="$vendor_dir/$name"
    local work_dir="$repo_root/tmp/vendor-$name"
    local next="$destination.next"
    mkdir -p "$vendor_dir" "$work_dir"

    if [ -e "$destination.previous" ]; then
        vendor_log "$destination.previous already exists. Delete it (it is the copy from the update before this one) and run this again."
        return 1
    fi
    if [ -e "$next" ]; then
        vendor_log "$next already exists from an update that did not finish. Delete it and run this again."
        return 1
    fi

    vendor_log "Downloading $url"
    curl -fsSL --retry 3 -o "$work_dir/$name.tarball" "$url"

    # GNU tar matches an exclude against the member's name in the archive, which starts with the top directory.
    local top
    top="$(tar -tf "$work_dir/$name.tarball" | sed -n 1p)"
    top="${top%%/*}"
    local excludes=()
    local excluded
    for excluded in "$@"; do
        excludes+=("--exclude=$top/$excluded")
    done

    mkdir -p "$next"
    tar -xf "$work_dir/$name.tarball" -C "$next" --strip-components=1 "${excludes[@]}"
    printf '%s\n%s\n' "$version" "$url" > "$next/VENDORED_VERSION"

    if [ -e "$destination" ]; then
        mv "$destination" "$destination.previous"
        vendor_log "The copy that was in $destination is now $destination.previous. Compare it, then delete it."
    fi
    mv "$next" "$destination"
    vendor_log "Vendored $name $version into $destination"
}
