# occult.el - Functional Specification

From Latin *occultus* ("hidden, secret"). Collapse any buffer region into a
single-line summary while keeping the underlying text fully intact.

## Problem

When working in Emacs buffers - LLM chat sessions, org documents, eshell, etc. -
verbose sections become visual clutter. Folding mechanisms like outline-mode or
org-cycle are structure-aware and don't work on arbitrary regions. We need a way
to visually collapse any selected region, with the guarantee that:

- The hidden text remains in the buffer (accessible to `buffer-string`,
  `buffer-substring`, org-export, copy/kill, LLM context extraction)
- Search (isearch AND evil-ex-search) can find text inside folds
- It works in any buffer: read-only, special-mode, TUI Emacs

## Core Mechanism

Each fold is backed by three overlays: a parent covering the entire region,
a head covering any leading whitespace, and a body covering the hidden
suffix. The first non-whitespace line of the region remains live, navigable
buffer text.

- Parent overlay spans `[beg, end)` and carries an interaction keymap, a
  face, and `modification-hooks`. It is non-evaporating so that an edit
  cannot drop the parent before the modification-hook gets a chance to
  clean up head and body.
- Head overlay spans `[beg, head-split)` where `head-split` is the first
  position of the region's visible summary text: past leading
  whitespace, and past a hidden prefix of that line (see "Hidden
  prefixes" below). It carries the indicator glyph as `before-string`
  and `invisible 'occult`. The head is always created, even as a
  zero-length overlay at `beg` when there is no leading whitespace; this
  gives the indicator a single, uniform host regardless of input shape.
- Body overlay spans `[body-split, end)` where `body-split` is the first
  line break after `head-split`, the fold end, or
  `head-split + occult-summary-max-length` characters from `head-split`,
  whichever comes first. It carries `invisible 'occult` and prepends the
  ellipsis via `before-string`.
- The three overlays are linked: parent references body and head via
  `occult-body` / `occult-head`; head and body reference parent via
  `occult-parent`.
- Summary overlays are optional extras over the visible line, one per
  `occult-summary-replace-alist` match plus one for
  `occult-summary-line-prefix`. The parent lists them in
  `occult-summary-overlays` and they die with it. They change what the
  line displays, never the text.
- `buffer-invisibility-spec` includes `'occult` whenever the internal mode is
  active, so the head and body text is hidden from display.
- `buffer-string` / `buffer-substring-no-properties` return the full original
  text regardless of overlay state - this is what LLM packages, org-export, and
  copy/kill use.

## Public API

Interactive commands and a programmatic function.

### `occult-toggle`

Interactive, DWIM behavior:

- Region active: collapse the region into a summary overlay.
- Point on an occult overlay (no region): expand it AND reactivate the region
  at the fold's original boundaries (point moves to `end`, mark is set to
  `beg`, `activate-mark` is called).
