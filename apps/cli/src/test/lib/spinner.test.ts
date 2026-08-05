import { spinner } from '../../lib/spinner';

// The same module instances the code under test is given: jest.config.js maps the `./clack/prompts`
// and `utils` imports in src/lib onto these, so requiring them here gets the very jest.fn()s that
// spinner() calls.
const clackPrompts = require('../../../__mocks__/clack-prompts.js');
const { log } = require('utils');

describe('spinner', () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test('uses the animated spinner when a user is watching', () => {
        const spin = spinner(true);

        spin.start('Waiting');

        expect(clackPrompts.spinner).toHaveBeenCalled();
        expect(log.info).not.toHaveBeenCalled();
    });

    test('does not create an animated spinner when non-interactive', () => {
        // The animated spinner takes hold of the terminal, which stops the process outright when it
        // is not the terminal's foreground job. With --yes there is nobody watching it anyway.
        const spin = spinner(false);

        spin.start('Waiting');

        expect(clackPrompts.spinner).not.toHaveBeenCalled();
    });

    test('reports the same messages as plain log lines when non-interactive', () => {
        const spin = spinner(false);

        spin.start('Waiting for sender');
        spin.message('Still waiting');
        spin.stop('Payload received');

        expect(log.info).toHaveBeenCalledWith('Waiting for sender');
        expect(log.info).toHaveBeenCalledWith('Still waiting');
        expect(log.info).toHaveBeenCalledWith('Payload received');
    });

    test('reports nothing as cancelled when non-interactive', () => {
        const spin = spinner(false);

        expect(spin.isCancelled).toBe(false);
    });
});
