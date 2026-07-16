#!/usr/bin/env bash
# Recreate the vault database from schema. Unlike the Focal demo there is
# no separate archive to protect: the INSERT-ONLY RAW VAULT is itself the
# durable history layer (for attributes -- see DATAVAULT.md for what that
# does and does not buy relative to Focal's delivery archive).
source "$(dirname "$0")/lib.sh"
echo "==> Initialising $DB (Data Vault 2.0, natural-key variant)"
rm -f "$DB"
cat "$ROOT_DIR/schema/01_stage.sql" \
    "$ROOT_DIR/schema/02_stage2_views.sql" \
    "$ROOT_DIR/schema/03_raw_vault.sql" \
    "$ROOT_DIR/schema/04_business_vault.sql" \
    "$ROOT_DIR/schema/05_info_mart.sql" | sql
echo "    stage, raw vault, business vault and info mart created."
