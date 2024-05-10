import { useEffect, useRef } from "react"
import { uuid } from "./uuid";

function getClientId() {
    const existingClientId = localStorage.getItem("clientId");
    if (existingClientId) {
        return existingClientId;
    }

    const newClientId = uuid();
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