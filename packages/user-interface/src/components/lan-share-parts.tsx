//
// The parts the share and receive dialogs for databases and secrets, and the view-secret dialog,
// are drawn from, so each flow looks the same: the row of step dots under the title, the step
// that slides in, the pulsing rings while one device looks for the other, the pairing code in
// tiles, the check drawn when a share or receive is done and the rows of read-only details.
//

import React, { useRef, type ReactNode } from 'react';
import Box from '@mui/material/Box';
import Check from '@mui/icons-material/Check';
import type { SxProps, Theme } from '@mui/material/styles';

//
// Props for StepDots.
//
export interface IStepDotsProps {
    //
    // The position of the step on screen, counted from 0.
    //
    index: number;

    //
    // How many steps the dialog has.
    //
    count: number;
}

//
// Renders one dot per step of a dialog, the current one drawn longer in the accent colour, so the
// user can see how far through the flow they are. It sits at the top of the dialog's content,
// just under the title.
//
export function StepDots({ index, count }: IStepDotsProps) {
    const dots: ReactNode[] = [];
    for (let dotIndex = 0; dotIndex < count; dotIndex += 1) {
        let width = 'var(--space-2)';
        let color = 'var(--dialog-step-dot-color)';
        if (dotIndex === index) {
            width = 'var(--space-6)';
            color = 'var(--dialog-step-dot-current-color)';
        }
        dots.push(
            <Box
                key={dotIndex}
                component="span"
                sx={{
                    width,
                    height: 'var(--space-2)',
                    borderRadius: 'var(--radius-full)',
                    backgroundColor: color,
                    transition: 'width var(--dialog-step-duration) var(--ease-standard)',
                }}
                />
        );
    }
    return (
        <Box
            aria-hidden={true}
            sx={{
                display: 'flex',
                gap: 'var(--space-1)',
                marginBottom: 'var(--space-4)',
            }}
            >
            {dots}
        </Box>
    );
}

//
// The step a dialog last showed and which way it slid in, kept by useStepForward.
//
interface IStepPlace {
    //
    // The name of the step.
    //
    step: string;

    //
    // Its position among the dialog's steps, counted from 0.
    //
    stepIndex: number;

    //
    // True when it slid in from the right.
    //
    forward: boolean;
}

//
// Returns whether the step `step`, at `stepIndex`, slides in from the right: true when it comes
// after the step shown before it, or is the first step, and false when the user went back. The
// answer is kept until the step changes, so a re-render of the same step does not change its
// class and replay its slide.
//
export function useStepForward(step: string, stepIndex: number): boolean {
    const last = useRef<IStepPlace>({
        step,
        stepIndex,
        forward: true,
    });
    if (last.current.step !== step) {
        let forward = true;
        if (stepIndex > 0 && stepIndex < last.current.stepIndex) {
            forward = false;
        }
        last.current = {
            step,
            stepIndex,
            forward,
        };
    }
    return last.current.forward;
}

//
// Props for StepTransition.
//
export interface IStepTransitionProps {
    //
    // The name of the step shown. A new name starts the slide again.
    //
    step: string;

    //
    // True when the step comes after the last one, so it slides in from the right, and false when
    // the user went back, so it slides in from the left.
    //
    forward: boolean;

    //
    // The step's content.
    //
    children: ReactNode;
}

//
// Renders a dialog's step so it fades in and slides in by --dialog-step-shift from the side it
// comes from, as the dialog rules ask. Keyed on the step, so each step change replays it.
//
export function StepTransition({ step, forward, children }: IStepTransitionProps) {
    let className = 'photosphere-dialog-step-in-back';
    if (forward) {
        className = 'photosphere-dialog-step-in-forward';
    }
    return (
        <Box
            key={step}
            className={className}
            sx={{
                display: 'flex',
                flexDirection: 'column',
                gap: 'var(--space-4)',
            }}
            >
            {children}
        </Box>
    );
}

//
// Props for PulsingSearch.
//
export interface IPulsingSearchProps {
    //
    // The icon in the disc at the centre of the rings.
    //
    icon: ReactNode;

    //
    // The words under the rings, saying what the device waits for.
    //
    message: string;
}

