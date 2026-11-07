import { isTestMode } from '../lib/test-mode';

//
// Runs the check with a page address whose query is the given text, then puts the global object back as it was.
//
function isTestModeAt(search: string): boolean {
    const globals = globalThis as { window?: { location: { search: string } } };
    globals.window = {
        location: {
            search,
        },
    };
    try {
        return isTestMode();
    }
    finally {
        delete globals.window;
    }
}

describe('isTestMode', () => {
    test('is true when the page address asks for test mode', () => {
        expect(isTestModeAt('?restApiUrl=x&testMode=1')).toBe(true);
    });

    test('is false when the page address does not ask for it, or asks with another value', () => {
        expect(isTestModeAt('?restApiUrl=x')).toBe(false);
        expect(isTestModeAt('?testMode=0')).toBe(false);
    });

    test('is false where there is no page', () => {
        expect(isTestMode()).toBe(false);
    });
});