- Neither: signals `user-error` ("No region selected and no occult fold at
  point").

### `occult-reveal-all`

Remove all occult overlays in the current buffer. Emits `Revealed N fold(s)`
in the echo area. Leaves point and mark untouched.

### `occult-hide-region` (beg end)

Non-interactive. Programmatic entry point for creating a fold.

- Returns `t` on success, `nil` on silent refusal (empty / whitespace-only
  region, or `beg >= end`).
- Calls `deactivate-mark` on success.
- Absorbs any existing folds overlapping the region: their bounds extend
  the new fold so no hidden content is lost.

### `occult-edit-region`

Open the fold at point in a narrowed indirect buffer for editing. Bound to
`e` on the fold keymap.

- Signals `user-error` if point is not on an occult fold.
- Creates an indirect buffer via `make-indirect-buffer` with CLONE=t.
- Deletes all occult overlays inside the indirect buffer so the fold content
  is fully visible and modification-hooks do not fire on shared text edits.
- Narrows to the fold range and activates `occult-edit-mode`.
- Base buffer's fold stays collapsed throughout the session.
- Returns the indirect buffer (also displayed via `pop-to-buffer`).
- If base buffer is read-only, the session is created in view mode
  (see below).

### `occult-edit-commit` / `occult-edit-abort`

Commands active only inside `occult-edit-mode`. Both signal `user-error` if
called outside an edit session.

- `occult-edit-commit`: marks the indirect buffer unmodified and kills it,
  keeping all user changes live in the base buffer (text is shared via the
  indirect-buffer mechanism, no re-insertion needed).
- `occult-edit-abort`: restores the fold region to its original contents
  using `replace-buffer-contents` under `inhibit-modification-hooks`, which
  shifts the base's fold overlays to match the original boundaries without
  dissolving them. Prompts with `yes-or-no-p` when the buffer is modified.

In a read-only view session both commands simply close the view buffer
without touching the base buffer.

## Edit Mode

`occult-edit-mode` is a buffer-local minor mode enabled inside the indirect
buffer created by `occult-edit-region`.

- Keymap `occult-edit-mode-map` binds `occult-edit-commit-key` to
  `occult-edit-commit` and `occult-edit-abort-key` to `occult-edit-abort`.
  The map is rebuilt from the custom key variables whenever the mode is
  enabled, and when either custom is set through `customize-set-variable`.
- `header-line-format` is set to `(:eval (occult-edit--header-line))`, so
  the displayed keys always reflect the current bindings via
  `where-is-internal`.

### Edit session header

```
 Edit Occult Fold  │ C-c C-c commit │ C-c C-k abort
```

### View session header (read-only base buffer)

```
 View Occult Fold  │ C-c C-k close
```

The view variant hides the commit binding entirely because there is nothing
to commit; the abort key is relabelled "close" and simply kills the view
buffer.

### Session state

Each session stores buffer-local state inside the indirect buffer:

| Variable                      | Meaning                                   |
|-------------------------------|-------------------------------------------|
| `occult-edit--original-text`  | Fold content at session start (abort).    |
| `occult-edit--base-buffer`    | Base buffer the session is attached to.   |
| `occult-edit--read-only-p`    | `t` iff base buffer was read-only at start. |

## Point and Mark State After Operations

- After `occult-hide-region` success (including via `occult-toggle` collapse
  branch): mark is deactivated, point is unchanged.
- After `occult-toggle` expand branch: the region is active at the fold's
  former boundaries, point at `end`, mark at `beg`.
- After `occult-reveal-all`: point and mark are untouched.

## No User-Facing Top-Level Minor Mode

There is no `occult-mode` the user toggles for folding. The user calls
`occult-toggle` and it works. An internal minor mode (`occult--mode`)
activates/deactivates automatically to manage buffer-local hooks when folds
exist. The user never interacts with it directly.

`occult-edit-mode` is different: it is enabled only inside the indirect
buffer `occult-edit-region` creates, and the user interacts with it
indirectly through the commit/abort key bindings surfaced in the header
line.

## Overlay Properties

Folds use three overlays: parent, head, and body.

### Parent overlay

Spans `[beg, end)`. Owns the face, keymap, and modification-hook.

| Property             | Value                                                  |
|----------------------|--------------------------------------------------------|
| `occult`             | `t` (marker for finding our overlays)                  |
| `occult-body`        | Reference to the body overlay                          |
| `occult-head`        | Reference to the head overlay                          |
| `occult-summary-overlays` | List of the summary overlays, possibly empty      |
| `face`               | `occult-summary`                                       |
| `keymap`             | TAB/mouse-1 toggle the fold; `e` opens it for editing  |
| `help-echo`          | "Press TAB to expand"                                  |
| `evaporate`          | `nil`                                                  |
| `modification-hooks` | Remove the fold when the characters under it change    |
| `occult-chars-tick`  | `buffer-chars-modified-tick` recorded before a change  |

Parent no longer carries `before-string`; the indicator lives on the head
overlay so that its placement is uniform regardless of leading whitespace.
Parent is non-evaporating so an edit cannot drop it before the
modification-hook runs and cleans up head and body.

The hook runs before and after every change that touches the fold. The
before call records `buffer-chars-modified-tick` on the parent; the after
call removes the fold only when the tick moved. A property-only change -
`put-text-property` over the range, a mode re-fontifying or re-protecting
its text - bumps `buffer-modified-tick` alone and keeps the fold with its
decorations. An insertion, a deletion or a same-length replacement
(`subst-char-in-region`) moves the characters tick and removes the fold.
Changes made under `inhibit-modification-hooks` reach neither call.

### Head overlay

Spans `[beg, head-split)`. Always created, even as a zero-length overlay
at `beg` when there is no leading whitespace, so that the indicator has a
single, uniform host.

| Property          | Value                                |
|-------------------|--------------------------------------|
| `occult-parent`   | Back-reference to parent overlay     |
| `invisible`       | `'occult`                            |
| `before-string`   | Indicator string                     |
| `evaporate`       | `nil`                                |

The head hides with `invisible`, never with `display`. `vertical-motion`
backs point up past a line that starts with a display string, and
`line-move` uses it for the last step of every upward move, so a head
hidden with an empty `display` string makes `previous-line` and evil's
`k` skip the summary line.

### Hidden prefixes

The display engine draws an invisible overlay's `before-string` where
that overlay ends. When text hidden by an `invisible` text property
follows the head's whitespace - a dired listing with
`dired-hide-details-mode` on hides everything between the leading
spaces and the file name - the iterator skips the head's end together
with the hidden run, and the indicator is never drawn.

`occult--leading-whitespace` therefore carries `head-split` past such a
run, and past the whitespace after it, so the head ends on text the
reader can see and the indicator is drawn in front of it. Only a run
that ends before the end of its line counts. A run reaching the end of
the line is a hidden line - a folded org subtree, an outline body, a
hidden magit section - not a hidden prefix, and the buffer may show it
again after the fold is made; the head leaves it to the summary, as it
always did. `next-single-char-property-change` finds the run's end, so
overlays and text properties both count, against the buffer's
`buffer-invisibility-spec` via `invisible-p`.

The consequence to know about: a hidden prefix skipped this way stays
hidden on the summary line even if the buffer shows it again later
(details toggled back on in dired), until the fold is revealed.

### Body overlay

Spans `[body-split, end)`. Hides the tail of the fold.

| Property                             | Value                              |
|--------------------------------------|------------------------------------|
| `occult-parent`                      | Back-reference to parent overlay   |
| `invisible`                          | `'occult`                          |
| `before-string`                      | Ellipsis string                    |
| `evaporate`                          | `t`                                |
| `isearch-open-invisible`             | `occult--isearch-reveal`           |
| `isearch-open-invisible-temporary`   | `occult--isearch-reveal-temporary` |

### Summary overlays

Created only when `occult-summary-replace-alist` or
`occult-summary-line-prefix` is set in the buffer. A replacement overlay
spans one match inside `[head-split, body-split)`; the line-prefix
overlay spans `[beg, body-split)`, because the display engine reads
`line-prefix` at the position that starts the screen line.

| Property        | Value                                          |
|-----------------|------------------------------------------------|
| `occult-parent` | Back-reference to parent overlay               |
| `display`       | Replacement text (replacement overlays)        |
| `line-prefix`   | `occult-summary-line-prefix` (prefix overlay)  |
| `evaporate`     | `t`                                            |

## Summary Line Format

```
📎 First non-whitespace line of the region...
```

The visible portion of a folded region is live buffer text between
`head-split` and `body-split`:

- `head-split` = first visible non-whitespace position in the region
  (leading blank lines and other ASCII whitespace are hidden by the head
  overlay, and so is a hidden prefix of the summary line - see "Hidden
  prefixes")
- `body-split = min(line-end-from-head-split, end, head-split + occult-summary-max-length)`

The head overlay hides `[beg, head-split)` and prepends the indicator via
its `before-string`. The body overlay hides `[body-split, end)` and
prepends `occult-ellipsis` via its `before-string`.

Both strings are drawn where their overlay ends, since both overlays
are invisible. The head's end is visible text by construction. The
body's end is the fold's end, and a fold that ends exactly where text a
text property hides begins loses its ellipsis and the line break the
ellipsis carries. Line-wise selections end at a line's first character,
so this does not come up in practice.

The ellipsis ends with a line break only when the hidden text ends with
one (`occult--ellipsis`). When the fold stops at end of line with the
newline excluded, or mid-line, the buffer text after `end` breaks the
line itself; a second break would render as an empty line under the
summary. Creation, isearch re-hide, and auto-reveal re-hide all apply
the same rule.

`occult-summary-max-length` is measured from `head-split`, not from the
region start, so leading whitespace does not consume any of the summary
budget.

- Indicator: customizable via `occult-indicator`, default `"📎 "`,
  buffer-local when set
- Ellipsis: customizable via `occult-ellipsis`, default `"..."`
- Max length: customizable via `occult-summary-max-length`, default `80`
- The visible summary is not synthesized or copied - it is the actual
  underlying buffer text, navigable and selectable.

### Replacements

`occult-summary-replace-alist` maps a regexp to what its matches should
display as. Every match between `head-split` and `body-split` gets an
overlay carrying the replacement as `display`; the rest of the line
renders as it is. A replacement is a string, where `\1` and friends
stand for groups of the match, or a function called with the matched
text.

- Entries apply in listing order, and a match overlapping an earlier
  replacement is skipped, so two display strings never stack over the
  same text.
- A match that starts before `body-split` and ends after it is replaced
  up to `body-split`; the rest of it is behind the fold already.
- A regexp that matches the empty string replaces nothing: the search
  steps over it rather than spinning in place.
- The buffer text is untouched, so isearch, kill/yank, `buffer-string`
  and `occult-edit-region` still see the full line. A search that lands
  under a replacement shows the replacement, as anything with a
  `display` property does.

### Line prefix

`occult-summary-line-prefix` overrides the `line-prefix` the buffer puts
on the summary line - indentation guides, block markers and the like,
which are display properties rather than text and so out of reach of a
replacement. An empty string drops the prefix. The override stops at
`body-split`, so the hidden lines keep theirs for when a fold is
temporarily revealed.

## Faces

Inherit from standard faces to work in light and dark themes without custom colors.

- `occult-summary` - the summary text. Inherits from `shadow`, adds `:slant italic`.
- `occult-indicator` - the prefix glyph. Inherits from `font-lock-constant-face`.
- `occult-edit-header` - edit/view label in the header line. Bold, inherits
  from `font-lock-function-name-face`.
- `occult-edit-commit-key` - commit key in the header line. Bold, inherits
  from `success`.
- `occult-edit-abort-key` - abort/close key in the header line. Bold,
  inherits from `error`.
- `occult-edit-header-separator` - pipes and descriptive labels in the
  header line. Inherits from `shadow`.

## Search Integration

### isearch (C-s / C-r)

Native integration via `invisible` property on the body overlay:

- `isearch-open-invisible-temporary`: temporarily reveals the fold while
  searching, re-hides when search moves on
- `isearch-open-invisible`: permanently reveals (deletes both overlays) when
  isearch exits with point inside a fold

### evil-ex-search (/ and ?)

Optional integration, only when evil is loaded. After `evil-ex-search-forward`,
`evil-ex-search-backward`, `evil-ex-search-next`, `evil-ex-search-previous` - if
point lands inside an occult overlay, temporarily reveal it. Re-hide is driven
by `post-command-hook` via shared `occult--auto-reveal-ov` state: once point
leaves the revealed fold, the hook re-hides it.

Implemented via advice on evil search commands, guarded by `(featurep 'evil)`.

## Auto-Reveal

Controlled by `occult-auto-reveal`:

- `nil` (default): folds stay collapsed until explicitly toggled
- `echo`: show full text in echo area when point is on a fold (truncated to
  approximately five frame-widths of characters)
- `expand`: temporarily expand when point enters, re-collapse when point leaves

isearch integration is always active regardless of this setting.

## Revert-Buffer Persistence

Folds survive `revert-buffer` (important for LLM chat buffers, eshell, etc.):

- `before-revert-hook`: save `(beg end content-hash)` tuples for all occult
  overlays into a buffer-local variable. `content-hash` is the SHA-256 of the
  region text.
- `after-revert-hook`: for each saved tuple, verify text at `(beg . end)`
  matches the stored hash. If yes, re-create the fold. If the hash does not
  match (or `end > point-max`), the fold is lost (graceful degradation).
  A range that already holds a fold is skipped: `insert-file-contents`
  replaces only the text that changed, so a fold over unchanged text
  survives the revert with its overlays intact and must not be recreated
  on top of itself.

This works reliably for append-only buffers (LLM, eshell) where old content
doesn't shift. For buffers that rebuild entirely (Dired `g`), folds are
lost - which is the expected behavior.

## Edge Cases

- Overlapping regions: the new fold absorbs any touched folds, extending
  its bounds outward so no hidden content is lost
- Nested folds: not representable; a selection inside an existing fold
  recreates that fold at its original bounds
- Empty / whitespace-only region: silent no-op, returns `nil`
- `beg >= end`: silent no-op, returns `nil`
- Single-line region: works (collapses to truncated summary)
- Region ending at end of line, newline excluded: the next line follows
  the summary directly, with no empty line between; the fold keeps the
  caller's exact bounds, so the newline stays visible buffer text
- Selection made backward (mark after point): folds exactly like the
  forward selection of the same span
- Read-only buffers: folds can be created and revealed normally; 
  `occult-edit-region` opens a view-only session instead of an edit session
- Buffers with no associated file: `occult-edit-region` works because the
  indirect buffer is created via `make-indirect-buffer`, which does not
  depend on the base buffer having a file
- Editing inside the indirect buffer: text propagates immediately to the
  base buffer (shared text), but the fold overlay in base stays collapsed
  because the modification-hooks only fire on the cloned overlays that were
  deleted from the indirect buffer at session start

## Customizable Variables

| Variable                       | Default      | Description                                  |
|--------------------------------|--------------|----------------------------------------------|
| `occult-indicator`             | `"📎 "`      | Prefix string for summary line, buffer-local |
| `occult-ellipsis`              | `"..."`      | Suffix string for summary line               |
| `occult-summary-max-length`    | `80`         | Max chars from first line to show            |
| `occult-summary-replace-alist` | `nil`        | Patterns the summary line displays differently |
| `occult-summary-line-prefix`   | `nil`        | Prefix drawn at the start of the summary line |
| `occult-auto-reveal`           | `nil`        | Auto-reveal mode: nil, echo, or expand       |
| `occult-lighter`               | `" Occ"`     | Mode-line lighter (internal mode)            |
| `occult-edit-lighter`          | `" OccEdit"` | Mode-line lighter inside an edit session     |
| `occult-edit-commit-key`       | `"C-c C-c"`  | Key that commits an edit session             |
| `occult-edit-abort-key`        | `"C-c C-k"`  | Key that aborts / closes an edit session     |

## Package Metadata

- Requires: Emacs 29.1
- No external dependencies (evil integration is optional/lazy)
- License: GPL-3.0-or-later
- Single file: `occult.el`