//
// Renders `icon` in a disc of the brand gradient with three rings pulsing out from it, over
// `message`, while a device looks for the other on the network.
//
export function PulsingSearch({ icon, message }: IPulsingSearchProps) {
    const rings: ReactNode[] = [];
    for (let ringIndex = 0; ringIndex < 3; ringIndex += 1) {
        rings.push(
            <Box
                key={ringIndex}
                component="span"
                aria-hidden={true}
                className="photosphere-dialog-ring"
                sx={{
                    position: 'absolute',
                    inset: 0,
                    borderRadius: 'var(--radius-full)',
                    border: '2px solid var(--color-accent)',
                    '--photosphere-dialog-delay': `calc(var(--duration-slow) * ${ringIndex * 2})`,
                }}
                />
        );
    }
    return (
        <Box
            sx={{
                display: 'flex',
                flexDirection: 'column',
                alignItems: 'center',
                gap: 'var(--space-4)',
                padding: 'var(--space-6) 0 var(--space-4)',
            }}
            >
            <Box
                sx={{
                    position: 'relative',
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    width: 'calc(var(--space-8) * 4)',
                    height: 'calc(var(--space-8) * 4)',
                }}
                >
                {rings}
                <Box
                    component="span"
                    aria-hidden={true}
                    sx={{
                        position: 'relative',
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        width: 'calc(var(--space-8) * 2)',
                        height: 'calc(var(--space-8) * 2)',
                        borderRadius: 'var(--radius-full)',
                        background: 'var(--empty-icon-bg)',
                        color: 'var(--color-empty-icon)',
                        boxShadow: 'var(--shadow-overlay)',
                        '& .MuiSvgIcon-root': {
                            fontSize: 'var(--text-2xl)',
                        },
                    }}
                    >
                    {icon}
                </Box>
            </Box>
            <Box
                component="span"
                role="status"
                sx={{
                    color: 'var(--color-text-muted)',
                    textAlign: 'center',
                }}
                >
                {message}
            </Box>
        </Box>
    );
}

//
// Props for PairingCodeTiles.
//
export interface IPairingCodeTilesProps {
    //
    // The pairing code the sender shows.
    //
    code: string;

    //
    // The data-id the smoke tests read the code from. The tiles hold nothing but the digits, so
    // the element's text is the code itself.
    //
    dataId: string;
}

//
// Renders the pairing code large in the mono font, each digit in its own tinted tile, so it reads
// aloud digit by digit, as the dialog rules ask.
//
export function PairingCodeTiles({ code, dataId }: IPairingCodeTilesProps) {
    return (
        <Box
            data-id={dataId}
            className="photosphere-dialog-pop"
            sx={{
                display: 'flex',
                justifyContent: 'center',
                gap: 'var(--pairing-digit-gap)',
            }}
            >
            {code.split('').map((digit, digitIndex) => (
                <Box
                    key={digitIndex}
                    component="span"
                    className="photosphere-dialog-pop"
                    sx={{
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        width: 'var(--pairing-digit-width)',
                        height: 'calc(var(--space-8) * 2 + var(--space-4))',
                        fontFamily: 'var(--font-mono)',
                        fontSize: 'calc(var(--text-2xl) * 1.5)',
                        fontWeight: 'var(--weight-bold)',
                        color: 'var(--pairing-digit-color)',
                        backgroundColor: 'var(--pairing-digit-bg)',
                        border: '1px solid var(--pairing-digit-border-color)',
                        borderRadius: 'var(--radius-md)',
                        '--photosphere-dialog-delay': `calc(var(--duration-fast) * ${digitIndex})`,
                    }}
                    >
                    {digit}
                </Box>
            ))}
        </Box>
    );
}

//
// The look of the box the receiver types the pairing code into: the digits large in the mono font,
// spaced out and centred, as the style guide's digit boxes draw them. The receive-database and
// receive-secret dialogs both take it, so the two code boxes match.
//
export const PAIRING_CODE_INPUT_SX: SxProps<Theme> = {
    alignSelf: 'center',
    width: 'calc(var(--space-8) * 6)',
    maxWidth: '100%',
    marginTop: 'var(--space-2)',
    '& input': {
        textAlign: 'center',
        fontFamily: 'var(--font-mono)',
        fontSize: 'var(--text-2xl)',
        fontWeight: 'var(--weight-bold)',
        letterSpacing: 'var(--space-3)',
        paddingLeft: 'var(--space-3)',
    },
};

