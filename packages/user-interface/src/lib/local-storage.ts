//
// Service for accesisng local storage.
//

export interface ILocalStorage {

    //
    // Gets a value from storage.
    //
    get(name: string): Promise<string | undefined>;

    // 
    // Sets a value in storage.
    //
    set(name: string, value: string): Promise<void>;

    //
    // Removes a value from storage.
    //
    remove(name: string): Promise<void>;
}

export class LocalStorage implements ILocalStorage {

    //
    // Gets a value from storage.
    //
    async get(name: string): Promise<string | undefined> {
        return window.localStorage.getItem(name) || undefined;
    }

    // 
    // Sets a value in storage.
    //
    async set(name: string, value: string): Promise<void> {
        window.localStorage.setItem(name, value);
    }

    //
    // Removes a value from storage.
    //
    async remove(name: string): Promise<void> {
        window.localStorage.removeItem(name);
    }
}
