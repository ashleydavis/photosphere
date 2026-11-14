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
    width: string;
    height: string;
    objectFit: string;
    objectPosition: string;
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
    portrait.style.display = "block";
    portrait.style.width = "100%";
    portrait.style.height = "100%";
    portrait.style.objectFit = "cover";
    portrait.style.objectPosition = "center";
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
            return Promise.resolve();
        }
        return new Promise<void>(resolve => {
            const remaining = Math.max(0, options.minimumDisplayMilliseconds - (Date.now() - installedAt));
            documentInterface.defaultView.setTimeout(() => {
                if (removed) {
                    resolve();
                    return;
                }
                fadeOut(documentInterface, overlay, options.fadeDurationMilliseconds, resolve);
            }, remaining);
        });
    }

    return {
        remove,
    };
}

//
// Fades the overlay out with easeOutCubic and removes it, resolving once it is gone.
//
export function fadeOut(documentLike: IDocumentLike, overlay: ISplashElement, fadeDurationMilliseconds: number, onRemoved: () => void): void {
    const fadeStartedAt = Date.now();

    function step(): void {
        const elapsed = Date.now() - fadeStartedAt;
        const progress = Math.min(1, elapsed / Math.max(1, fadeDurationMilliseconds));
        overlay.style.opacity = String(1 - fadeEasing(progress));
        if (progress >= 1) {
            overlay.remove();
            onRemoved();
            return;
        }
        documentLike.defaultView.requestAnimationFrame(step);
    }

    documentLike.defaultView.requestAnimationFrame(step);
}
