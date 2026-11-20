//
// The splash overlay the frontend shows over the page until the app has painted, and the options it takes.
//

//
// The options of a splash screen: the background colour, how long it stays at least, and how long its fade takes.
//
export interface ISplashOptions {
    // The CSS colour behind the images, matching the native splash.
    background: string;

    // How long the overlay stays, in milliseconds, counted from when it was installed.
    minimumDisplayMilliseconds: number;

    // How long the fade to transparent takes, in milliseconds.
    fadeDurationMilliseconds: number;

    // Called as the overlay starts to fade, with how long the fade takes in milliseconds, or with 0 when the overlay is already gone.
    // The app passes it on to window.ziggy.splashFading, so the native app fades what it covered with the splash colour (the menu
    // bar on Linux and Windows) together with the overlay.
    onFadeStart: (durationMilliseconds: number) => void;
}

//
// A splash screen that is showing.
//
export interface ISplashScreen {
    // Fades the overlay out and removes it. Resolves once it is gone.
    remove(): Promise<void>;
}

//
// The style members the splash sets.
//
export interface ISplashStyle {
    position: string;
    inset: string;
    background: string;
    zIndex: string;
    overflow: string;
    opacity: string;
    display: string;
    top: string;
    left: string;
    width: string;
    height: string;
    objectFit: string;
    objectPosition: string;
    transform: string;
    maxWidth: string;
}

//
// The element members the splash uses.
//
export interface ISplashElement {
    style: ISplashStyle;
    setAttribute(name: string, value: string): void;
    addEventListener(type: string, listener: () => void): void;
    appendChild(child: ISplashElement): void;
    remove(): void;
}

//
// The parent members the splash uses: the document body, which the overlay is added to.
//
export interface ISplashParent {
    appendChild(child: ISplashElement): void;
}

//
// The window members the splash uses.
//
export interface ISplashWindow {
    setTimeout(callback: () => void, delayMilliseconds: number): number;
    requestAnimationFrame(callback: (time: number) => void): number;
}

//

//
// The document members the splash uses.
//
export interface IDocumentLike {
    body: ISplashParent;
    defaultView: ISplashWindow;
    createElement(tagName: string): ISplashElement;
}

//
// The fade's progress, on the cubic-bezier(0.4, 0, 0.2, 1) curve: it eases into the app's UI instead of moving linearly.
//
export function fadeEasing(progress: number): number {
    let parameter = Math.min(1, Math.max(0, progress));
    for (let attempt = 0; attempt < 8; attempt += 1) {
        const difference = bezierCoordinate(parameter, 0.4, 0.2) - progress;
        if (Math.abs(difference) < 0.0001) {
            break;
        }
        const slope = bezierSlope(parameter, 0.4, 0.2);
        if (Math.abs(slope) < 0.0001) {
            break;
        }
        parameter = Math.min(1, Math.max(0, parameter - difference / slope));
    }
    return bezierCoordinate(parameter, 0, 1);
}

//
// One coordinate of a cubic bezier curve at the parameter t, for that coordinate's two control points.
//
function bezierCoordinate(t: number, firstControl: number, secondControl: number): number {
    const oneMinus = 1 - t;
    return 3 * oneMinus * oneMinus * t * firstControl + 3 * oneMinus * t * t * secondControl + t * t * t;
}

//
// The slope of that coordinate at the parameter t, which Newton's method follows to find the t for a progress.
//
function bezierSlope(t: number, firstControl: number, secondControl: number): number {
    const oneMinus = 1 - t;
    return 3 * oneMinus * oneMinus * firstControl + 6 * oneMinus * t * (secondControl - firstControl) + 3 * t * t * (1 - secondControl);
}

