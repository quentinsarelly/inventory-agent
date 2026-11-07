# Sarelly Inventory Agent

A Claude agent that writes a weekly inventory brief and proposes
SKU master data fixes, reading from the inventory database in Supabase.

## Structure
- `sql/`: views the agent reads, numbered in the order they were run.
  Never edit a file that has already been run. Add a new numbered file
  (e.g. `002_add_sales_views.sql`) with the change instead.
- `agent/instructions.md`: the agent's instructions. This is the source
  of truth; the Claude Project reads it from here.
- `examples/`: good outputs, saved as reference for what "right" looks like.
- `CHANGELOG.md`: what changed and why.

## How to make a change
1. Edit `agent/instructions.md`, or add a new file in `sql/`.
2. If it's SQL, run it in the Supabase SQL editor.
3. Note the change in `CHANGELOG.md` and commit.
4. Sync the Claude Project so it picks up the new version.

## Safety rules
- The Claude connector to Supabase is read-only, scoped to one project,
  with only the database tools enabled.
- The agent only reads views in the `agent` schema. Don't expose that
  schema in Supabase's API settings.
- The agent proposes changes to `sku_master` / `sku_mappings` as SQL.
  A person reviews and runs them. Deactivate SKUs, never delete them.
- Never commit keys, tokens, or passwords to this repo.
