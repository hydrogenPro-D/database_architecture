# database_architecture

MSSQL schema + load tooling for the Plating-Line QC dataset, targeting **Azure
SQL Database**. The schema is designed visually in [drawdb.com](https://drawdb.com)
and everything downstream is generated/scripted so it's reproducible across
environments.

## Environments

Two databases on the same Azure SQL server:

| Env  | Database          | Notes |
|------|-------------------|-------|
| dev  | `dataloggingDev`  | ⚠️ **this is PRODUCTION** |
| test | `dataloggingTest` | test / staging |

All QC objects live in a dedicated **`qc`** schema, kept identical on both DBs by
running the same migrations against each.

## Files

```
PROCEDURES.md                app integration guide — how to call the qc.usp_* CRUD procs
generate_mssql.py            drawdb export ─► sql/migrations/004_create_qc_tables.sql
db_common.py                 shared interactive prompts + connection helper (used by load_data.py)
load_data.py                 loads the 21 CSVs into qc.* (interactive)
Draw DB/                     drawdb exports (.json + .sql) — source of truth for the schema
db_tables/                   the 21 load-ready CSVs
sql/migrations/
  001_create_schema_qc.sql              create schema qc + the qc.schema_migrations ledger
  002_create_role_qc_data_manager.sql   role (read-only on qc) + EXECUTE placeholder
  003_create_user_db_qc_data_manager.sql contained user, added to the role
  004_create_qc_tables.sql              GENERATED — the 21 tables
  005_create_qc_views.sql               the 10 denormalizing UI views (plate split 28/29/30)
  006_create_qc_ph_procedures.sql       pH Control CRUD procs + EXECUTE grants
  007_create_qc_adding_chemicals_procedures.sql  Adding Chemicals CRUD (JSON payload) + grants
  008_create_qc_production_procedures.sql        Production Tracking CRUD (JSON payload) + grants
  009_create_qc_conductivity_procedures.sql      Conductivity CRUD (JSON payload) + grants
  010_create_qc_bath_procedures.sql              Cleaner/Activator/Strike/Plate CRUD (12 procs) + grants
  011_add_cobalt_dosing.sql                      add CoSO4 dosing: co_dose/co_value cols, vw_production_tracking + production procs (@co_dose)
  012_add_view_indexes.sql                       covering nonclustered indexes on child FK columns to speed up the vw_* views
  013_add_change_polling.sql                     row_version on the log tables + vw_change_watermark (app polls this to detect changes)
  014_add_dosage_change_log.sql                  vw_electrode_chemical_dosage + usp_electrode_chemical_dosage_insert (replaces chemicals_log.csv)
  015_fix_adding_chemicals_concentration.sql     bugfix: adding-chemicals procs cast concentration via DECIMAL so HCl % (30.0) isn't dropped
  016_conductivity_strike_stage.sql              split pos.25 into a Strike stage: conductivity_vat_log.stage col + backfill, procs + vw_conductivity
  017_add_created_at_and_row_added.sql           created_at (Norway-local DEFAULT) on the 7 event/log tables; views expose it as [Row added]
  018_edit_guard_on_created_at.sql               update/delete editability keyed on created_at (created today/yesterday) instead of entered date
sql/maintenance/
  reset_qc_tables_TEST_ONLY.sql         drop all qc tables (test only) to rebuild
```

## Prerequisites

- Python 3.8+ and a venv with `pyodbc` (`.venv` already set up; otherwise
  `python -m venv .venv` then `.\.venv\Scripts\python -m pip install pyodbc`)
- **ODBC Driver 18 for SQL Server** installed
- SSMS or Azure Data Studio (to run the migrations)
- An admin/owner login on the server (to create schema/role/user and to load data)

## 1. Regenerate the table DDL (only after changing the schema in drawdb)

Export the schema from drawdb into `Draw DB/`, then:

```
.\.venv\Scripts\python generate_mssql.py
```

This picks the **newest** export automatically and writes
`sql/migrations/004_create_qc_tables.sql` — schema-qualified, idempotent
(`IF OBJECT_ID(...) IS NULL CREATE TABLE`), inline foreign keys, DECIMAL sizes
derived from the actual CSV data, and a self-record into the ledger.
**Never hand-edit the generated file.**

## 2. Create the test database (one-off)

Create an **empty** `dataloggingTest` in the Azure portal (match dev's tier).
We deliberately do *not* copy dev, so no production data leaks into test — the
structure comes from the migrations.

## 3. Run the migrations — manually, in order

Open each file in SSMS / Azure Data Studio **connected to the target database**
and run them **in order**: `001 → 002 → … → 017 → 018`.

- Each file is a **single batch** with a `DB_NAME()` guard at the top, so running
  it against the wrong database aborts the whole script (a guard in its own
  `GO`-batch would *not* stop later batches — SSMS runs them independently).
- Each file is **idempotent** (safe to re-run) and **records itself** in
  `qc.schema_migrations`, so even running one file by hand keeps the audit trail.
- **`003` needs a password:** type it into the `@pw` line, run the file, then
  **close it without saving**. The committed file keeps only a placeholder, so no
  secret reaches git. (Forgetting to set it throws instead of creating a junk user.)

Check what's been applied at any time:

```sql
SELECT * FROM qc.schema_migrations ORDER BY id;
```

Do the same against **dev (prod)** when you're confident — same files, same order.

## 4. Load CSV data

```
.\.venv\Scripts\python load_data.py
```

Interactive menu. Preserves CSV ids (`IDENTITY_INSERT`), turns empty fields into
real `NULL`, loads parents-before-children, all-or-nothing. **Refuses** if any
target table already has rows. Loading into **dev (prod)** requires typing the
database name + `yes`. Credentials are typed at the prompt, never stored.

## Adding changes later (e.g. stored procedures + their grants)

Migrations are **append-only**. Do **not** edit an already-applied file. Add a new
numbered file, e.g.:

```
sql/migrations/005_create_qc_procedures.sql      -- CREATE/ALTER PROCEDURE qc.usp_...
sql/migrations/006_grant_execute_qc_procs.sql    -- GRANT EXECUTE ON qc.usp_... TO qc_data_manager_role
```

then run it (in order) against each environment. It self-records like the rest.

## Safety model

- **No `USE`** (Azure SQL DB doesn't support it). Safety is *connection* + a
  single-batch `DB_NAME()` guard at the top of every migration.
- **Idempotent**: every script is safe to re-run; nothing drops data.
- **dev = prod**: `load_data.py` gates dev behind a typed confirmation; the
  migration guards stop a wrong-DB run.
- **No secrets in git**: the qc user password is typed at run time and the file
  is closed without saving. Loader credentials are always typed, never stored.
- **Audit trail**: `qc.schema_migrations` records every migration that ran, in
  each database.
