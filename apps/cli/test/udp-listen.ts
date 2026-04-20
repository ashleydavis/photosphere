import { createSocket } from "dgram";

//
// Listens for a single UDP broadcast on port 54321, prints it to stdout, and exits.
// Used by smoke tests to capture the receiver's PSIE_RECV broadcast.
//
const DISCOVERY_PORT = 54321;
const socket = createSocket({ type: "udp4", reuseAddr: true });

socket.on("message", (message) => {
    const text = message.toString("utf-8");
    if (text.startsWith("PSIE_RECV:")) {
        console.log(text);
        socket.close();
        process.exit(0);
    }
});

socket.bind(DISCOVERY_PORT);
