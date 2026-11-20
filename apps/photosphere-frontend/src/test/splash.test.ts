//
// The splash screen: the easing curve, the overlay it installs and the fade that removes it.
//

import { fadeEasing, installSplashScreen, IDocumentLike, ISplashElement, ISplashStyle, ISplashWindow } from "../lib/splash";

//
// An element that records what the splash does to it.
//
class FakeElement implements ISplashElement {
    style: ISplashStyle = {
        position: "",
        inset: "",
        background: "",
        zIndex: "",
        overflow: "",
        opacity: "",
        display: "",
        top: "",
        left: "",
        width: "",
        height: "",
        objectFit: "",
        objectPosition: "",
        transform: "",
        maxWidth: "",
    };

    attributes: Record<string, string> = {};

    children: FakeElement[] = [];

    listeners: Record<string, (() => void)[]> = {};

    removed = false;

    setAttribute(name: string, value: string): void {
        this.attributes[name] = value;
    }

    addEventListener(type: string, listener: () => void): void {
        this.listeners[type] = this.listeners[type] ?? [];
        this.listeners[type].push(listener);
    }

    appendChild(child: ISplashElement): void {
        this.children.push(child as FakeElement);
    }

    remove(): void {
        this.removed = true;
    }
}

//
// A window whose timeouts and animation frames the test runs itself.
//
class FakeWindow implements ISplashWindow {
    timeouts: { callback: () => void; delayMilliseconds: number }[] = [];

    frames: ((time: number) => void)[] = [];

    setTimeout(callback: () => void, delayMilliseconds: number): number {
        this.timeouts.push({ callback, delayMilliseconds });
        return this.timeouts.length;
    }

    requestAnimationFrame(callback: (time: number) => void): number {
        this.frames.push(callback);
        return this.frames.length;
    }
}

//
// A document that records the elements the splash creates.
//
class FakeDocument implements IDocumentLike {
    body = new FakeElement();


    defaultView = new FakeWindow();

    created: FakeElement[] = [];

    createElement(): FakeElement {
        const element = new FakeElement();
        this.created.push(element);
        return element;
    }
}

describe("fadeEasing", () => {
    test("eases from zero to one on the cubic-bezier(0.4, 0, 0.2, 1) curve", () => {
        expect(fadeEasing(0)).toBe(0);
        expect(fadeEasing(0.5)).toBeCloseTo(0.778, 2);
        expect(fadeEasing(1)).toBe(1);
    });
});

