#!/usr/bin/env bash

# Cuts a splash recording to start at the first frame in which the app's splash fills the screen, so the video does not show what
# was on the screen before the app opened. See cut-to-splash.md. record-splash.sh sources it for its Android recordings, and it can
# be run on its own to cut a recording, such as the iOS one, which macOS's ffmpeg crashed cutting.

set -euo pipefail

# Fails naming the command when it is not installed.
require() {
    if ! command -v "$1" > /dev/null 2>&1; then
        echo "ERROR: $(basename "$0") needs $1, which is not on PATH." >&2
        exit 1
    fi
}

# Prints the average colours of five areas of each frame of a video, one line of fifteen values per frame (the red, green and blue
# of each area in turn). Each area is read by an ffmpeg of its own, as macOS's ffmpeg crashed on one filter graph that read them
# all, and in a time base fine enough to keep every frame apart, so ffmpeg writes each frame once. Fails, naming the counts, when
# the areas do not all have the same number of frames. The values are put three to a line by xargs, as macOS's od has no -w.
# Usage: area_colours <video> <area> <area> <area> <area> <area>, each as ffmpeg's crop filter takes it
area_colours() {
    local video="$1"
    shift
    local files=()
    local counts=""
    local area
    local file
    for area in "$@"; do
        file="$(mktemp)"
        ffmpeg -v error -i "$video" -vf "crop=$area,scale=1:1:flags=area" -fps_mode passthrough -enc_time_base 1/90000 -f rawvideo \
            -pix_fmt rgb24 - | od -An -v -tu1 | xargs -n 3 > "$file"
        files+=("$file")
        counts="$counts $(wc -l < "$file" | tr -d ' ')"
    done
    if [ "$(printf '%s\n' $counts | sort -u | wc -l)" -ne 1 ]; then
        echo "ERROR: the areas of $video have different numbers of frames:$counts" >&2
        rm -f "${files[@]}"
        exit 1
    fi
    paste -d ' ' "${files[@]}"
    rm -f "${files[@]}"
}

# Writes the video from the first frame in which the app's splash fills the screen, so the recording does not show what was on the
# screen before the app opened (the launcher on Android and the home screen on iOS, which show around the app's window as it
# opens). That frame is the first in which five areas all have the splash colour from icons/assets.json: bands across the screen
# near its top and its bottom, the two pixel columns at its left and right edges from below the status bar to above the
# navigation bar, where the opening window's rounded corners show last, and the middle of two pixel rows near its top, which the
# caller gives: the top edge on Android, and on iOS a tenth of the way down, below its status bar and camera cut-out, which are
# not in the splash colour. The art in the middle reaches none of them. Fails when no frame has it.
# Usage: trim_to_splash <video> <output> <the rows near the top, as ffmpeg's crop filter takes them>
trim_to_splash() {
    require ffmpeg
    require jq
    local colour
    colour="$(jq -r '.background' "$(dirname "${BASH_SOURCE[0]}")/../icons/assets.json")"
    local want_red=$((16#${colour:1:2}))
    local want_green=$((16#${colour:3:2}))
    local want_blue=$((16#${colour:5:2}))
    local frame=0
    local first=""
    local line
    local values
    # The areas' colours, one line per frame, are written out first, so a recording with no splash frame can show what it had.
    local areas
    areas="$(mktemp)"
    area_colours "$1" "iw:ih/6:0:ih/10" "iw:ih/6:0:ih*3/4" "2:ih*9/10:0:ih/20" "2:ih*9/10:iw-2:ih/20" "$3" > "$areas"
    while read -r line; do
        read -r -a values <<< "$line"
        local matches=true
        local index
        for index in 0 3 6 9 12; do
            if ! near "${values[index]}" "$want_red" || ! near "${values[index + 1]}" "$want_green" \
                || ! near "${values[index + 2]}" "$want_blue"; then
                matches=false
                break
            fi
        done
        if [ "$matches" = true ]; then
            first=$frame
            break
        fi
        frame=$((frame + 1))
    done < "$areas"
    if [ -z "$first" ]; then
        echo "ERROR: no frame of the recording shows the splash colour $colour ($want_red $want_green $want_blue) in all five areas." >&2
        echo "The recording's $(wc -l < "$areas") frames, every tenth, with the red, green and blue of the band near the top, the" \
            "band near the bottom, the left edge, the right edge and the rows near the top:" >&2
        sed -n '1~10p' "$areas" >&2
        rm -f "$areas"
        exit 1
    fi
    rm -f "$areas"
    # Each frame keeps its own time: screenrecord writes a frame only when the screen changes, and at a constant frame rate ffmpeg
    # dropped frames from a fade and repeated others.
    ffmpeg -loglevel error -y -i "$1" -vf "select=gte(n\,$first),setpts=PTS-STARTPTS" -fps_mode passthrough -enc_time_base demux \
        -video_track_timescale 90000 -c:v libx264 -pix_fmt yuv420p "$2"
}

# Succeeds when two colour channel values are within 6 of each other, which the video's compression keeps the splash colour within
# and the opening window's last frames, still blending the launcher in at its edges, are not. Usage: near <value> <value>
near() {
    local difference=$(($1 - $2))
    [ "${difference#-}" -le 6 ]
}

# Run as a script, it cuts the video it is given; sourced, it only defines trim_to_splash.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if [ $# -ne 3 ]; then
        echo "Usage: cut-to-splash.sh <video> <output> <the rows near the top, as ffmpeg's crop filter takes them>" >&2
        exit 2
    fi
    mkdir -p "$(dirname "$2")"
    trim_to_splash "$1" "$2" "$3"
fi
