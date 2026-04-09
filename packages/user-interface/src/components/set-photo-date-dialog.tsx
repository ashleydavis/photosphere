import React, { useState, useEffect } from "react";
import dayjs from "dayjs";
import Modal from "@mui/joy/Modal";
import ModalDialog from "@mui/joy/ModalDialog";
import DialogTitle from "@mui/joy/DialogTitle";
import DialogContent from "@mui/joy/DialogContent";
import DialogActions from "@mui/joy/DialogActions";
import Select from "@mui/joy/Select";
import Option from "@mui/joy/Option";
import Input from "@mui/joy/Input";
import Button from "@mui/joy/Button";

//
// The mode for setting a photo date.
//
type DateMode = "specific" | "year" | "month" | "decade" | "clear";

//
// Short month names for the month select.
//
const MONTH_NAMES = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
];

//
// Decades available in the decade select (1900s–2020s).
//
const DECADES = [
    1900, 1910, 1920, 1930, 1940, 1950,
    1960, 1970, 1980, 1990, 2000, 2010, 2020,
];

//
// Props for the SetPhotoDateDialog component.
//
export interface ISetPhotoDateDialogProps {

    //
    // Whether the dialog is open.
    //
    open: boolean;

    //
    // Called when the dialog should close without making changes.
    //
    onClose: () => void;

    //
    // Called with the chosen ISO date string, or undefined to clear the date.
    //
    onSetDate: (date: string | undefined) => Promise<void>;

    //
    // The current photoDate value, used to pre-fill inputs.
    //
    currentDate?: string;
}

//
// A dialog for setting or clearing the photo date on one or more assets.
// Supports specific date, year-only, month+year, decade, or clearing the date.
//
export function SetPhotoDateDialog({ open, onClose, onSetDate, currentDate }: ISetPhotoDateDialogProps) {

    const [dateMode, setDateMode] = useState<DateMode>("specific");

    // Specific date state (YYYY-MM-DD string for <input type="date">)
    const [specificDate, setSpecificDate] = useState<string>("");

    // Year state
    const [year, setYear] = useState<string>(String(dayjs().year()));

    // Month state (1–12)
    const [month, setMonth] = useState<number>(1);

    // Month year state
    const [monthYear, setMonthYear] = useState<string>(String(dayjs().year()));

    // Decade state (e.g. 2020)
    const [decade, setDecade] = useState<number>(2020);

    //
    // Reset state whenever the dialog opens or currentDate changes.
    //
    useEffect(() => {
        if (!open) {
            return;
        }
        const parsed = currentDate ? dayjs(currentDate) : undefined;
        setDateMode("specific");
        setSpecificDate(parsed ? parsed.format("YYYY-MM-DD") : "");
        setYear(parsed ? String(parsed.year()) : String(dayjs().year()));
        setMonth(parsed ? parsed.month() + 1 : 1);
        setMonthYear(parsed ? String(parsed.year()) : String(dayjs().year()));
        setDecade(parsed ? Math.floor(parsed.year() / 10) * 10 : 2020);
    }, [open, currentDate]);

    //
    // Computes whether the Set Date button should be disabled.
    //
    function isConfirmDisabled(): boolean {
        if (dateMode === "clear") {
            return false;
        }
        if (dateMode === "specific") {
            return !specificDate;
        }
        if (dateMode === "year") {
            const parsed = parseInt(year, 10);
            return isNaN(parsed) || parsed < 1000 || parsed > 9999;
        }
        if (dateMode === "month") {
            const parsed = parseInt(monthYear, 10);
            return isNaN(parsed) || parsed < 1000 || parsed > 9999;
        }
        return false;
    }

    //
    // Builds the ISO date string from the current mode and inputs.
    //
    function buildDate(): string | undefined {
        if (dateMode === "clear") {
            return undefined;
        }
        if (dateMode === "specific") {
            return dayjs(specificDate).toISOString();
        }
        if (dateMode === "year") {
            return dayjs(`${year}-01-01`).toISOString();
        }
        if (dateMode === "month") {
            const paddedMonth = String(month).padStart(2, "0");
            return dayjs(`${monthYear}-${paddedMonth}-01`).toISOString();
        }
        if (dateMode === "decade") {
            return dayjs(`${decade}-01-01`).toISOString();
        }
        return undefined;
    }

    //
    // Handles the confirm button click.
    //
    async function handleConfirm(): Promise<void> {
        const date = buildDate();
        await onSetDate(date);
    }

    return (
        <Modal open={open} onClose={onClose}>
            <ModalDialog sx={{ width: 340, overflow: "hidden" }}>
                <DialogTitle>Set Photo Date</DialogTitle>
                <DialogContent sx={{ overflow: "visible", pb: 1 }}>
                    <Select
                        size="sm"
                        value={dateMode}
                        onChange={(_event, value) => setDateMode(value as DateMode)}
                        sx={{ mt: 1, width: "100%" }}
                    >
                        <Option value="specific">Specific date</Option>
                        <Option value="year">Year</Option>
                        <Option value="month">Month</Option>
                        <Option value="decade">Decade</Option>
                        <Option value="clear">Clear date (undated)</Option>
                    </Select>

                    <div style={{ minHeight: 40, marginTop: 16 }}>
                        {dateMode === "specific" && (
                            <input
                                type="date"
                                value={specificDate}
                                onChange={event => setSpecificDate(event.target.value)}
                                style={{ width: "100%", padding: "4px 8px", boxSizing: "border-box" }}
                            />
                        )}
                        {dateMode === "year" && (
                            <Input
                                size="sm"
                                type="number"
                                value={year}
                                onChange={event => setYear(event.target.value)}
                                slotProps={{ input: { min: 1000, max: 9999 } }}
                                placeholder="e.g. 2023"
                                sx={{ width: "100%" }}
                            />
                        )}
                        {dateMode === "month" && (
                            <div style={{ display: "flex", gap: 8 }}>
                                <Select
                                    size="sm"
                                    value={month}
                                    onChange={(_event, value) => setMonth(value as number)}
                                    sx={{ flex: 1 }}
                                >
                                    {MONTH_NAMES.map((name, index) => (
                                        <Option key={name} value={index + 1}>{name}</Option>
                                    ))}
                                </Select>
                                <Input
                                    size="sm"
                                    type="number"
                                    value={monthYear}
                                    onChange={event => setMonthYear(event.target.value)}
                                    slotProps={{ input: { min: 1000, max: 9999 } }}
                                    placeholder="Year"
                                    sx={{ width: 90 }}
                                />
                            </div>
                        )}
                        {dateMode === "decade" && (
                            <Select
                                size="sm"
                                value={decade}
                                onChange={(_event, value) => setDecade(value as number)}
                                sx={{ width: "100%" }}
                            >
                                {DECADES.map(decadeValue => (
                                    <Option key={decadeValue} value={decadeValue}>{decadeValue}s</Option>
                                ))}
                            </Select>
                        )}
                    </div>
                </DialogContent>
                <DialogActions>
                    <Button variant="plain" color="neutral" onClick={onClose}>
                        Cancel
                    </Button>
                    <Button
                        variant="solid"
                        color="primary"
                        disabled={isConfirmDisabled()}
                        onClick={handleConfirm}
                    >
                        Set Date
                    </Button>
                </DialogActions>
            </ModalDialog>
        </Modal>
    );
}
