package dev.ziggy.shell;

// What a HostRequestHandler throws when it cannot do what a host request asked. The message is the reason, in words the user can act on, and
// it is passed to the core as the failure text of the request.
public final class HostRequestException extends Exception {
    public HostRequestException(String reason) {
        super(reason);
    }

    public HostRequestException(String reason, Throwable cause) {
        super(reason, cause);
    }
}
