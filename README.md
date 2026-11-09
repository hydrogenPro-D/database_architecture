# database_architecture

MSSQL schema + load tooling for the Plating-Line QC dataset, targeting **Azure
SQL Database**. The original schema is designed visually in
[drawdb.com](https://drawdb.com) and generated from there; everything since is
hand-written numbered migrations, so the whole thing is reproducible across
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
README.md                    this file — how to run everything
MIGRATION_OVERVIEW.md        current state: folders, ledger, all migrations, permissions
MIGRATION_PLAYBOOK.md        the rules for writing a migration
DB_HANDOFF.md                the original 21-CSV data contract
PROCEDURES.md                app integration guide — how to call the qc.usp_* CRUD procs
UI_VIEWS_HANDOFF.md          the vw_* views the app reads
VAT_DUMP_HANDOFF.md          migration 031 contract (dumping history)
APP_SETTINGS_HANDOFF.md      migration 032 contract (app settings, append-only)

db_common.py                 shared interactive prompts + connection helper
generate_mssql.py            drawdb export ─► sql/migrations/004_create_qc_tables.sql
load_data.py                 loads the 21 CSVs into qc.* (interactive)
load_contamination_data.py   loads the wide contamination CSV (unpivots it)
load_plate_cobalt_data.py    loads plate rows + Ni absorbance from the weekly workbook
export_plate_from_prod.py    READ-ONLY export of plate data from a database
sync_plate_test_from_prod.py wipes + reloads TEST's plate data from that export

Draw DB/                     drawdb exports (.json + .sql) — source for 004 only
db_tables/                   the 21 load-ready CSVs
data/                        contamination_log.csv
plate_cobalt/                the 4 cobalt CSVs
export/                      prod exports + the weekly result scheme workbook
config/                      config.json — credentials, gitignored
sql/maintenance/             measure_view_runtimes.sql, reset_qc_tables_TEST_ONLY.sql
```

### Migrations (`sql/migrations/`)

```
001 create schema qc + the qc.schema_migrations ledger
002 role (read-only on qc) + EXECUTE placeholder
003 contained user, added to the role
004 GENERATED — the 21 tables
005 the 10 denormalizing UI views (plate split 28/29/30)
006 pH Control CRUD procs + EXECUTE grants
007 Adding Chemicals CRUD (JSON payload) + grants
008 Production Tracking CRUD (JSON payload) + grants
009 Conductivity CRUD (JSON payload) + grants
010 Cleaner/Activator/Strike/Plate CRUD (12 procs) + grants
011 CoSO4 dosing: co_dose/co_value cols, vw_production_tracking, procs (@co_dose)
012 covering nonclustered indexes on child FK columns, to speed up the vw_* views
013 row_version on the log tables + vw_change_watermark (the app polls this)
014 vw_electrode_chemical_dosage + its insert proc (replaces chemicals_log.csv)
015 bugfix: adding-chemicals procs cast concentration so HCl % (30.0) isn't dropped
016 split pos.25 into a Strike stage: conductivity_vat_log.stage + backfill
017 created_at (Norway-local DEFAULT) on the 7 event tables; views expose [Row added]
018 editability keyed on created_at (created today/yesterday), not the entered date
019 RENAME the role + user to production_data_manager_role / db_production_..._user
020 Water Quality tab: table, view, procs, watermark entity
021 notes column on Water Quality
022 Contamination Log: parent/child tables, wide view, JSON procs, watermark entity
023 notes column on Contamination
024 read-only grant on the dbo schema
025 plate cobalt: measurement → DECIMAL(10,5), Ni re-type, absorbance, wider proc casts
026 split the two nickel labels into separate view columns
027 created_at / [Row added] on Production Tracking; guards switched to it
028 measurement limits: append-only section + threshold tables, seeded 32 / 67 rows
029 limits create + delete: is_deleted tombstones, hidden from the view
030 pH before/after: three (after) columns from measurement_number = 3
031 vat dumping history: table, 3 per-vat views + latest, procs, 3 watermark entities
032 app settings: append-only key/value table, seeded with the acid calculator's two
033 seed the five contamination limit keys into qc.app_setting
```

`MIGRATION_OVERVIEW.md` groups these by purpose and documents the permission
model and error codes.

## Prerequisites

- Python 3.8+ and a venv with `pyodbc` (`.venv` already set up; otherwise
  `python -m venv .venv` then `.\.venv\Scripts\python -m pip install pyodbc`)
- `openpyxl` as well, if you run `load_plate_cobalt_data.py` (it reads .xlsx)
- **ODBC Driver 18 for SQL Server** installed
- SSMS or Azure Data Studio (to run the migrations)
- An admin/owner login on the server (to create schema/role/user and to load data)
- Your current IP allowed through the Azure SQL firewall

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

Note this only regenerates **004**. Every table change since (017, 020, 022,
025, 027, 028, 031, 032 …) lives in its own migration and is *not* reflected
back into drawdb.

## 2. Create the test database (one-off)

Create an **empty** `dataloggingTest` in the Azure portal (match dev's tier).
We deliberately do *not* copy dev, so no production data leaks into test — the
structure comes from the migrations.

## 3. Run the migrations — manually, in order

Open each file in SSMS / Azure Data Studio **connected to the target database**
and run them **in order**, `001 → … → 033`.

- Every file starts with a `DB_NAME()` guard, so running it against anything but
  `dataloggingDev` / `dataloggingTest` aborts.
- **001–012 are single-batch** (a `THROW` guard aborts the whole file).
  **013 onward are multi-batch** — `CREATE VIEW` / `CREATE PROCEDURE` must lead a
  batch — and use `RAISERROR` + `SET NOEXEC ON` … `SET NOEXEC OFF` instead,
  because SSMS runs `GO`-separated batches independently.
- Every file is **idempotent** (safe to re-run) and **records itself** in
  `qc.schema_migrations`, so even running one by hand keeps the audit trail.
- **`003` needs a password:** type it into the `@pw` line, run the file, then
  **close it without saving**. The committed file keeps only a placeholder, so no
  secret reaches git. (Forgetting to set it throws instead of creating a junk user.)

Check what's been applied at any time:

```sql
SELECT filename, applied_at_utc FROM qc.schema_migrations ORDER BY id;
```

Do the same against **dev (prod)** when you're confident — same files, same order.

> ⚠️ A **parse** error (e.g. `Msg 1046`) kills only its own batch, so the rest of
> the file still runs and the ledger can get ahead of the data. If a migration
> errors, check the data actually landed, fix the file and re-run it — they are
> all idempotent.

## 4. Load data

```
.\.venv\Scripts\python load_data.py                  # the original 21 CSVs
.\.venv\Scripts\python load_contamination_data.py    # contamination (unpivots a wide CSV)
.\.venv\Scripts\python load_plate_cobalt_data.py     # plate rows + Ni absorbance (xlsx)
```

All interactive: pick the environment, type credentials at the prompt. They
preserve ids where the source has them (`IDENTITY_INSERT`), turn empty fields
into real `NULL`, load parents-before-children, and are all-or-nothing. Loading
into **dev (prod)** requires typing the database name + `yes`. Credentials are
typed, never stored.

Reference data (limits, app settings) is **seeded by the migrations themselves**,
not by a loader — see 028, 032 and 033.

### Copying plate data between environments

```
.\.venv\Scripts\python export_plate_from_prod.py      # READ-ONLY, writes export/*.csv
.\.venv\Scripts\python sync_plate_test_from_prod.py   # wipe + reload TEST from that export
```

The sync script **hard-refuses** to run against production and asks you to type
the row count before deleting anything.

## Adding changes later

Migrations are **append-only**. Do **not** edit an already-applied file — add the
next number (`034_…`) and run it against each environment.

Consequence: the current definition of a view or procedure lives in the **newest**
migration that touched it, not where it was created. For example `vw_ph_control`
is in 030, the plate views in 026, `vw_change_watermark` in 032. Always start from
the latest version when changing one.

## Safety model

- **No `USE`** (Azure SQL DB doesn't support it). Safety is *connection* + the
  `DB_NAME()` guard at the top of every migration.
- **Idempotent**: every script is safe to re-run; nothing drops data. The one
  destructive script, `sync_plate_test_from_prod.py`, refuses production outright.
- **dev = prod**: the loaders gate dev behind a typed confirmation; the migration
  guards stop a wrong-DB run.
- **Writes are procedure-only.** No table has `INSERT`/`UPDATE`/`DELETE` granted
  to `production_data_manager_role`; every write goes through a `qc.usp_*` proc.
  Reads are routed through `vw_*` views by *convention* — the role does hold
  `SELECT ON SCHEMA::[qc]`, so it can read tables directly. There are no `DENY`s.
- **No secrets in git**: the qc user password is typed at run time and the file
  closed without saving; `config/` is gitignored; loader credentials are typed.
- **Timestamps are Norway local** (`AT TIME ZONE 'W. Europe Standard Time'`) —
  Azure runs UTC, which would drift the today/yesterday edit windows at midnight.
- **Audit trail**: `qc.schema_migrations` records every migration that ran, in
  each database.
