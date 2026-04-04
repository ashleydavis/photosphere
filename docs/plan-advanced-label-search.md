# Plan: Advanced Label Search

## Context
The search box supports `.field=value` syntax for field-specific filtering, and spaces as AND separators. Labels are stored as `string[]` on `IGalleryItem`. The user needs four new label capabilities: single label match, AND (multiple `.labels=` terms), OR (pipe-separated), and empty check. Multi-word labels require quoted values since spaces are the token separator.

## Proposed Query Syntax

| Goal | Query |
|---|---|
| Single label | `.labels=my-birthday` |
| Multi-word label | `.labels="one thing"` |
| OR | `.labels="one thing"\|"another"` |
| AND | `.labels="one thing"&"another"` |
| Empty labels | `.labels=-` |

## Files to Change

- `packages/user-interface/src/lib/gallery-search.ts` — production changes
- `packages/user-interface/src/test/lib/gallery-search.test.ts` — new tests
- `../photosphere.wiki/Gallery-Search.md` — new wiki page
- `../photosphere.wiki/Home.md` — add link to the new page in Quick Links

## Implementation

### 1. Add `tokenizeSearchText` (new, exported)
Replaces `searchText.split(' ')`. Tracks whether we're inside double-quotes and only splits on spaces outside quotes. This allows `.labels="one thing"` to remain a single token.

```typescript
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
```

### 2. Add `applyLabelsTerm` (new, exported)
Handles the value portion of a `.labels=<value>` token:
- Value `"-"` → items with no/empty labels
- `&`-separated values = AND: item must have a label matching **each** value
- `|`-separated values = OR: item must have a label matching **any** value
- Strip surrounding `"..."` quotes from each value
- Substring match (case-insensitive) against each item's labels array

```typescript
export function applyLabelsTerm(rawValue: string, items: IGalleryItem[]): IGalleryItem[] {
    if (rawValue === "-") {
        return items.filter(item => !item.labels || item.labels.length === 0);
    }

    function stripQuotes(value: string): string {
        value = value.trim();
        if (value.startsWith('"') && value.endsWith('"')) {
            return value.slice(1, -1);
        }
        return value;
    }

    function labelMatches(labels: string[], pattern: string): boolean {
        const lwr = pattern.toLowerCase();
        return labels.some(label => label.toLowerCase().includes(lwr));
    }

    // AND: all &-separated values must match a label
    if (rawValue.includes("&")) {
        const required = rawValue.split("&").map(stripQuotes);
        return items.filter(item => {
            if (!item.labels || item.labels.length === 0) return false;
            return required.every(pattern => labelMatches(item.labels!, pattern));
        });
    }

    // OR: any |-separated value must match a label
    const alternatives = rawValue.split("|").map(stripQuotes);
    return items.filter(item => {
        if (!item.labels || item.labels.length === 0) return false;
        return alternatives.some(pattern => labelMatches(item.labels!, pattern));
    });
}
```

### 3. Modify `applySearch`

Two changes:
1. Replace `searchText.split(' ')` with `tokenizeSearchText(searchText)`
2. In the loop body, after the `.field=value` parsing extracts `searchFields = [parts[0]]` and `term = parts[1]`, add a branch: if the field is `"labels"`, call `applyLabelsTerm(term, items)` and `continue`; otherwise fall through to the existing `applySearchTerm`.
3. Reset `searchFields = defaultSearchFields` after any `.field=` branch so subsequent free-text terms search all fields (fixes a pre-existing scoping bug).

Loop body becomes:
```typescript
for (let term of terms) {
    if (term.startsWith(".")) {
        term = term.substring(1);
        const parts = term.split("=").map(part => part.trim());
        if (parts.length !== 2) {
            continue;
        }
        const fieldName = parts[0].toLowerCase();
        const fieldValue = parts[1];
        searchFields = defaultSearchFields; // reset scope for subsequent terms

        if (fieldName === "labels") {
            items = applyLabelsTerm(fieldValue, items);
            continue;
        }
        searchFields = [ parts[0] ];
        term = fieldValue;
    }
    items = applySearchTerm(term, items, searchFields);
}
```

## Tests to Add

### New `describe("tokenizeSearchText", ...)`:
- Splits simple space-separated terms
- Treats quoted string with spaces as one token
- Handles multiple quoted tokens

### New `describe("applyLabelsTerm", ...)`:
- Empty value matches item with `labels: undefined`
- Empty value matches item with `labels: []`
- Empty value does not match item with labels
- Single unquoted value matches label by substring
- Single quoted value matches multi-word label
- `|` OR: matches item with either label
- `|` OR: does not match item with neither label
- Case-insensitive matching

### Additional cases in `describe("applySearch", ...)`:
- `.labels=my-birthday` filters correctly
- `.labels="one thing"` matches multi-word label
- `.labels=birthday|beach` OR logic
- `.labels=-` matches only items with no labels
- `.labels="one thing"&"another"` AND logic
- Free-text term after `.labels=` searches all fields (not just labels)

## Documentation

### New file: `../photosphere.wiki/Gallery-Search.md`
A user-facing reference page covering:
- Overview of the search box and how to open it
- Free-text search (single and multi-term AND)
- Field-specific search syntax (`.field=value`)
- Label search syntax with examples for all four cases:
  - Single label: `.labels=my-birthday`
  - Multi-word label: `.labels="one thing"`
  - OR: `.labels="one thing"|"another"`
  - AND: `.labels="one thing"&"another"`
  - Empty: `.labels=-`

### `../photosphere.wiki/Home.md` update
Add `[[Gallery Search]]` to the Quick Links section.

## Verification
```
cd packages/user-interface && bun test src/test/lib/gallery-search.test.ts
bun run compile  # from repo root
```