//
// Props for SuccessCheck.
//
export interface ISuccessCheckProps {
    //
    // The data-id the smoke tests find the finished step by, or undefined when they do not look
    // for it.
    //
    dataId: string | undefined;

    //
    // The sentence saying what was done.
    //
    children: ReactNode;
}

//
// Renders a check that draws itself in a disc of the success colour over the sentence saying a
// share or a receive is done.
//
export function SuccessCheck({ dataId, children }: ISuccessCheckProps) {
    return (
        <Box
            role="status"
            sx={{
                display: 'flex',
                flexDirection: 'column',
                alignItems: 'center',
                gap: 'var(--space-3)',
                padding: 'var(--space-6) 0 var(--space-4)',
                textAlign: 'center',
            }}
            >
            <Box
                component="span"
                aria-hidden={true}
                className="photosphere-dialog-pop"
                sx={{
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    width: 'calc(var(--space-8) * 2 + var(--space-4))',
                    height: 'calc(var(--space-8) * 2 + var(--space-4))',
                    borderRadius: 'var(--radius-full)',
                    color: 'var(--color-success)',
                    backgroundColor: 'color-mix(in srgb, var(--color-success) 14%, transparent)',
                    border: '2px solid var(--color-success)',
                    '& .MuiSvgIcon-root': {
                        fontSize: 'var(--text-2xl)',
                    },
                }}
                >
                <Check className="photosphere-dialog-check" />
            </Box>
            <Box
                data-id={dataId}
                component="span"
                sx={{
                    fontSize: 'var(--text-lg)',
                    fontWeight: 'var(--weight-bold)',
                }}
                >
                {children}
            </Box>
        </Box>
    );
}

//
// One read-only detail of a database or a secret.
//
export interface IDetail {
    //
    // What the detail is, shown muted at the row's left.
    //
    label: string;

    //
    // Its value, shown at the row's right.
    //
    value: ReactNode;

    //
    // The data-id the smoke tests read the row's text by, or undefined when they do not read it.
    //
    dataId: string | undefined;
}

//
// Props for DetailRows.
//
export interface IDetailRowsProps {
    //
    // The details shown, one row each, in order.
    //
    details: IDetail[];
}

//
// Renders `details` as rows of a label and its value in a card, the way the settings sections
// group them. A space sits between label and value, so a row's text reads "Name: value" to the
// smoke tests while the flex layout spreads them to the row's ends.
//
export function DetailRows({ details }: IDetailRowsProps) {
    return (
        <Box
            sx={{
                display: 'flex',
                flexDirection: 'column',
                overflow: 'hidden',
                backgroundColor: 'var(--color-settings-section-bg)',
                border: '1px solid var(--color-settings-section-border)',
                borderRadius: 'var(--radius-settings-section)',
            }}
            >
            {details.map((detail, detailIndex) => {
                let borderTop = 'var(--settings-row-divider-width) solid var(--color-border)';
                if (detailIndex === 0) {
                    borderTop = 'none';
                }
                return (
                    <Box
                        key={detail.label}
                        data-id={detail.dataId}
                        sx={{
                            display: 'flex',
                            flexWrap: 'wrap',
                            alignItems: 'baseline',
                            justifyContent: 'space-between',
                            columnGap: 'var(--space-4)',
                            rowGap: 'var(--space-1)',
                            padding: 'var(--space-3)',
                            borderTop,
                        }}
                        >
                        <Box
                            component="span"
                            sx={{
                                color: 'var(--color-text-muted)',
                                fontSize: 'var(--text-sm)',
                            }}
                            >
                            {detail.label}
                        </Box>
                        {' '}
                        <Box
                            component="span"
                            sx={{
                                minWidth: 0,
                                textAlign: 'right',
                                overflowWrap: 'anywhere',
                            }}
                            >
                            {detail.value}
                        </Box>
                    </Box>
                );
            })}
        </Box>
    );
}
