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
// Strips surrounding double-quotes from a value.
//
function stripQuotes(value: string): string {
    value = value.trim();
    if (value.startsWith('"') && value.endsWith('"')) {
        return value.slice(1, -1);
    }
    return value;
}

//
// Returns true if any label in the array contains the pattern (case-insensitive substring).
//
function labelMatches(labels: string[], pattern: string): boolean {
    const lwr = pattern.toLowerCase();
    return labels.some(label => label.toLowerCase().includes(lwr));
}

//
// Filters items by label search.
// Supports:
//   "-"           — items with no labels
//   "val"         — any label contains "val"
//   "a"&"b"       — has a label matching "a" AND a label matching "b"
//   "a"|"b"       — has a label matching "a" OR "b"
// Values may be quoted to support multi-word labels.
//
export function applyLabelsTerm(rawValue: string, items: IGalleryItem[]): IGalleryItem[] {
    if (rawValue === "-") {
        return items.filter(item => !item.labels || item.labels.length === 0);
    }

    // AND: all &-separated values must each match a label.
    if (rawValue.includes("&")) {
        const required = rawValue.split("&").map(stripQuotes);
        return items.filter(item => {
            if (!item.labels || item.labels.length === 0) {
                return false;
            }
            return required.every(pattern => labelMatches(item.labels!, pattern));
        });
    }

    // OR: any |-separated value must match a label.
    const alternatives = rawValue.split("|").map(stripQuotes);
    return items.filter(item => {
        if (!item.labels || item.labels.length === 0) {
            return false;
        }
        return alternatives.some(pattern => labelMatches(item.labels!, pattern));
    });
}

//
// Splits search text into tokens, respecting double-quoted strings as single tokens.
//
export function tokenizeSearchText(searchText: string): string[] {
    const tokens: string[] = [];
    let current = "";
    let inQuotes = false;

    for (const ch of searchText) {
        if (ch === '"') {
            inQuotes = !inQuotes;
            current += ch;
        }
        else if (ch === ' ' && !inQuotes) {
            if (current.trim()) {
                tokens.push(current.trim());
            }
            current = "";
        }
        else {
            current += ch;
        }
    }

    if (current.trim()) {
        tokens.push(current.trim());
    }

    return tokens;
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

    const terms = tokenizeSearchText(searchText);

    let searchFields = defaultSearchFields;

    for (let term of terms) {
        if (term.startsWith(".")) {
            term = term.substring(1);
            const parts = term.split("=").map(part => part.trim());
            if (parts.length !== 2) {
                continue; // Bad formatting.
            }
            const fieldName = parts[0].toLowerCase();
            const fieldValue = parts[1];
            searchFields = defaultSearchFields; // Reset scope for subsequent free-text terms.

            if (fieldName === "labels") {
                items = applyLabelsTerm(fieldValue, items);
                continue;
            }

            searchFields = [ parts[0] ];
            term = fieldValue;
        }

        items = applySearchTerm(term, items, searchFields);
    }

    return items;
}
