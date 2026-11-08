# Changelog

Record every change to the SQL or the instructions, with the reason.

## v0.2 (2026-11-07)
- Instructions: ignore codes ending in `-FBM` / `-FBM-2`. They are
  duplicate MX 3PL codes kept for Amazon FBM and were all rejected in the
  first SKU review.
- Instructions: the SKU review now produces a Google Sheet for approval
  (fixed tab and column format, Row IDs, Decision dropdowns). SQL is only
  written after the user marks the sheet ready, only for approved rows,
  and after re-checking each row against the views.
- Instructions: added the steps used in the first review (bundle
  mappings, near matches, retirement status recomputed after pending
  mappings) so the sheet format can be reproduced.
- First review applied: 122 mappings added, 13 SKUs deactivated
  (`sku_review_2026-11-07_approved.sql`, run manually).

## v0.1 (2026-11-07)
- Created `agent` schema with 6 views (`sql/001_agent_views_v0.sql`).
- First version of agent instructions: weekly brief + SKU review.``

