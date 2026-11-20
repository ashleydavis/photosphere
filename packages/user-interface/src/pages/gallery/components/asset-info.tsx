import React, { useCallback, useEffect } from "react";
import dayjs from "dayjs";
import { useGalleryItem } from "../../../context/gallery-item-context";
import _ from "lodash";
import { TextField, IconButton, Button, Chip, Typography, Box } from "@mui/material";
import { Flag, FlagOutlined, Star, StarBorder } from "@mui/icons-material";
import { useGallery } from "../../../context/gallery-context";
import { SetPhotoDateDialog } from "../../../components/set-photo-date-dialog";
import { SetLocationDialog } from "../../../components/set-location-dialog";
import { dedupeLabels } from "../../../lib/labels";

export interface IAssetInfoProps { 

    //
    // Event raised when the modal is closed.
    //
    onClose: () => void;

    //
    // Event raised when the asset has been deleted.
    //
    onDeleted: () => void;

    //
    // Event raised when the user clicks a label to search for it.
    //
    onLabelSearch: () => void;
}

//
// The style of the Star or Flag button while it is on: the accent fill with the icon in the colour
// that pairs with it, since the viewer's starred and flagged colours are paired only with the
// glass of a control over a photo, not with the panel.
//
const PRESSED_BUTTON_SX = {
    color: "var(--color-on-accent)",
    backgroundColor: "var(--color-accent)",
    borderColor: "var(--color-accent)",
    "&:hover": {
        color: "var(--color-on-accent)",
        backgroundColor: "var(--color-accent)",
    },
};

