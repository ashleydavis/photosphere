import React, { ReactNode, createContext, useContext, useEffect, useState } from "react";
import { useGallery } from "./gallery-context";

export interface ISearchContext {
    //
    // Set to true to open the search input.
    //
    openSearch: boolean;
    setOpenSearch: (open: boolean) => void;

    //
    // The search currently being typed by the user.
    //
    searchInput: string;
    setSearchInput: (input: string) => void;

    //
    // Commits the search the user has typed in.
    //
    onCommitSearch: () => Promise<void>;

    //
    // Cancels/closes the search.
    //
    onCloseSearch: () => Promise<void>;
}


const SearchContext = createContext<ISearchContext | undefined>(undefined);

export interface ISearchContextProviderProps {
    children: ReactNode | ReactNode[];
}

export function SearchContextProvider({ children }: ISearchContextProviderProps) {
    // 
    // Set to true to open the search input.
    //
    const [openSearch, setOpenSearch] = useState<boolean>(false);
    
    //
    // The search currently being typed by the user.
    //
    const [searchInput, setSearchInput] = useState<string>("");

    const { search, clearSearch, searchText } = useGallery();

    //
    // Sync searchText from gallery context with search input.
    //
    useEffect(() => {
        if (searchText.length > 0 && !openSearch) {
            setSearchInput(searchText);
            setOpenSearch(true);
        }
    }, [searchText, openSearch, setSearchInput, setOpenSearch]);

    //
    // Commits the search the user has typed in.
    //
    async function onCommitSearch() {
        await search(searchInput);
    }

    //
    // Cancels/closes the search.
    //
    async function onCloseSearch() {
        await clearSearch();
        setSearchInput("");
        setOpenSearch(false);
    }

    const value: ISearchContext = {
        openSearch,
        setOpenSearch,
        searchInput,
        setSearchInput,
        onCommitSearch,
        onCloseSearch,
    };
    
    return (
        <SearchContext.Provider value={value}>
            {children}
        </SearchContext.Provider>
    );
}

//
// Get the search context.
//
export function useSearch() {
    const context = useContext(SearchContext);
    if (!context) {
        throw new Error(`SearchContext is not set! Add SearchContextProvider to the component tree.`);
    }
    return context;
}

