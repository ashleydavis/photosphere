import { IGalleryItem } from "./gallery-item";

//
// The default fields to search across.
//
export const defaultSearchFields = [ "_id", "hash", "location", "description", "labels", "origFileName", "origPath", "contentType" ];

//
// Determines if a field value matches the given search text.
//
export function valueMatches(fieldValue: any, searchTextLwr: string): boolean {
    if (Array.isArray(fieldValue)) {
        for (const elementValue of fieldValue) {
            if (elementValue.toLowerCase().includes(searchTextLwr)) {
                return true;
            }
        }
        return false;
    }
    else {
        return fieldValue.toLowerCase().includes(searchTextLwr);
    }
}

//
// Searches for a term in fields of assets.
//
export function applySearchTerm(searchText: string, items: IGalleryItem[], searchFields: string[]): IGalleryItem[] {
    const searchedItems: IGalleryItem[] = [];
    const searchTextLwr = searchText.toLowerCase();

    searchFields = searchFields.map(field => field.toLowerCase());

    for (const item of items) {

        let matches = false;

        for (const searchedFieldName of searchFields) {
            //
            // Find the lower case field name in the item.
            //
            for (const [actualFieldName, fieldValue] of Object.entries(item)) {
                if (actualFieldName.toLowerCase().includes(searchedFieldName)) {
                    if (valueMatches(fieldValue, searchTextLwr)) {
                        matches = true;
                        break;
                    }
                }
            }

            if (matches) {
                break;
            }
        }

        if (matches) {
            searchedItems.push(item);
        }
    }

    return searchedItems;
}

//
// Searches for assets based on text input.
// Returns a filtered copy of the input items array.
//
export function applySearch(items: IGalleryItem[], searchText: string): IGalleryItem[] {

    searchText = searchText.trim();

    if (searchText === "") {
        return items.slice(); // Clone the array to make sure state update triggers a render.
    }

    const terms = searchText.split(' ').map(term => term.trim());

    let searchFields = defaultSearchFields;

    for (let term of terms) {
        if (term.startsWith(".")) {
            term = term.substring(1);
            const parts = term.split("=").map(part => part.trim());
            if (parts.length !== 2) {
                continue; // Bad formatting.
            }
            searchFields = [ parts[0] ];
            term = parts[1];
        }

        items = applySearchTerm(term, items, searchFields);
    }

    return items;
}
