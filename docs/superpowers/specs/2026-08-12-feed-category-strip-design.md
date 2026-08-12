# Feed Category Strip — Design

Approved by Tanis 2026-08-12 ("lets make it first and then decide the pipeline").
App-side only; any pipeline changes are a separate later decision.

## What

A horizontal chip strip pinned above the feed's PageView:

`All · Markets · Economy · IPO · Corporate · Policy · Global · Commodities · Geopolitics · ⚙`

- Tap a chip → the feed shows only that category. Client-side filter of the
  already-loaded 50 stories; zero new queries.
- **All** is the default and shows everything except hidden categories.
- **⚙** opens a bottom sheet listing all 8 categories with on/off toggles.
  A toggled-off category disappears from the feed AND from the strip.
  Hidden means hidden everywhere — All respects it too.
- Hidden set persists on-device (SharedPreferences, `hidden_categories_v1`).
  The tapped chip selection is session-only — it's a filter, not a setting.

## Rules

- Categories are the pipeline's fixed 8 (ai.py CATEGORIES); the strip order is
  fixed (above), not data-driven — a stable strip beats a jumping one.
- A story with a null category (shouldn't happen for approved rows, but guard)
  shows under All only and never crashes a chip filter.
- Hiding the currently-selected category resets selection to All.
- A notification tap (pendingStory) resets selection to All before jumping —
  the alerted story must never be invisible because of a chip.
- Filter change jumps the PageView back to the top card.
- Style: clay-black minimal — flat chips, square corners, `border` outline,
  active chip in `green`; mono font like the ledger line.

## Non-goals (this cut)

Reordering categories, per-category alert rules, cross-device sync of hidden
set (single-device user today; sync arrives with beta accounts).

## Test contract

- Pure filter `visibleStories(list, hidden, selected)` unit-tested: hidden
  excluded from All; selected narrows; null-category tolerated.
- Widget: chips render, tap narrows the PageView, hidden category's chip is
  absent, ⚙ sheet toggle hides live.
- Alert landing resets to All (regression on the M7 alert-tap fix).
