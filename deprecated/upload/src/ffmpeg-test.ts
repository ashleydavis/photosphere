//
// Testbed for experimenting with ffmpeg.
//
// Use it like this:
//
//    npx ts-node srec/ffmpeg-test.ts
//

import { getVideoScreenshot } from "./lib/video";

async function main() {
    const videoPath = "z:\\photos\\Photo Library\\Surrey Bike Ride.wmv";

    const screenshot = getVideoScreenshot(videoPath, 10);
    console.log(screenshot);
}

main()
    .catch(err => {
        console.error(`Failed with error:`);
        console.error(err);
        process.exit(1);
    });

