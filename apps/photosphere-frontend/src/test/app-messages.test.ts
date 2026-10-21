import { AppMessages } from '../lib/app-messages';
import { FakeZiggy } from './fake-ziggy';

describe('AppMessages', () => {
    test('invoke sends the message name as the name and the payload as the data, and resolves with the reply', async () => {
        const ziggy = new FakeZiggy();
        ziggy.replies.set('get-config', 'dark');
        const messages = new AppMessages(ziggy);

        const reply = await messages.invoke('get-config', 'theme');

        expect(reply).toEqual('dark');
        expect(ziggy.invoked).toEqual([{ name: 'get-config', data: 'theme' }]);
    });

    test('send sends the message name as the name and the payload as the data', () => {
        const ziggy = new FakeZiggy();
        const messages = new AppMessages(ziggy);

        messages.send('notify-database-edited', { databasePath: '/db' });

        expect(ziggy.sent).toEqual([{ name: 'notify-database-edited', data: { databasePath: '/db' } }]);
    });
});