//
// Installs the splash overlay in the page. It is removed by remove(), or at once when its image cannot be loaded, which is
// what happens in dev mode where the core serves no splash files.
//
export function installSplashScreen(documentLike: IDocumentLike | Document, options: ISplashOptions): ISplashScreen {
    // A browser's Document is wider than IDocumentLike (its appendChild takes any Node), so TypeScript cannot check one
    // against the other and no type guard can narrow it. At runtime the members the splash uses are the same.
    const documentInterface = documentLike as IDocumentLike;
    const overlay = documentInterface.createElement("div");
    overlay.setAttribute("data-id", "ziggy-splash");
    overlay.style.position = "fixed";
    overlay.style.inset = "0";
    overlay.style.background = options.background;
    overlay.style.zIndex = "2147483647";
    overlay.style.overflow = "hidden";

    const picture = documentInterface.createElement("picture");
    const landscape = documentInterface.createElement("source");
    landscape.setAttribute("media", "(orientation: landscape)");
    landscape.setAttribute("srcset", "/ziggy-splash-landscape.png");
    const portrait = documentInterface.createElement("img");
    portrait.setAttribute("src", "/ziggy-splash-portrait.png");
    portrait.setAttribute("alt", "");
    // The image's box is the whole window, not only the page: on Android and iOS the page is kept clear of the system bars, and the
    // native app sets --ziggy-window-inset-<side> to how far the window reaches past the page on that side, so the art sits where
    // the native splash picture, which covers the whole window, has it. Elsewhere they are unset and the box is the page. The image
    // covers the box, except on Android, where the native app sets --ziggy-splash-fit to none and --ziggy-splash-scale to the
    // fixed scale its system splash draws the art at, so the image is centred at that scale instead: the box is made larger by one
    // over the scale, around the same centre, so the image is not cut at the box's edges before it is scaled down to fit them.
    const windowWidth = "(100% + var(--ziggy-window-inset-left, 0px) + var(--ziggy-window-inset-right, 0px))";
    const windowHeight = "(100% + var(--ziggy-window-inset-top, 0px) + var(--ziggy-window-inset-bottom, 0px))";
    const scale = "var(--ziggy-splash-scale, 1)";
    portrait.style.display = "block";
    // An app's base styles may cap every image at the width of its box (Tailwind gives img max-width: 100%), which shrank the
    // enlarged box above back to the window and moved the art off screen on Android.
    portrait.style.maxWidth = "none";
    portrait.style.position = "absolute";
    portrait.style.top = `calc(-1 * var(--ziggy-window-inset-top, 0px) + ${windowHeight} * (1 - 1 / ${scale}) / 2)`;
    portrait.style.left = `calc(-1 * var(--ziggy-window-inset-left, 0px) + ${windowWidth} * (1 - 1 / ${scale}) / 2)`;
    portrait.style.width = `calc(${windowWidth} / ${scale})`;
    portrait.style.height = `calc(${windowHeight} / ${scale})`;
    portrait.style.objectFit = "var(--ziggy-splash-fit, cover)";
    portrait.style.objectPosition = "center";
    portrait.style.transform = `scale(${scale})`;
    picture.appendChild(landscape);
    picture.appendChild(portrait);
    overlay.appendChild(picture);
    documentInterface.body.appendChild(overlay);

    const installedAt = Date.now();
    let removed = false;

    function removeElement(): void {
        if (removed) {
            return;
        }
        removed = true;
        overlay.remove();
    }

    portrait.addEventListener("error", removeElement);

    function remove(): Promise<void> {
        if (removed) {
            options.onFadeStart(0);
            return Promise.resolve();
        }
        return new Promise<void>(resolve => {
            const remaining = Math.max(0, options.minimumDisplayMilliseconds - (Date.now() - installedAt));
            documentInterface.defaultView.setTimeout(() => {
                if (removed) {
                    options.onFadeStart(0);
                    resolve();
                    return;
                }
                fadeOut(documentInterface, overlay, options.fadeDurationMilliseconds, () => options.onFadeStart(options.fadeDurationMilliseconds), resolve);
            }, remaining);
        });
    }

    return {
        remove,
    };
}

//
// Fades the overlay out with easeOutCubic and removes it, resolving once it is gone. The fade starts at its first frame, and
// onStarted is called at the frame after it, once the web view has drawn the fade's first step, so what the native app fades with
// it (the menu bar's cover, the system bars' strips) starts with what is on screen rather than ahead of it.
//
// Each frame moves the fade on by the time since the frame before it, but by no more than largestFrameMilliseconds, a frame at 10
// frames a second, so a slow device keeps the fade's timing. After the web view draws no frames for a while, which a slow device
// does, the fade goes on from where it was at its own speed: following the clock, it jumped, or, kept to small steps, it hurried
// through the rest and left the native app's fades behind.
//
export function fadeOut(documentLike: IDocumentLike, overlay: ISplashElement, fadeDurationMilliseconds: number, onStarted: () => void, onRemoved: () => void): void {
    const largestFrameMilliseconds = 100;
    let lastFrameAt = 0;
    let elapsed = 0;
    let frames = 0;

    function step(): void {
        const now = Date.now();
        if (frames > 0) {
            elapsed += Math.min(largestFrameMilliseconds, Math.max(0, now - lastFrameAt));
        }
        if (frames === 1) {
            onStarted();
        }
        lastFrameAt = now;
        frames += 1;
        const progress = Math.min(1, elapsed / Math.max(1, fadeDurationMilliseconds));
        overlay.style.opacity = String(1 - fadeEasing(progress));
        if (progress >= 1) {
            if (frames === 1) {
                onStarted();
            }
            overlay.remove();
            onRemoved();
            return;
        }
        documentLike.defaultView.requestAnimationFrame(step);
    }

    documentLike.defaultView.requestAnimationFrame(step);
}
