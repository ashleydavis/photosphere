import React, { ReactNode, createContext, useContext, useEffect, useState } from "react";
import { useGallery } from "./gallery-context";
import { useConfig } from "./config-context";

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
    // Accepts an optional text parameter; if omitted, uses the current searchInput.
    //
    onCommitSearch: (text?: string) => Promise<void>;

    //
    // Cancels/closes the search.
    //
    onCloseSearch: () => Promise<void>;

    //
    // The list of recent searches, most recent first, capped at 10.
    //
    recentSearches: string[];

    //
    // Removes a search from the recent searches list.
    //
    removeRecentSearch: (searchText: string) => Promise<void>;

    //
    // The list of saved searches.
    //
    savedSearches: string[];

    //
    // Saves a search to the saved searches list.
    //
    saveSearch: (searchText: string) => Promise<void>;

    //
    // Removes a search from the saved searches list.
    //
    unsaveSearch: (searchText: string) => Promise<void>;
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

    //
    // Recent searches list, loaded from the configuration file, most recent first, capped at 10.
    //
    const [recentSearches, setRecentSearches] = useState<string[]>([]);

    //
    // Saved searches list, loaded from the configuration file.
    //
    const [savedSearches, setSavedSearches] = useState<string[]>([]);

    const { search, clearSearch, searchText } = useGallery();
    const config = useConfig();

    //
    // Load recent searches and saved searches from the configuration file on mount.
    //
    useEffect(() => {
        config.get<string[]>("recentSearches").then(searches => {
            setRecentSearches(searches || []);
        });
        config.get<string[]>("savedSearches").then(searches => {
            setSavedSearches(searches || []);
        });
    }, []);

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
    // Commits the search the user has typed in and saves it to the configuration file.
    // Accepts an optional text parameter; if omitted, uses the current searchInput.
    //
    async function onCommitSearch(text?: string) {
        const searchTerm = text !== undefined ? text : searchInput;
        await search(searchTerm);
        if (searchTerm.trim().length > 0 && !savedSearches.includes(searchTerm.trim())) {
            await config.add<string>("recentSearches", searchTerm, 10);
            const updated = [searchTerm, ...recentSearches.filter(item => item !== searchTerm)].slice(0, 10);
            setRecentSearches(updated);
        }
    }

    //
    // Removes a search from the recent searches list in the configuration file.
    //
    async function removeRecentSearch(recentSearch: string) {
        await config.remove<string>("recentSearches", recentSearch);
        setRecentSearches(recentSearches.filter(item => item !== recentSearch));
    }

    //
    // Saves a search to the saved searches list.
    //
    async function saveSearch(searchText: string) {
        await config.add<string>("savedSearches", searchText);
        setSavedSearches(prev => [searchText, ...prev.filter(item => item !== searchText)]);
        await config.remove<string>("recentSearches", searchText);
        setRecentSearches(prev => prev.filter(item => item !== searchText));
    }

    //
    // Removes a search from the saved searches list.
    //
    async function unsaveSearch(searchText: string) {
        await config.remove<string>("savedSearches", searchText);
        setSavedSearches(prev => prev.filter(item => item !== searchText));
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
        recentSearches,
        removeRecentSearch,
        savedSearches,
        saveSearch,
        unsaveSearch,
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

