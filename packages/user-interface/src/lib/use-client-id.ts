import { RandomUuidGenerator } from "utils";

function getClientId() {
    const existingClientId = localStorage.getItem("clientId");
    if (existingClientId) {
        return existingClientId;
    }

    const uuidGenerator = new RandomUuidGenerator();
    const newClientId = uuidGenerator.generate();
    localStorage.setItem("clientId", newClientId);
    return newClientId;
}

//
// Gets a unique ID for the client.
//
export function useClientId() {
    const clientId = getClientId();
    return {
        clientId,
    };
}