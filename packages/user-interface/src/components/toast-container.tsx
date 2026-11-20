import React, { useEffect } from "react";
import Box from "@mui/material/Box";
import Button from "@mui/material/Button";
import IconButton from "@mui/material/IconButton";
import SnackbarContent from "@mui/material/SnackbarContent";
import Close from "@mui/icons-material/Close";
import { useToast, type IToast } from "../context/toast-context";
import { useIsMobile } from "../lib/use-is-mobile";

//
// The kind of toast the style guide draws: plain for a message with no status, or the status it
// reports. The theme styles each status kind through its photosphere-toast-<kind> class.
//
export type ToastKind = "plain" | "info" | "success" | "warning" | "error";

//
// Picks the style guide's toast kind for a toast's colour, so each toast keeps the meaning its
// sender chose: a neutral toast is plain, a primary one is information and a danger one is an error.
//
export function toastKind(toastColor: IToast["color"]): ToastKind {
    if (toastColor === 'success') {
        return 'success';
    }

    if (toastColor === 'warning') {
        return 'warning';
    }

    if (toastColor === 'danger') {
        return 'error';
    }

    if (toastColor === 'primary') {
        return 'info';
    }

    return 'plain';
}

//
// The Font Awesome icon each status kind shows before its message, as the style guide's toasts do.
//
const STATUS_ICON_CLASSES: Record<Exclude<ToastKind, "plain">, string> = {
    info: "fa-circle-info",
    success: "fa-circle-check",
    warning: "fa-triangle-exclamation",
    error: "fa-circle-exclamation",
};

//
// Individual toast notification item.
//
function ToastItem({ toast }: { toast: IToast }) {
    const { removeToast } = useToast();
    const kind = toastKind(toast.color);

    useEffect(() => {
        if (toast.duration > 0) {
            const timer = setTimeout(() => {
                removeToast(toast.id);
            }, toast.duration);
            return () => clearTimeout(timer);
        }
    }, [toast.id, toast.duration, removeToast]);

    return (
        <SnackbarContent
            className={kind === "plain" ? "photosphere-toast-arrive" : `photosphere-toast-arrive photosphere-toast-${kind}`}
            role={kind === "error" || kind === "warning" ? "alert" : "status"}
            sx={{
                flexWrap: 'nowrap',
                pointerEvents: 'auto',
            }}
            action={
                <>
                    {toast.action && (
                        <Button
                            data-id="toast-action"
                            size="small"
                            variant="outlined"
                            onClick={() => {
                                toast.action!.onClick();
                                removeToast(toast.id);
                            }}
                        >
                            {toast.action.label}
                        </Button>
                    )}
                    <IconButton
                        size="small"
                        title="Dismiss"
                        className="photosphere-toast-close"
                        data-id="toast-dismiss"
                        onClick={() => {
                            if (toast.onDismiss) {
                                toast.onDismiss();
                            }
                            removeToast(toast.id);
                        }}
                    >
                        <Close
                            sx={{
                                fontSize: 'calc(var(--toast-close-size) / 2)',
                            }}
                            />
                    </IconButton>
                </>
            }
            message={
                <Box
                    sx={{
                        display: 'flex',
                        alignItems: 'flex-start',
                        gap: 'var(--space-2)',
                    }}
                    >
                    {kind !== "plain"
                        && <Box
                            component="i"
                            aria-hidden={true}
                            className={`fa-solid ${STATUS_ICON_CLASSES[kind]} photosphere-toast-icon`}
                            sx={{
                                flex: 'none',
                                fontSize: 'var(--icon-md)',
                                lineHeight: 'var(--leading-normal)',
                            }}
                            />
                    }
                    <div>
                        <div data-id="toast-message">{toast.message}</div>
                        {toast.link && (
                            <Box
                                component="a"
                                data-id="toast-link"
                                href={toast.link.url}
                                target="_blank"
                                rel="noopener noreferrer"
                                sx={{
                                    display: 'inline-block',
                                    marginTop: 'var(--space-1)',
                                    color: 'inherit',
                                    textDecoration: 'underline',
                                }}
                            >
                                {toast.link.label}
                            </Box>
                        )}
                    </div>
                </Box>
            }
        />
    );
}

//
// Container that renders all active toast notifications, stacked where the style guide's toast
// stack tokens place them: centred at the foot of the screen, and across its width on a mobile.
//
export function ToastContainer() {
    const { toasts } = useToast();
    const isMobile = useIsMobile();

    if (toasts.length === 0) {
        return null;
    }

    return (
        <Box
            sx={{
                position: 'fixed',
                top: 'var(--toast-stack-top)',
                bottom: 'calc(var(--toast-stack-bottom) + env(safe-area-inset-bottom))',
                left: 'var(--space-4)',
                right: 'var(--space-4)',
                zIndex: 9999,
                display: 'flex',
                flexDirection: 'column',
                alignItems: 'var(--toast-stack-align)',
                gap: 'var(--space-2)',
                pointerEvents: 'none',
            }}
        >
            {toasts.map(toast => (
                <Box
                    key={toast.id}
                    sx={{
                        width: isMobile ? '100%' : 'auto',
                        maxWidth: 'calc(var(--space-8) * 16)',
                    }}
                    >
                    <ToastItem toast={toast} />
                </Box>
            ))}
        </Box>
    );
}
