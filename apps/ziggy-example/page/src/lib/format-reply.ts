//
// The reply the example's ping channel gives.
//
export interface IPingReply {
    // The Zig version the core was built with.
    zigVersion: string;

    // The operating system the core was built for.
    os: string;

    // The CPU architecture the core was built for.
    arch: string;

    // What the page sent, echoed back.
    echo: { greeting: string };
}

//
// Formats the ping reply for display in the page.
//
export function formatPingReply(reply: IPingReply): string {
    return `Zig ${reply.zigVersion} on ${reply.os} ${reply.arch} says: ${reply.echo.greeting}`;
}
