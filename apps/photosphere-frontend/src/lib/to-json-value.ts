import type { IJsonValue } from "ziggy-bridge";

//
// Converts a value built from interfaces (a database entry, a list of assets) to the JSON value the bridge sends. An interface
// has no index signature, so it is not assignable to a JSON object by type alone, and this makes the conversion real rather than
// asserting it: the value goes through JSON, which is what the bridge does with it anyway, so a field that is undefined is left
// out and a value JSON cannot hold (undefined at the top, a function) throws instead of being sent as something else.
//
export function toJsonValue<TValue>(value: TValue): IJsonValue {
    const text = JSON.stringify(value);
    if (text === undefined) {
        throw new Error("The value cannot be sent to the core because it has no JSON form.");
    }
    return JSON.parse(text);
}
