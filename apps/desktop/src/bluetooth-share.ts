// @ts-ignore - dbus-next has incomplete typings
import dbus from 'dbus-next';

// @ts-ignore
const { Interface, ACCESS_READ } = dbus.interface;

//
// BLE service and characteristic UUIDs for Photosphere database sharing.
//
const SERVICE_UUID = '0000db51-0000-1000-8000-00805f9b34fb';
const CHAR_UUID = '0000db52-0000-1000-8000-00805f9b34fb';

//
// D-Bus object paths for the GATT application.
//
const APP_PATH = '/com/photosphere';
const SERVICE_PATH = '/com/photosphere/service0';
const CHAR_PATH = '/com/photosphere/service0/char0';
const ADV_PATH = '/com/photosphere/adv0';

//
// Active D-Bus connection, kept alive while sharing.
//
let activeBus: any = null;

//
// GATT characteristic that serves the database config JSON.
//
class GattCharacteristic1 extends Interface {
    private configData: Buffer;

    constructor(configData: Buffer) {
        super('org.bluez.GattCharacteristic1');
        this.configData = configData;
    }

    get UUID(): string { return CHAR_UUID; }

    get Service(): string { return SERVICE_PATH; }

    get Flags(): string[] { return ['read']; }

    ReadValue(_options: Record<string, unknown>): number[] {
        return Array.from(this.configData);
    }
}

GattCharacteristic1.configureMembers({
    properties: {
        UUID: { signature: 's', access: ACCESS_READ },
        Service: { signature: 'o', access: ACCESS_READ },
        Flags: { signature: 'as', access: ACCESS_READ },
    },
    methods: {
        ReadValue: { inSignature: 'a{sv}', outSignature: 'ay' },
    },
});

//
// GATT service wrapping the config characteristic.
//
class GattService1 extends Interface {
    constructor() {
        super('org.bluez.GattService1');
    }

    get UUID(): string { return SERVICE_UUID; }

    get Primary(): boolean { return true; }
}

GattService1.configureMembers({
    properties: {
        UUID: { signature: 's', access: ACCESS_READ },
        Primary: { signature: 'b', access: ACCESS_READ },
    },
    methods: {},
});

//
// BLE advertisement that makes the device discoverable as 'PhotoSphere'.
//
class LEAdvertisement1 extends Interface {
    constructor() {
        super('org.bluez.LEAdvertisement1');
    }

    get Type(): string { return 'peripheral'; }

    get ServiceUUIDs(): string[] { return [SERVICE_UUID]; }

    get LocalName(): string { return 'PhotoSphere'; }

    Release(): void {}
}

LEAdvertisement1.configureMembers({
    properties: {
        Type: { signature: 's', access: ACCESS_READ },
        ServiceUUIDs: { signature: 'as', access: ACCESS_READ },
        LocalName: { signature: 's', access: ACCESS_READ },
    },
    methods: {
        Release: { inSignature: '', outSignature: '' },
    },
});

//
// ObjectManager that tells BlueZ about all our GATT objects.
//
class ObjectManager extends Interface {
    constructor() {
        super('org.freedesktop.DBus.ObjectManager');
    }

    GetManagedObjects(): Record<string, Record<string, Record<string, unknown>>> {
        return {
            [SERVICE_PATH]: {
                'org.bluez.GattService1': {
                    UUID: new dbus.Variant('s', SERVICE_UUID),
                    Primary: new dbus.Variant('b', true),
                },
            },
            [CHAR_PATH]: {
                'org.bluez.GattCharacteristic1': {
                    UUID: new dbus.Variant('s', CHAR_UUID),
                    Service: new dbus.Variant('o', SERVICE_PATH),
                    Flags: new dbus.Variant('as', ['read']),
                },
            },
        };
    }
}

ObjectManager.configureMembers({
    properties: {},
    methods: {
        GetManagedObjects: { inSignature: '', outSignature: 'a{oa{sa{sv}}}' },
    },
});

//
// Starts advertising the database config as a BLE GATT peripheral via BlueZ.
//
export async function startBluetoothShare(config: unknown): Promise<void> {
    await stopBluetoothShare();

    const bus = dbus.systemBus();
    activeBus = bus;

    const configData = Buffer.from(JSON.stringify(config));

    bus.export(APP_PATH, new ObjectManager());
    bus.export(SERVICE_PATH, new GattService1());
    bus.export(CHAR_PATH, new GattCharacteristic1(configData));
    bus.export(ADV_PATH, new LEAdvertisement1());

    const bluezRoot = await bus.getProxyObject('org.bluez', '/');
    const objectManager = bluezRoot.getInterface('org.freedesktop.DBus.ObjectManager');
    const objects = await objectManager.GetManagedObjects();

    const adapterPath = Object.keys(objects).find((adapterKey: string) =>
        objects[adapterKey]['org.bluez.Adapter1'] !== undefined
    );

    if (!adapterPath) {
        throw new Error('No Bluetooth adapter found');
    }

    const adapter = await bus.getProxyObject('org.bluez', adapterPath);

    const gattManager = adapter.getInterface('org.bluez.GattManager1');
    await gattManager.RegisterApplication(APP_PATH, {});

    const advManager = adapter.getInterface('org.bluez.LEAdvertisingManager1');
    await advManager.RegisterAdvertisement(ADV_PATH, {});
}

//
// Stops the active BLE GATT peripheral and disconnects from D-Bus.
//
export async function stopBluetoothShare(): Promise<void> {
    if (!activeBus) {
        return;
    }

    const bus = activeBus;
    activeBus = null;

    try {
        const bluezRoot = await bus.getProxyObject('org.bluez', '/');
        const objectManager = bluezRoot.getInterface('org.freedesktop.DBus.ObjectManager');
        const objects = await objectManager.GetManagedObjects();

        const adapterPath = Object.keys(objects).find((adapterKey: string) =>
            objects[adapterKey]['org.bluez.Adapter1'] !== undefined
        );

        if (adapterPath) {
            const adapter = await bus.getProxyObject('org.bluez', adapterPath);
            const gattManager = adapter.getInterface('org.bluez.GattManager1');
            await gattManager.UnregisterApplication(APP_PATH);
            const advManager = adapter.getInterface('org.bluez.LEAdvertisingManager1');
            await advManager.UnregisterAdvertisement(ADV_PATH);
        }
    }
    catch {
        // Ignore cleanup errors.
    }

    bus.disconnect();
}
