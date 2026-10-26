import { createSocket } from "dgram";

//
// Listens for a receiver's UDP discovery broadcast on port 54321, prints the first one that belongs
// to the expected receiver, and exits.
//
// Used by the LAN share smoke tests to capture the receiver they just started.
//
// The code hash argument is what makes this safe to run beside anything else. Discovery is a
// broadcast to the whole segment, and 54321 is a machine-wide port that every Photosphere receiver
// on it uses, so a listener that took the first PSIE_RECV it heard took whichever receiver spoke
// first: another worktree's CLI suite, or one of the mobile smoke tests' on-device receivers, which
// broadcast onto the same 192.168.55.0/24 emulator bridge the host is on. The test then attacked a
// port belonging to a receiver that was gone by the time it connected, and curl reported 000. The
// hash is in the broadcast, and each test knows the code it started its own receiver with, so
// matching on it is what makes the captured broadcast provably the right one.
//
const DISCOVERY_PORT = 54321;

// sha256 of the pairing code of the receiver whose broadcast is wanted. Required: without it this
// would be back to reporting whichever receiver on the segment happened to speak first.
const expectedCodeHash = process.argv[2];
if (!expectedCodeHash) {
    console.error("usage: udp-listen.ts <expected-code-hash>");
    console.error("The hash is the sha256 of the pairing code the receiver was started with.");
    process.exit(1);
}

const socket = createSocket({ type: "udp4", reuseAddr: true });

socket.on("message", (message) => {
    const text = message.toString("utf-8");
    if (!text.startsWith("PSIE_RECV:")) {
        return;
    }

    // "PSIE_RECV:{port}:{codeHash}:{fingerprint}". Split with a limit so a fingerprint containing a
    // colon stays in one piece, exactly as the shell callers parse it.
    const fields = text.slice("PSIE_RECV:".length).split(":");
    const codeHash = fields[1];
    if (codeHash !== expectedCodeHash) {
        // Somebody else's receiver. Keep listening for the one this test is waiting for.
        return;
    }

    console.log(text);
    socket.close();
    process.exit(0);
});

socket.bind(DISCOVERY_PORT);
