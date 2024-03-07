import React, { ReactNode, createContext, useContext, useState } from "react";

export interface ISearchContext { 

    //
    // The current search text.
    //
    searchText: string;

    //
    // Search for assets based on text input.
    //
    search(searchText: string): Promise<void>;

    //
    // Clears the current search.
    //
    clearSearch(): Promise<void>;
}

const SearchContext = createContext<ISearchContext | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

export function SearchContextProvider({ children }: IProps) {

    //
    // The current search that has been executed.
    //
    const [ searchText, setSearchText ] = useState<string>("");

    //
    // Sets the search text for finding assets.
    // Passing in empty string or undefined gets all assets.
    // This does a gallery reset when the search term has changed.
    //
    async function search(newSearchText: string): Promise<void> {
        
        console.log(`Setting asset search ${newSearchText}`);

        if (searchText === newSearchText) {
            //
            // No change.
            //
            return;
        }

        setSearchText(newSearchText);
    }

    //
    // Clears the current search.
    //
    async function clearSearch(): Promise<void> {
        await search("");
    }

    const value: ISearchContext = {
        searchText,
        search,
        clearSearch,
    };
    
    return (
        <SearchContext.Provider value={value} >
            {children}
        </SearchContext.Provider>
    );
}

//
// Use the Search context in a component.
//
export function useSearch(): ISearchContext {
    const context = useContext(SearchContext);
    if (!context) {
        throw new Error(`Search context is not set! Add SearchContextProvider to the component tree.`);
    }
    return context;
}

