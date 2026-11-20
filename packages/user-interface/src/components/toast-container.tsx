import React, { useEffect } from "react";
import Alert, { type AlertColor } from "@mui/material/Alert";
import Button from "@mui/material/Button";
import IconButton from "@mui/material/IconButton";
import Close from "@mui/icons-material/Close";
import { useToast, type IToast } from "../context/toast-context";

//
// Picks the MUI Alert colour for a toast's colour, so each toast keeps the colour its sender chose.
// MUI's Alert has no neutral colour, so a neutral toast is drawn as info and painted grey by
// neutralToastSx.
//
export function alertColor(toastColor: IToast["color"]): AlertColor {
    if (toastColor === 'success') {
        return 'success';
    }

    if (toastColor === 'warning') {
        return 'warning';
    }

    if (toastColor === 'danger') {
        return 'error';
    }

    return 'info';
}

//
// The dark grey a neutral toast is painted, which keeps it apart from the coloured toasts.
//
const neutralToastSx = {
    backgroundColor: 'grey.800',
    color: 'common.white',
};

//
// Individual toast notification item.
//
function ToastItem({ toast }: { toast: IToast }) {
    const { removeToast } = useToast();

    useEffect(() => {
        if (toast.duration > 0) {
            const timer = setTimeout(() => {
                removeToast(toast.id);
            }, toast.duration);
            return () => clearTimeout(timer);
        }
    }, [toast.id, toast.duration, removeToast]);

    return (
        <Alert
            color={alertColor(toast.color)}
            variant="filled"
            icon={false}
            sx={{
                mb: 1,
                minWidth: 300,
                maxWidth: 480,
                boxShadow: 6,
                alignItems: 'center',
                ...(toast.color === 'neutral' ? neutralToastSx : {}),
            }}
            action={
                <div style={{ display: 'flex', gap: '8px', alignItems: 'center', flexShrink: 0 }}>
                    {toast.action && (
                        <Button
                            data-id="toast-action"
                            size="small"
                            variant="outlined"
                            color="inherit"
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
                        color="inherit"
                        title="Dismiss"
                        data-id="toast-dismiss"
                        onClick={() => {
                            if (toast.onDismiss) {
                                toast.onDismiss();
                            }
                            removeToast(toast.id);
                        }}
                    >
                        <Close />
                    </IconButton>
                </div>
            }
        >
            <div>
                <div data-id="toast-message">{toast.message}</div>
                {toast.link && (
                    <a
                        data-id="toast-link"
                        href={toast.link.url}
                        target="_blank"
                        rel="noopener noreferrer"
                        style={{ display: 'inline-block', marginTop: 4, color: 'inherit', textDecoration: 'underline' }}
                    >
                        {toast.link.label}
                    </a>
                )}
            </div>
        </Alert>
    );
}

//
// Container that renders all active toast notifications fixed to the bottom-right of the screen.
//
export function ToastContainer() {
    const { toasts } = useToast();

    if (toasts.length === 0) {
        return null;
    }

    return (
        <div
            style={{
                position: 'fixed',
                bottom: '16px',
                left: '50%',
                transform: 'translateX(-50%)',
                zIndex: 9999,
                display: 'flex',
                flexDirection: 'column',
                alignItems: 'center',
            }}
        >
            {toasts.map(toast => (
                <ToastItem key={toast.id} toast={toast} />
            ))}
        </div>
    );
}