//
// Shows info for a particular asset.
//
export function AssetInfo({ onClose, onDeleted, onLabelSearch }: IAssetInfoProps) {

    //
    // Interface to the gallery item.
    //
    const { asset, updateAsset, addArrayValue, removeArrayValue, deleteAsset } = useGalleryItem();
    const { search } = useGallery();

    const [description, setDescription] = React.useState(asset?.description);

    //
    // The description this panel last took from the asset, so a change coming from storage can be told
    // apart from the user's own typing.
    //
    const assetDescriptionRef = React.useRef(asset?.description);

    //
    // Shows the asset's description when it changes underneath the panel.
    //
    // Without this the field was seeded once at mount and never looked at the asset again. The only
    // thing that remounted it was a change of asset id (the `key` on this component), so a panel
    // opened before the asset had finished loading showed an empty description for an asset that had
    // one, permanently. That is not only a wrong reading: the field is what the next edit is built
    // from, so typing into it would have written the blank over the real value.
    //
    // Keyed on the asset's own description rather than on the asset object, so the user's typing is
    // not thrown away by an unrelated re-render. While typing, local state runs ahead of the asset for
    // the length of the 500ms debounce and this does not fire; when the write lands the two agree and
    // setting it again changes nothing.
    //
    React.useEffect(() => {
        if (asset?.description !== assetDescriptionRef.current) {
            assetDescriptionRef.current = asset?.description;
            setDescription(asset?.description);
        }
    }, [asset?.description]);

    //
    // Controls visibility of the set date dialog.
    //
    const [editingDate, setEditingDate] = React.useState(false);

    //
    // Controls visibility of the set location dialog.
    //
    const [editingLocation, setEditingLocation] = React.useState(false);

    //
    // Controls visibility of the inline add-label input.
    //
    const [addingLabel, setAddingLabel] = React.useState(false);

    //
    // The text currently typed into the add-label input.
    //
    const [newLabelName, setNewLabelName] = React.useState("");

    //
    // Confirms the new label and adds it to the asset.
    //
    async function onConfirmLabel(): Promise<void> {
        const trimmed = newLabelName.trim();
        if (trimmed) {
            await addArrayValue("labels", trimmed);
        }
        setNewLabelName("");
        setAddingLabel(false);
    }
    
	//
    // Removes a label from the asset.
    //
    async function onRemoveLabel(labelName: string): Promise<void> {
        await removeArrayValue("labels", labelName);
    }

    //
    // Marks the asset as deleted.
    //
    async function onDeleteItem(): Promise<void> {
        await deleteAsset();
        onDeleted();
    }

    // 
    // Debounce the update to prevent too many updates.
    //
    const debouncedUpdateDescription = useCallback(_.debounce((description: string) => {
        updateAsset({ description });
    }, 500), []);

    //
    // Flushes the debounced description update on unmount.
    //
    useEffect(() => {
        return () => {
            debouncedUpdateDescription.flush();
        };
    }, []);
        
    //
    // Event raised when the user has updated the assets description.
    //
    async function onUpdateDescription(description: string): Promise<void> {
        setDescription(description);
        debouncedUpdateDescription(description);
    }

    //
    // Renders a label.
    //
    function renderLabel(name: string) {
        return (
            <Chip
                key={name}
                variant="outlined"
                size="small"
                label={name}
                onClick={() => {
                    search(`.labels="${name}"`);
                    onLabelSearch();
                }}
                sx={{ cursor: "pointer" }}
                onDelete={() => {
                    onRemoveLabel(name);
                }}
                deleteIcon={<i className="fa-solid fa-close" title="Remove label" />}
                />
        );
    }

    if (!asset) {
        return null; // Waiting for asset to be loaded.
    }

    const isStarred = asset.labels?.includes("starred");
    const isFlagged = asset.labels?.includes("flagged");

    return (
        <Box
            className="photosphere-asset-info flex flex-col"
            sx={{
                gap: "var(--space-4)",
                padding: "var(--space-4)",
                bgcolor: "var(--color-details-panel-bg)",
                color: "var(--color-text)",
            }}
            >
            <div
                className="flex items-center"
                style={{
                    gap: "var(--space-2)",
                }}
                >
                <Typography
                    component="h4"
                    className="flex-1"
                    sx={{
                        margin: 0,
                        fontSize: "var(--text-lg)",
                        fontWeight: "var(--weight-bold)",
                    }}
                    >
                    Detail
                </Typography>

                <IconButton
                    title={isStarred ? "Unstar" : "Star"}
                    sx={isStarred ? PRESSED_BUTTON_SX : undefined}
                    onClick={async () => {
                        if (isStarred) {
                            await removeArrayValue("labels", "starred");
                        }
                        else {
                            await addArrayValue("labels", "starred");
                        }
                    }}
                    >
                    {isStarred
                        ? <Star fontSize="inherit" />
                        : <StarBorder fontSize="inherit" />
                    }
                </IconButton>

                <IconButton
                    title={isFlagged ? "Unflag" : "Flag"}
                    sx={isFlagged ? PRESSED_BUTTON_SX : undefined}
                    onClick={async () => {
                        if (isFlagged) {
                            await removeArrayValue("labels", "flagged");
                        }
                        else {
                            await addArrayValue("labels", "flagged");
                        }
                    }}
                    >
                    {isFlagged
                        ? <Flag fontSize="inherit" />
                        : <FlagOutlined fontSize="inherit" />
                    }
                </IconButton>

                <IconButton
                    title="Close"
                    onClick={() => {
                        onClose();
                    }}
                    >
                    <i className="fa-solid fa-close" />
                </IconButton>
            </div>

            <TextField
                data-id="asset-description-input"
                fullWidth
                multiline
                minRows={2}
                size="small"
                placeholder="Add a description"
                value={description}
                onChange={event => onUpdateDescription(event.target.value)}
                />

            <DetailRow label="Asset id" icon="fa-solid fa-calendar-day">
                <span
                    data-testid="asset-id"
                    className="break-all"
                    style={{
                        fontFamily: "var(--font-mono)",
                        fontSize: "var(--text-sm)",
                    }}
                    >
                    {asset._id}
                </span>
            </DetailRow>

            <DetailRow label="Asset hash" icon="fa-solid fa-calendar-day">
                <span
                    className="break-all"
                    style={{
                        fontFamily: "var(--font-mono)",
                        fontSize: "var(--text-sm)",
                    }}
                    >
                    {asset.hash}
                </span>
            </DetailRow>

            <DetailRow label={undefined} icon="fa-solid fa-tags">
                <span
                    className="flex flex-row flex-wrap items-center"
                    style={{
                        gap: "var(--space-2)",
                    }}
                    >
                    {dedupeLabels(asset.labels || []).map(label => {
                        return renderLabel(label);
                    })}

                    {addingLabel
                        ? <TextField
                            autoFocus
                            size="small"
                            placeholder="Label name"
                            value={newLabelName}
                            onChange={event => setNewLabelName(event.target.value)}
                            onKeyDown={async event => {
                                if (event.key === "Enter") {
                                    await onConfirmLabel();
                                }
                                else if (event.key === "Escape") {
                                    setNewLabelName("");
                                    setAddingLabel(false);
                                }
                            }}
                            onBlur={onConfirmLabel}
                            />
                        : <IconButton
                            title="Add label"
                            onClick={() => setAddingLabel(true)}
                            >
                            <i className="fa-solid fa-square-plus" />
                        </IconButton>
                    }
                </span>
            </DetailRow>

            <DetailRow label={undefined} icon="fa-solid fa-calendar-day">
                <span
                    className="flex items-center"
                    style={{
                        gap: "var(--space-2)",
                    }}
                    >
                    <span className="flex min-w-0 flex-1 flex-col">
                        <span>
                            {asset.photoDate ? dayjs(asset.photoDate).format("MMM D, YYYY") : "No date" }
                        </span>
                        <span
                            style={{
                                color: "var(--color-text-muted)",
                                fontSize: "var(--text-sm)",
                            }}
                            >
                            {asset.photoDate ? dayjs(asset.photoDate).format("HH:mm") : "No time" }
                        </span>
                    </span>
                    <IconButton
                        size="small"
                        title="Edit date"
                        onClick={() => setEditingDate(true)}
                        >
                        <i className="fa-solid fa-pen" />
                    </IconButton>
                </span>
            </DetailRow>

            <SetPhotoDateDialog
                open={editingDate}
                onClose={() => setEditingDate(false)}
                currentDate={asset.photoDate}
                onSetDate={async (date) => {
                    await updateAsset({ photoDate: date });
                    setEditingDate(false);
                }}
                />

            <DetailRow label={undefined} icon="fa-regular fa-map">
                <span
                    className="flex items-center"
                    style={{
                        gap: "var(--space-2)",
                    }}
                    >
                    <span className="flex min-w-0 flex-1 flex-col">
                        <span>
                            {asset.location ?? "No location"}
                        </span>
                        {asset.coordinates && (
                            <span
                                style={{
                                    color: "var(--color-text-muted)",
                                    fontSize: "var(--text-sm)",
                                }}
                                >
                                {asset.coordinates.lat.toFixed(6)}, {asset.coordinates.lng.toFixed(6)}
                            </span>
                        )}
                    </span>
                    <IconButton
                        size="small"
                        title="Edit location"
                        onClick={() => setEditingLocation(true)}
                        >
                        <i className="fa-solid fa-pen" />
                    </IconButton>
                </span>
            </DetailRow>

            <SetLocationDialog
                open={editingLocation}
                initialCoordinates={asset.coordinates}
                onSetLocation={async (coordinates, location) => {
                    await updateAsset({ coordinates, location });
                    setEditingLocation(false);
                }}
                onClearLocation={async () => {
                    await updateAsset({ coordinates: undefined, location: undefined });
                    setEditingLocation(false);
                }}
                onClose={() => setEditingLocation(false)}
            />

            <DetailRow label={undefined} icon="fa-regular fa-image">
                <span className="break-all">
                    {asset.origPath} {asset.origFileName}
                </span>
                <span
                    style={{
                        color: "var(--color-text-muted)",
                        fontSize: "var(--text-sm)",
                    }}
                    >
                    {asset.width} × {asset.height}
                </span>
            </DetailRow>

            <div
                className="flex justify-end max-md:justify-stretch"
                style={{
                    paddingTop: "var(--space-2)",
                    borderTop: "1px solid var(--color-border)",
                }}
                >
                <Button
                    variant="outlined"
                    color="error"
                    className="max-md:flex-1"
                    startIcon={<i className="fa-solid fa-trash" />}
                    onClick={onDeleteItem}
                    >
                    Delete
                </Button>
            </div>
        </Box>
    );
}

