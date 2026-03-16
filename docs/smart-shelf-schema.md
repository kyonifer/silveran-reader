# Smart Shelf JSON Schema

A **SmartShelf** is a user-defined dynamic collection that filters books based on a set of conditions.

## Top-Level Object: `SmartShelf`

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "name": "Unfinished Audiobooks",
  "conditions": [ ... ],
  "createdAt": 731529600.0
}
```

| Field | Type | Description |
|---|---|---|
| `id` | UUID string | Unique identifier |
| `name` | string | Display name for the shelf |
| `conditions` | array of `ShelfCondition` | Filter rules (see below) |
| `createdAt` | number (Date) | Creation timestamp (seconds since reference date) |

## Condition Logic

Conditions within the array follow **AND/OR** semantics:
- Conditions are **ANDed** together by default.
- An `orSeparator` condition splits conditions into groups. Groups are **ORed**; conditions within a group are **ANDed**.

Example: `[A, B, orSeparator, C]` means `(A AND B) OR (C)`.

## `ShelfCondition` (tagged union)

Each condition is a JSON object with a single key indicating the type. Swift's `Codable` encodes enum cases with associated values as `{ "caseName": { ...params } }`.

### Conditions with `mode` + `values` (string matching)

These all share the same shape: include/exclude mode with a list of string values. Matching is case-insensitive. Within a single condition, the `values` array is **ORed** -- a book matches if it has *any* of the listed values. To require a book to have *all* of several values, use separate conditions (which are ANDed within the same group).

| Condition Key | What it matches against |
|---|---|
| `status` | Book's reading status name |
| `tag` | Book's tag names |
| `series` | Book's series names |
| `author` | Book's author names |
| `narrator` | Book's narrator names |
| `translator` | Creators with role `"trl"` |
| `publicationYear` | Book's sortable publication year string |

```json
{ "author": { "mode": "include", "values": ["Brandon Sanderson", "Joe Abercrombie"] } }
{ "tag": { "mode": "exclude", "values": ["dnf"] } }
```

**`InclusionMode`** values: `"include"`, `"exclude"`

### Conditions with `mode` + `conditions` (enum matching)

| Condition Key | Sub-condition enum | Allowed values |
|---|---|---|
| `format` | `FormatCondition` | `"ebook"`, `"audiobook"`, `"readaloud"`, `"missingReadaloud"`, `"ebookOnly"`, `"audiobookOnly"` |
| `location` | `LocationCondition` | `"downloaded"`, `"serverOnly"`, `"localFiles"` |
| `progress` | `ProgressCondition` | `"notStarted"`, `"inProgress"`, `"completed"` |

```json
{ "format": { "mode": "include", "conditions": ["audiobook"] } }
{ "progress": { "mode": "include", "conditions": ["inProgress", "notStarted"] } }
{ "location": { "mode": "exclude", "conditions": ["serverOnly"] } }
```

### `rating` -- numeric comparison

```json
{ "rating": { "comparison": "greaterThanOrEqual", "value": 4 } }
```

**`RatingComparison`** values: `"greaterThanOrEqual"`, `"lessThanOrEqual"`, `"equal"`

`value` is an integer (rating is rounded before comparison).

### `publicationYearComparison` -- numeric year comparison

```json
{ "publicationYearComparison": { "comparison": "newerThan", "value": 2020 } }
```

**`YearComparison`** values: `"newerThan"`, `"olderThan"`, `"exactly"`

### Boolean (presence/absence) conditions

These have no associated values -- they encode as bare strings within the conditions array:

| Value | Matches when... |
|---|---|
| `"hasAuthor"` | Book has at least one author |
| `"hasNarrator"` | Book has at least one narrator |
| `"hasTranslator"` | Book has a creator with role `"trl"` |
| `"hasSeries"` | Book belongs to at least one series |
| `"hasRating"` | Book has a rating > 0 |
| `"hasPublicationYear"` | Book has a non-empty publication year |
| `"hasTag"` | Book has at least one tag |
| `"noAuthor"` | Book has no authors |
| `"noNarrator"` | Book has no narrators |
| `"noTranslator"` | Book has no translator creators |
| `"noSeries"` | Book has no series |
| `"noRating"` | Book has no rating or rating <= 0 |
| `"noPublicationYear"` | Book has empty publication year |
| `"noTag"` | Book has no tags |

### `orSeparator`

Encodes as the bare string `"orSeparator"`. Splits the condition list into OR-groups.

## Full Example

A shelf that matches: in-progress audiobooks that belong to a series **OR** any book rated 5 stars:

```json
{
  "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "name": "Active Series Listens or Favorites",
  "conditions": [
    { "format": { "mode": "include", "conditions": ["audiobook"] } },
    { "progress": { "mode": "include", "conditions": ["inProgress"] } },
    "hasSeries",
    "orSeparator",
    { "rating": { "comparison": "equal", "value": 5 } }
  ],
  "createdAt": 731529600.0
}
```

This evaluates as: `(format=audiobook AND progress=inProgress AND hasSeries) OR (rating == 5)`.
