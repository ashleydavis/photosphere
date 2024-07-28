import React, { useState } from 'react';
import Button from '@mui/joy/Button';
import Modal from '@mui/joy/Modal';
import Typography from '@mui/joy/Typography';
import ModalDialog from '@mui/joy/ModalDialog';

export interface IProps {
    //
    // Set to true to display the dialog.
    //
    open: boolean;

    //
    // The number of items to be deleted.
    //
    numItems: number;

    //
    // Event raised to cancel the delete operation.
    //
    onCancel: () => void;

    //
    // Event raised to confirm the delete operation.
    //
    onDelete: () => Promise<void>;
}

export function DeleteConfirmationDialog({ open, numItems, onCancel, onDelete }: IProps) {
    
    const [working, setWorking] = useState(false);

    return (
        <Modal 
            open={open} 
            onClose={onCancel}
            >
            <ModalDialog>
                <Typography component="h2">
                    Delete Confirmation
                </Typography>
                <Typography>
                    Are you sure you want to delete {numItems} assets? This cannot be undone.
                </Typography>
                <div className="flex flex-row w-full">
                    <Button variant="plain" onClick={onCancel}>
                        Cancel
                    </Button>
                    <div className="flex-grow" />
                    <Button 
                        variant="solid" 
                        color="danger" 
                        onClick={async () => {
                            setWorking(true);
                            try {
                                await onDelete();
                            }
                            finally {
                                setWorking(false);
                            }
                        }}
                        >
                        Delete
                    </Button>
                </div>
            </ModalDialog>
        </Modal>
    );
}
