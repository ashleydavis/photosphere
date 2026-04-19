import React, { useState } from 'react';
import Modal from '@mui/joy/Modal';
import ModalDialog from '@mui/joy/ModalDialog';
import DialogTitle from '@mui/joy/DialogTitle';
import DialogContent from '@mui/joy/DialogContent';
import DialogActions from '@mui/joy/DialogActions';
import Button from '@mui/joy/Button';
import Input from '@mui/joy/Input';
import Box from '@mui/joy/Box';
import Typography from '@mui/joy/Typography';
import FormControl from '@mui/joy/FormControl';
import FormLabel from '@mui/joy/FormLabel';
import List from '@mui/joy/List';
import ListItem from '@mui/joy/ListItem';
import ListItemButton from '@mui/joy/ListItemButton';
import { usePlatform } from '../context/platform-context';

export interface IS3BrowserModalProps {
    // Whether the modal is visible.
    open: boolean;

    // Id of the shared secret entry holding S3 credentials.
    credentialId: string;

    // Called when the modal should close without a selection.
    onClose: () => void;

    // Called with the selected S3 path string (format: "s3:bucket:/prefix").
    onSelect: (path: string) => void;
}

//
// Modal for browsing an S3 bucket and selecting a directory path.
//
export function S3BrowserModal({ open, credentialId, onClose, onSelect }: IS3BrowserModalProps) {
    const platform = usePlatform();

    // Current bucket name entered by the user.
    const [bucket, setBucket] = useState('');

    // Current navigation prefix (directory path within the bucket).
    const [prefix, setPrefix] = useState('');

    // Directory names listed under the current bucket/prefix.
    const [entries, setEntries] = useState<string[]>([]);

    // Error message to show when a listing fails.
    const [listError, setListError] = useState<string | undefined>(undefined);

    //
    // Loads the directory listing for the current bucket and prefix.
    //
    async function loadListing(targetBucket: string, targetPrefix: string): Promise<void> {
        setListError(undefined);
        setEntries([]);
        const dirs = await platform.listS3Dirs(credentialId, targetBucket, targetPrefix);
        setEntries(dirs);
    }

    //
    // Handles bucket input changes: reset prefix and load listing.
    //
    function handleBucketChange(newBucket: string): void {
        setBucket(newBucket);
        setPrefix('');
        setEntries([]);
        if (newBucket) {
            loadListing(newBucket, '').catch(err => {
                setListError(String(err));
            });
        }
    }

    //
    // Navigates into a sub-directory entry.
    //
    function handleNavigate(dirName: string): void {
        const newPrefix = prefix ? `${prefix}${dirName}/` : `${dirName}/`;
        setPrefix(newPrefix);
        loadListing(bucket, newPrefix).catch(err => {
            setListError(String(err));
        });
    }

    //
    // Navigates up to a breadcrumb segment.
    //
    function handleBreadcrumb(segmentIndex: number): void {
        const segments = prefix.split('/').filter(segment => segment.length > 0);
        const newPrefix = segments.slice(0, segmentIndex + 1).join('/') + '/';
        setPrefix(newPrefix);
        loadListing(bucket, newPrefix).catch(err => {
            setListError(String(err));
        });
    }

    //
    // Navigates to the bucket root.
    //
    function handleGoRoot(): void {
        setPrefix('');
        loadListing(bucket, '').catch(err => {
            setListError(String(err));
        });
    }

    //
    // Builds and returns the selected S3 path string.
    //
    function handleSelectLocation(): void {
        const selectedPath = `s3:${bucket}:/${prefix}`;
        onSelect(selectedPath);
    }

    //
    // Renders the breadcrumb trail for the current prefix.
    //
    function renderBreadcrumbs(): React.ReactNode {
        const segments = prefix.split('/').filter(segment => segment.length > 0);
        return (
            <Box sx={{ display: 'flex', flexWrap: 'wrap', gap: 0.5, mb: 1 }}>
                <Button size="sm" variant="plain" onClick={handleGoRoot}>
                    {bucket || 'root'}
                </Button>
                {segments.map((segment, index) => (
                    <React.Fragment key={index}>
                        <Typography level="body-sm" sx={{ alignSelf: 'center' }}>/</Typography>
                        <Button size="sm" variant="plain" onClick={() => handleBreadcrumb(index)}>
                            {segment}
                        </Button>
                    </React.Fragment>
                ))}
            </Box>
        );
    }

    return (
        <Modal open={open} onClose={onClose}>
            <ModalDialog sx={{ minWidth: 520, maxWidth: 740, overflowY: 'auto' }}>
                <DialogTitle>Browse S3</DialogTitle>
                <DialogContent>
                    <FormControl sx={{ mb: 2 }}>
                        <FormLabel>Bucket</FormLabel>
                        <Input
                            value={bucket}
                            onChange={event => handleBucketChange(event.target.value)}
                            placeholder="my-bucket-name"
                        />
                    </FormControl>

                    {bucket && renderBreadcrumbs()}

                    {listError && (
                        <Typography level="body-sm" color="danger" sx={{ mb: 1 }}>
                            {listError}
                        </Typography>
                    )}

                    {entries.length > 0 && (
                        <List size="sm" sx={{ maxHeight: 300, overflowY: 'auto' }}>
                            {entries.map(dirName => (
                                <ListItem key={dirName}>
                                    <ListItemButton onClick={() => handleNavigate(dirName)}>
                                        {dirName}/
                                    </ListItemButton>
                                </ListItem>
                            ))}
                        </List>
                    )}

                    {bucket && entries.length === 0 && !listError && (
                        <Typography level="body-sm" sx={{ mt: 1 }}>
                            No sub-directories found here.
                        </Typography>
                    )}
                </DialogContent>
                <DialogActions>
                    <Button variant="plain" onClick={onClose}>Cancel</Button>
                    <Button
                        disabled={!bucket}
                        onClick={handleSelectLocation}
                    >
                        Select this location
                    </Button>
                </DialogActions>
            </ModalDialog>
        </Modal>
    );
}