describe("installSplashScreen", () => {
    test("appends one overlay with the background and both image paths", () => {
        const documentLike = new FakeDocument();
        installSplashScreen(documentLike, {
            background: "#140A24",
            minimumDisplayMilliseconds: 600,
            fadeDurationMilliseconds: 400,
            onFadeStart: () => {},
        });
        expect(documentLike.body.children.length).toBe(1);
        const overlay = documentLike.body.children[0];
        expect(overlay.attributes["data-id"]).toBe("ziggy-splash");
        expect(overlay.style.background).toBe("#140A24");
        expect(overlay.style.position).toBe("fixed");
        expect(overlay.style.zIndex).toBe("2147483647");
        const picture = overlay.children[0];
        expect(picture.children.length).toBe(2);
        const source = picture.children[0];
        expect(source.attributes["media"]).toBe("(orientation: landscape)");
        expect(source.attributes["srcset"]).toBe("/ziggy-splash-landscape.png");
        const image = picture.children[1];
        expect(image.attributes["src"]).toBe("/ziggy-splash-portrait.png");
        expect(image.attributes["alt"]).toBe("");
        expect(image.style.objectFit).toBe("var(--ziggy-splash-fit, cover)");
        expect(image.style.transform).toBe("scale(var(--ziggy-splash-scale, 1))");
        expect(image.style.maxWidth).toBe("none");
        expect(image.style.position).toBe("absolute");
        expect(image.style.top).toBe("calc(-1 * var(--ziggy-window-inset-top, 0px) + (100% + var(--ziggy-window-inset-top, 0px) + var(--ziggy-window-inset-bottom, 0px)) * (1 - 1 / var(--ziggy-splash-scale, 1)) / 2)");
        expect(image.style.left).toBe("calc(-1 * var(--ziggy-window-inset-left, 0px) + (100% + var(--ziggy-window-inset-left, 0px) + var(--ziggy-window-inset-right, 0px)) * (1 - 1 / var(--ziggy-splash-scale, 1)) / 2)");
        expect(image.style.width).toBe("calc((100% + var(--ziggy-window-inset-left, 0px) + var(--ziggy-window-inset-right, 0px)) / var(--ziggy-splash-scale, 1))");
        expect(image.style.height).toBe("calc((100% + var(--ziggy-window-inset-top, 0px) + var(--ziggy-window-inset-bottom, 0px)) / var(--ziggy-splash-scale, 1))");
    });

    test("an image that fails to load removes the overlay at once", async () => {
        const documentLike = new FakeDocument();
        const splash = installSplashScreen(documentLike, {
            background: "#140A24",
            minimumDisplayMilliseconds: 600,
            fadeDurationMilliseconds: 400,
            onFadeStart: () => {},
        });
        const overlay = documentLike.body.children[0];
        const image = overlay.children[0].children[1];
        expect(image.listeners["error"].length).toBe(1);
        image.listeners["error"][0]();
        expect(overlay.removed).toBe(true);
        await expect(splash.remove()).resolves.toBeUndefined();
    });


    test("remove waits for the minimum display and follows the eased fade", async () => {
        let now = 1000;
        const clock = jest.spyOn(Date, "now").mockImplementation(() => now);
        const documentLike = new FakeDocument();
        const splash = installSplashScreen(documentLike, {
            background: "#140A24",
            minimumDisplayMilliseconds: 600,
            fadeDurationMilliseconds: 400,
            onFadeStart: () => {},
        });
        const overlay = documentLike.body.children[0];
        let resolved = false;
        const removal = splash.remove().then(() => {
            resolved = true;
        });
        expect(documentLike.defaultView.timeouts.length).toBe(1);
        expect(documentLike.defaultView.timeouts[0].delayMilliseconds).toBe(600);
        expect(overlay.removed).toBe(false);
        expect(resolved).toBe(false);
        now = 1600;
        documentLike.defaultView.timeouts[0].callback();
        expect(overlay.removed).toBe(false);
        expect(documentLike.defaultView.frames.length).toBe(1);
        documentLike.defaultView.frames[0](0);
        expect(overlay.style.opacity).toBe("1");
        // Frames 25 milliseconds apart follow the curve.
        for (let frame = 1; frame < 16; frame++) {
            now = 1600 + frame * 25;
            documentLike.defaultView.frames[frame](0);
            expect(parseFloat(overlay.style.opacity)).toBeCloseTo(1 - fadeEasing(frame * 25 / 400), 5);
            expect(overlay.removed).toBe(false);
        }
        now = 2000;
        documentLike.defaultView.frames[16](0);
        expect(overlay.style.opacity).toBe("0");
        expect(overlay.removed).toBe(true);
        await removal;
        expect(resolved).toBe(true);
        clock.mockRestore();
    });

    test("after frames stop coming the fade goes on from where it was, at its own speed, by at most 100 milliseconds a frame", async () => {
        let now = 1000;
        const clock = jest.spyOn(Date, "now").mockImplementation(() => now);
        const documentLike = new FakeDocument();
        const durations: number[] = [];
        const splash = installSplashScreen(documentLike, {
            background: "#140A24",
            minimumDisplayMilliseconds: 600,
            fadeDurationMilliseconds: 400,
            onFadeStart: durationMilliseconds => durations.push(durationMilliseconds),
        });
        const overlay = documentLike.body.children[0];
        const removal = splash.remove();
        documentLike.defaultView.timeouts[0].callback();
        documentLike.defaultView.frames[0](0);
        expect(overlay.style.opacity).toBe("1");
        // No frame for 300 milliseconds: the fade moves on by 100 of them.
        now = 1300;
        documentLike.defaultView.frames[1](0);
        expect(parseFloat(overlay.style.opacity)).toBeCloseTo(1 - fadeEasing(100 / 400), 5);
        expect(durations).toEqual([400]);
        // Then frames 25 milliseconds apart go on from there at the fade's own speed.
        for (let frame = 2; frame < 13; frame++) {
            now = 1300 + (frame - 1) * 25;
            documentLike.defaultView.frames[frame](0);
            expect(parseFloat(overlay.style.opacity)).toBeCloseTo(1 - fadeEasing((100 + (frame - 1) * 25) / 400), 5);
            expect(overlay.removed).toBe(false);
        }
        now = 1300 + 12 * 25;
        documentLike.defaultView.frames[13](0);
        expect(overlay.style.opacity).toBe("0");
        expect(overlay.removed).toBe(true);
        await removal;
        clock.mockRestore();
    });

    test("onFadeStart is told the fade's duration at the fade's second frame, once its first is drawn, not before", () => {
        const documentLike = new FakeDocument();
        const durations: number[] = [];
        const splash = installSplashScreen(documentLike, {
            background: "#140A24",
            minimumDisplayMilliseconds: 600,
            fadeDurationMilliseconds: 400,
            onFadeStart: durationMilliseconds => durations.push(durationMilliseconds),
        });
        splash.remove();
        expect(durations).toEqual([]);
        documentLike.defaultView.timeouts[0].callback();
        expect(durations).toEqual([]);
        documentLike.defaultView.frames[0](0);
        expect(durations).toEqual([]);
        documentLike.defaultView.frames[1](0);
        expect(durations).toEqual([400]);
        documentLike.defaultView.frames[2](0);
        expect(durations).toEqual([400]);
    });

    test("onFadeStart is told 0 when the overlay is already gone", async () => {
        const documentLike = new FakeDocument();
        const durations: number[] = [];
        const splash = installSplashScreen(documentLike, {
            background: "#140A24",
            minimumDisplayMilliseconds: 600,
            fadeDurationMilliseconds: 400,
            onFadeStart: durationMilliseconds => durations.push(durationMilliseconds),
        });
        const image = documentLike.body.children[0].children[0].children[1];
        image.listeners["error"][0]();
        await splash.remove();
        expect(durations).toEqual([0]);
    });
});
