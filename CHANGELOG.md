# Changelog

Record every change to the SQL or the instructions, with the reason.

## v0.2 (2026-11-13)
- Added PO views (`sql/002_po_views.sql`): `agent.po_lines`,
  `agent.incoming_by_sku`, `agent.po_eta_changes`, plus date/quantity
  parsing helpers for the supply team's sheet.
- Instructions: weekly brief now covers inbound and PO risks; SKU review
  flags SKUs on POs missing from sku_master; new "PO check" for sheet fixes.

## v0.1 (2026-11-07)
- Created `agent` schema with 6 views (`sql/001_agent_views_v0.sql`).
- First version of agent instructions: weekly brief + SKU review.