//
// Props for one fact row of the details panel.
//
interface IDetailRowProps {
    //
    // The muted caption above the fact, such as "Asset id", or undefined for a fact whose value
    // says what it is, such as the date.
    //
    label: string | undefined;

    //
    // The Font Awesome classes of the icon drawn in front of the value.
    //
    icon: string;

    //
    // The value of the fact, stacked in a column when there is more than one part.
    //
    children: React.ReactNode;
}

//
// Renders one fact of the details panel as the style guide's photo details lay it out: a muted
// caption, then the icon in front of the value, with the columns and the visibility of the caption
// and icon set by the --details-* tokens.
//
function DetailRow({ label, icon, children }: IDetailRowProps) {
    return (
        <div
            className="grid items-baseline"
            style={{
                gridTemplateColumns: "var(--details-columns)",
                columnGap: "var(--space-3)",
                rowGap: "var(--space-1)",
            }}
            >
            {label !== undefined && (
                <span
                    style={{
                        display: "var(--details-label-display)",
                        color: "var(--color-text-muted)",
                        fontSize: "var(--text-sm)",
                    }}
                    >
                    {label}
                </span>
            )}
            <span
                className="flex items-baseline"
                style={{
                    gap: "var(--space-2)",
                }}
                >
                <i
                    className={icon}
                    style={{
                        display: "var(--details-icon-display)",
                        color: "var(--color-text-muted)",
                        fontSize: "var(--icon-md)",
                        width: "var(--icon-md)",
                        flex: "none",
                        textAlign: "center",
                    }}
                    />
                <span
                    className="flex min-w-0 flex-1 flex-col"
                    style={{
                        gap: "var(--space-1)",
                    }}
                    >
                    {children}
                </span>
            </span>
        </div>
    );
}
