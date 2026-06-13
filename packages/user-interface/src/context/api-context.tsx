import React, { ReactNode, createContext, useContext } from "react";
import axios from "axios";

//
// How the response body should be parsed. A subset of axios's response types,
// covering only the modes the app actually uses.
//
export type ApiResponseType = "json" | "text" | "blob" | "arraybuffer";

//
// Configuration for a single HTTP request. A deliberately small subset of axios's
// request config exposing only what the app needs.
//
export interface IApiRequestConfig {
    //
    // How to parse the response body. When omitted, axios's default (json) applies.
    //
    responseType?: ApiResponseType;

    //
    // Request headers.
    //
    headers?: Record<string, string>;
}

//
// The result of an HTTP request.
//
export interface IApiResponse<DataType> {
    //
    // Parsed response body.
    //
    data: DataType;

    //
    // HTTP status code.
    //
    status: number;
}

//
// HTTP client abstraction. Centralises every REST/HTTP call behind one interface
// so it can be swapped for a mock in stories and tests.
//
export interface IApi {
    //
    // Performs an HTTP GET request and resolves with the response.
    //
    get<DataType>(url: string, config?: IApiRequestConfig): Promise<IApiResponse<DataType>>;

    //
    // Performs an HTTP POST request with a JSON body and resolves with the response.
    //
    post<DataType>(url: string, body: object, config?: IApiRequestConfig): Promise<IApiResponse<DataType>>;
}

//
// The real HTTP client, backed by axios. Used by the running app.
//
export const axiosApi: IApi = {
    get: async <DataType,>(url: string, config?: IApiRequestConfig): Promise<IApiResponse<DataType>> => {
        const response = await axios.get<DataType>(url, config);
        return { data: response.data, status: response.status };
    },
    post: async <DataType,>(url: string, body: object, config?: IApiRequestConfig): Promise<IApiResponse<DataType>> => {
        const response = await axios.post<DataType>(url, body, config);
        return { data: response.data, status: response.status };
    },
};

const ApiContext = createContext<IApi | undefined>(undefined);

//
// Props for the API context provider.
//
export interface IApiContextProviderProps {
    //
    // The API client supplied to consumers.
    //
    value: IApi;

    //
    // Wrapped content.
    //
    children: ReactNode | ReactNode[];
}

//
// Provides an IApi implementation to the component tree.
//
export function ApiContextProvider({ value, children }: IApiContextProviderProps) {
    return (
        <ApiContext.Provider value={value}>
            {children}
        </ApiContext.Provider>
    );
}

//
// Accesses the API client from context. Throws when no provider is present.
//
export function useApi(): IApi {
    const context = useContext(ApiContext);
    if (!context) {
        throw new Error(`ApiContext is not set! Add ApiContextProvider to the component tree.`);
    }
    return context;
}
