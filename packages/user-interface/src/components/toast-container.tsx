import React, { useEffect } from "react";
import Alert from "@mui/joy/Alert";
import Button from "@mui/joy/Button";
import IconButton from "@mui/joy/IconButton";
import Close from "@mui/icons-material/Close";
import { useToast, type IToast } from "../context/toast-context";

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
            color={toast.color}
            variant="solid"
            sx={{ mb: 1, minWidth: 300, maxWidth: 480, boxShadow: 'lg' }}
            endDecorator={
                <div style={{ display: 'flex', gap: '8px', alignItems: 'center', flexShrink: 0 }}>
                    {toast.action && (
                        <Button
                            size="sm"
                            variant="soft"
                            color={toast.color}
                            onClick={toast.action.onClick}
                        >
                            {toast.action.label}
                        </Button>
                    )}
                    <IconButton
                        size="sm"
                        variant="plain"
                        color={toast.color}
                        title="Dismiss"
                        onClick={() => removeToast(toast.id)}
                    >
                        <Close />
                    </IconButton>
                </div>
            }
        >
            {toast.message}
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
                right: '16px',
                zIndex: 9999,
                display: 'flex',
                flexDirection: 'column',
                alignItems: 'flex-end',
            }}
        >
            {toasts.map(toast => (
                <ToastItem key={toast.id} toast={toast} />
            ))}
        </div>
    );
}
