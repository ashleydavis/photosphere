import React, { Component, ReactNode, useEffect, useMemo, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { CssVarsProvider } from "@mui/joy/styles/CssVarsProvider";
import { log } from "utils";
import { stories } from "./index";
import type { IStory, StoryCategory } from "./types";

//
// Order in which categories are rendered as headers in the list.
//
const CATEGORY_ORDER: StoryCategory[] = ["Pages", "Modals", "Dialogs", "Components"];

//
// Top-level stories browser page. Provides a two-pane layout: a sidebar with
// a search input and category-grouped story list, and a right pane that
// renders the selected story.
//
// The page is intentionally mounted outside the regular provider stack so
// each story owns and controls the providers it needs.
//
export function StoriesPage(): JSX.Element {
    const [searchParams] = useSearchParams();

    //
    // Cycle mode is enabled by the smoke test via ?cycle=1. It renders a
    // dedicated component that walks the entire story registry instead of
    // the normal two-pane layout.
    //
    if (searchParams.get("cycle") === "1") {
        const durationParam = searchParams.get("duration");
        const parsedDuration = durationParam ? parseInt(durationParam, 10) : NaN;
        const durationMs = Number.isFinite(parsedDuration) && parsedDuration > 0 ? parsedDuration : 1000;
        return (
            <CssVarsProvider>
                <StoriesCycle stories={stories} durationMs={durationMs} />
            </CssVarsProvider>
        );
    }

    return (
        <CssVarsProvider>
            <StoriesBrowser />
        </CssVarsProvider>
    );
}

//
// The interactive two-pane browser shown when cycle mode is not enabled.
//
function StoriesBrowser(): JSX.Element {
    const [searchParams, setSearchParams] = useSearchParams();
    const [searchText, setSearchText] = useState<string>("");

    const selectedId = searchParams.get("id") || undefined;
    const selectedStory = selectedId
        ? stories.find(story => story.id === selectedId)
        : undefined;

    //
    // Filter stories by case-insensitive substring match against id, name,
    // and category. The currently selected story stays visible even when it
    // does not match the filter.
    //
    const filteredStories = useMemo(() => {
        const needle = searchText.trim().toLowerCase();
        if (!needle) {
            return stories;
        }
        return stories.filter(story =>
            story.id.toLowerCase().includes(needle)
                || story.name.toLowerCase().includes(needle)
                || story.category.toLowerCase().includes(needle)
        );
    }, [searchText]);

    //
    // Group stories by category for rendering under category headers.
    //
    const grouped = useMemo(() => {
        const result: { [category: string]: IStory[] } = {};
        for (const category of CATEGORY_ORDER) {
            result[category] = [];
        }
        for (const story of filteredStories) {
            if (!result[story.category]) {
                result[story.category] = [];
            }
            result[story.category].push(story);
        }
        return result;
    }, [filteredStories]);

    //
    // Click handler that updates the URL query so individual stories are linkable.
    //
    function selectStory(story: IStory): void {
        setSearchParams({ id: story.id });
    }

    return (
        <div className="flex h-screen w-screen" style={{ background: "var(--joy-palette-background-body)", color: "var(--joy-palette-text-primary)" }}>
            <aside
                className="flex flex-col border-r"
                style={{ width: "280px", borderColor: "var(--joy-palette-divider, #ddd)" }}
                >
                <div className="p-3 flex flex-col gap-2 border-b" style={{ borderColor: "var(--joy-palette-divider, #ddd)" }}>
                    <input
                        type="text"
                        value={searchText}
                        onChange={event => setSearchText(event.target.value)}
                        placeholder="Filter stories"
                        className="px-2 py-1 rounded border w-full"
                        style={{ borderColor: "var(--joy-palette-divider, #ddd)", background: "transparent", color: "inherit" }}
                        data-testid="stories-search-input"
                        />
                    <Link to="/" className="text-sm underline" data-testid="stories-back-link">
                        Back to app
                    </Link>
                </div>

                <div className="flex-1 overflow-auto p-2">
                    {CATEGORY_ORDER.map(category => {
                        const items = grouped[category] || [];
                        if (items.length === 0) {
                            return null;
                        }
                        return (
                            <div key={category} className="mb-3">
                                <h3 className="text-xs uppercase font-semibold mb-1 opacity-70">{category}</h3>
                                <ul className="flex flex-col">
                                    {items.map(story => {
                                        const isActive = selectedId === story.id;
                                        return (
                                            <li key={story.id}>
                                                <button
                                                    type="button"
                                                    onClick={() => selectStory(story)}
                                                    className="text-left px-2 py-1 w-full rounded"
                                                    style={{
                                                        background: isActive ? "var(--joy-palette-primary-softBg, #e3f2fd)" : "transparent",
                                                        color: isActive ? "var(--joy-palette-primary-plainColor, #0a6cd1)" : "inherit",
                                                    }}
                                                    data-testid={`stories-list-item-${story.id}`}
                                                    >
                                                    {story.name}
                                                </button>
                                            </li>
                                        );
                                    })}
                                </ul>
                            </div>
                        );
                    })}
                </div>
            </aside>

            <main className="flex-1 overflow-auto">
                {!selectedId
                    && <div className="p-6 opacity-70">Select a story</div>
                }
                {selectedId && !selectedStory
                    && <div className="p-6 opacity-70" data-testid="stories-unknown-story">{`Unknown story: ${selectedId}`}</div>
                }
                {selectedStory
                    && <div key={selectedStory.id} className="h-full w-full" data-testid={`stories-render-${selectedStory.id}`}>
                        {selectedStory.render()}
                    </div>
                }
            </main>
        </div>
    );
}

//
// Props for the StoriesCycle component.
//
interface IStoriesCycleProps {
    //
    // The full list of stories to walk through.
    //
    stories: IStory[];

    //
    // Number of milliseconds to dwell on each story before advancing.
    //
    durationMs: number;
}

//
// Renders each story in sequence, dwelling on each for `durationMs`,
// emitting log lines that the cycle smoke test reads to detect crashes.
//
function StoriesCycle({ stories: cycleStories, durationMs }: IStoriesCycleProps): JSX.Element {
    const [index, setIndex] = useState<number>(0);
    const [results, setResults] = useState<{ pass: number; fail: number }>({ pass: 0, fail: 0 });

    //
    // Emit the start banner once on first mount.
    //
    useEffect(() => {
        log.event(`STORIES CYCLE START: ${cycleStories.length} stories, ${durationMs}ms each`);
    // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    //
    // Per-story lifecycle: emit a READY event after a short settle so external
    // tools (the cycle smoke test) can capture a screenshot, then advance after
    // either the dwell timer expires or a `cycle-advance` window event fires.
    // The window-level error listeners capture async errors that the React
    // error boundary cannot see; they are removed before advancing so the next
    // story has a clean slate.
    //
    useEffect(() => {
        if (index >= cycleStories.length) {
            return;
        }

        const current = cycleStories[index];
        let asyncError: Error | undefined = undefined;
        let advanced = false;

        const onError = (event: ErrorEvent): void => {
            asyncError = event.error || new Error(event.message);
        };
        const onRejection = (event: PromiseRejectionEvent): void => {
            const reason = event.reason;
            if (reason instanceof Error) {
                asyncError = reason;
            }
            else {
                asyncError = new Error(typeof reason === "string" ? reason : String(reason));
            }
        };

        function advance(): void {
            if (advanced) {
                return;
            }
            advanced = true;
            window.removeEventListener("error", onError);
            window.removeEventListener("unhandledrejection", onRejection);
            window.removeEventListener("cycle-advance", advance);
            clearTimeout(readyTimer);
            clearTimeout(dwellTimer);

            const boundaryError = boundaryErrors.get(current.id);
            const error = boundaryError || asyncError;

            if (error) {
                log.event(`STORIES CYCLE FAILED: ${current.id}: ${error.message}`);
                setResults(prev => ({ pass: prev.pass, fail: prev.fail + 1 }));
            }
            else {
                log.event(`STORIES CYCLE OK: ${current.id}`);
                setResults(prev => ({ pass: prev.pass + 1, fail: prev.fail }));
            }
            boundaryErrors.delete(current.id);
            setIndex(index + 1);
        }

        window.addEventListener("error", onError);
        window.addEventListener("unhandledrejection", onRejection);
        window.addEventListener("cycle-advance", advance);

        const settleMs = Math.min(200, durationMs);
        const readyTimer = setTimeout(() => {
            log.event(`STORIES CYCLE READY: ${current.category}|${current.id}`);
        }, settleMs);

        const dwellTimer = setTimeout(advance, durationMs);

        return () => {
            window.removeEventListener("error", onError);
            window.removeEventListener("unhandledrejection", onRejection);
            window.removeEventListener("cycle-advance", advance);
            clearTimeout(readyTimer);
            clearTimeout(dwellTimer);
        };
    }, [index, cycleStories, durationMs]);

    //
    // Emit the completion banner once we have walked past the last story.
    //
    useEffect(() => {
        if (index >= cycleStories.length) {
            log.event(`STORIES CYCLE COMPLETE: ${results.pass} passed, ${results.fail} failed`);
        }
    }, [index, cycleStories.length, results]);

    if (index >= cycleStories.length) {
        return (
            <div className="p-6">
                <h2>Cycle complete</h2>
                <p>{`${results.pass} passed, ${results.fail} failed`}</p>
            </div>
        );
    }

    const current = cycleStories[index];
    return (
        <div className="h-screen w-screen">
            <div className="p-2 text-xs opacity-70">{`Cycle: ${index + 1}/${cycleStories.length} — ${current.id}`}</div>
            <StoryErrorBoundary storyId={current.id}>
                {current.render()}
            </StoryErrorBoundary>
        </div>
    );
}

//
// A side-channel that the error boundary uses to surface render errors to
// the StoriesCycle controller. The controller reads and clears entries as
// it advances; a Map keyed by story id is enough because only one story is
// mounted at a time.
//
const boundaryErrors: Map<string, Error> = new Map<string, Error>();

//
// Props for the StoryErrorBoundary class component.
//
interface IStoryErrorBoundaryProps {
    //
    // ID of the story being rendered. Used as the key under which any
    // captured error is recorded for the controller to read.
    //
    storyId: string;

    //
    // Story content the boundary wraps.
    //
    children: ReactNode | ReactNode[];
}

//
// State for the StoryErrorBoundary.
//
interface IStoryErrorBoundaryState {
    //
    // True after a render-time error has been caught for the wrapped child.
    //
    hasError: boolean;
}

//
// React class-component error boundary that captures render-time errors
// thrown by stories. Async errors (rejected promises, setTimeout throws)
// bypass error boundaries; those are caught by window-level listeners in
// StoriesCycle.
//
class StoryErrorBoundary extends Component<IStoryErrorBoundaryProps, IStoryErrorBoundaryState> {
    constructor(props: IStoryErrorBoundaryProps) {
        super(props);
        this.state = { hasError: false };
    }

    static getDerivedStateFromError(): IStoryErrorBoundaryState {
        return { hasError: true };
    }

    componentDidCatch(error: Error): void {
        boundaryErrors.set(this.props.storyId, error);
    }

    render(): ReactNode {
        if (this.state.hasError) {
            return <div className="p-4">Story crashed</div>;
        }
        return this.props.children;
    }
}

//
// onNavigate handler that responds to "navigate to /stories" without
// causing an infinite loop. Exported only for tests.
//
export { StoryErrorBoundary };
