# Migration overview — current state

A snapshot of what exists: databases, folders, the ledger, the 33 migrations and
the permission model.

Companion docs, not duplicated here:
**`MIGRATION_PLAYBOOK.md`** (the rules for writing one) ·
**`README.md`** (how to run them) ·
**`DB_HANDOFF.md`** (the original data contract).

---

## Databases

| Menu name | Database | Role |
|---|---|---|
| `test` | `dataloggingTest` | test |
| `dev` | **`dataloggingDev`** | **PRODUCTION** |

> **"dev" is production.** `db_common.PROD_DATABASES = {"dataloggingDev"}`, and
> every script tags it `<-- PRODUCTION` in its menu. This is the easiest thing in
> the repo to get wrong.

Azure SQL, ODBC Driver 18. Schema is **`qc`** (the server also carries `dbo` and
`qc_data`). Every migration begins with a guard refusing to run anywhere but
those two databases.

---

## Folders

```
database_architecture/
├─ sql/migrations/     33 numbered migrations  <- the source of truth
├─ sql/maintenance/    measure_view_runtimes.sql, reset_qc_tables_TEST_ONLY.sql
├─ db_tables/          the original 21 handoff CSVs
├─ data/               contamination_log.csv
├─ plate_cobalt/       the 4 cobalt CSVs
├─ export/             prod exports + the weekly result scheme workbook
├─ config/             config.json — credentials, gitignored
└─ Draw DB/            drawdb exports, consumed by generate_mssql.py
```

**Scripts:** `db_common.py` (shared prompts + connection), `load_data.py` (the 21
CSVs), `generate_mssql.py` (drawdb → migration 004), and the one-offs:
`load_contamination_data.py`, `export_plate_from_prod.py`,
`sync_plate_test_from_prod.py`, `load_plate_cobalt_data.py`.

---

## The ledger

```sql
qc.schema_migrations
    id              int IDENTITY PRIMARY KEY
    filename        nvarchar(260) NOT NULL UNIQUE
    applied_at_utc  datetime2     NOT NULL DEFAULT SYSUTCDATETIME()
    applied_by      nvarchar(256) NOT NULL DEFAULT SUSER_SNAME()
```

Created by 001. Every migration self-records as its last statement, `IF NOT
EXISTS`-guarded; `filename` is UNIQUE so double-recording is impossible.

```sql
SELECT filename, applied_at_utc FROM qc.schema_migrations ORDER BY id;
```

**Sharp edge:** the ledger insert is its own batch, so a **parse** error earlier
in a multi-batch file kills only that batch and the ledger can get ahead of the
data (this happened with 028). Runtime errors are caught by the `SET NOEXEC ON`
guards; parse errors are not. If a migration errors, check the data landed, then
re-run the corrected file — they are all idempotent.

---

## Conventions in force

* `NNN_lowercase_description.sql`, applied in order.
* **Idempotent**: `OBJECT_ID` / `COL_LENGTH` / `sys.indexes` guards, `NOT EXISTS`
  seeds, `CREATE OR ALTER` for views and procedures.
* **Applied migrations are frozen.** Changes go in a new number. Consequence: the
  current definition of a view or procedure lives in the newest migration that
  touched it, *not* where it was created — e.g. `vw_ph_control` → 030, the plate
  views → 026, `vw_change_watermark` → 032.
* **Timestamps are Norway local** (`AT TIME ZONE 'W. Europe Standard Time'`).
  Azure runs UTC, which would drift the today/yesterday edit windows at midnight.
* Single-batch files use `THROW`; multi-batch files (anything containing
  `CREATE VIEW` / `CREATE PROCEDURE`, which must lead a batch) use `RAISERROR` +
  `SET NOEXEC ON` … `SET NOEXEC OFF`, because SSMS runs batches independently.

> Note: `MIGRATION_PLAYBOOK.md` Rule 1 says every file is a single batch. That
> held early on; from 013 onward most files are multi-batch, using the
> `RAISERROR` + `SET NOEXEC` pattern above. The playbook's other rules still apply.

---

## The 33 migrations

| Range | What |
|---|---|
| 001–003 | schema + ledger, role, contained user |
| 004–005 | tables (generated from drawdb), views |
| 006–010 | CRUD procedures per entity |
| 011–018 | cobalt dosing, view indexes, change polling, dosage change log, fixes, `created_at`/`[Row added]`, edit guards |
| **019** | rename role + user to `production_*` |
| 020–023 | water quality, contamination (each + a notes column) |
| 024 | read access on `dbo` |
| 025–027 | plate cobalt split, nickel label split, production-tracking `[Row added]` |
| 028–029 | measurement limits (append-only), then create + delete |
| 030–033 | pH before/after reading, vat dump history, app settings, contamination limit seed |

**State:** production was at **032** at the time of writing; **033 is written and
unapplied on both databases**. Confirm with the ledger query above.

---

## Permissions

**Role** `production_data_manager_role` ← **user** `db_production_data_manager_user`
(a contained user with its own password, no server login). Both were renamed from
`qc_*` in migration 019.

| Grant | Added by | Covers |
|---|---|---|
| `SELECT ON SCHEMA::[qc]` | 002 | **all** tables *and* views, including ones added later |
| `SELECT ON SCHEMA::[dbo]` | 024 | read-only on dbo |
| `EXECUTE ON OBJECT::…` | each migration | one explicit grant per procedure |

### The model, stated precisely

Reads are routed through views by **convention**, not by permission — the role
can read every table directly. What is genuinely locked down is **writes**: no
table anywhere has `INSERT` / `UPDATE` / `DELETE` granted, so every write goes
through a stored procedure. There are **no `DENY`s** in the database.

This matters because more than one spec has asserted the opposite ("every other
table is reached only through its procedures"). It is not true, and anything
built on that assumption needs rechecking. See `VAT_DUMP_HANDOFF.md` §6 and the
header of `031_vat_dump_history.sql`.

### Error codes used by the procedures

| Code | Meaning |
|---|---|
| 50001 | a required date/time is missing |
| 50002 | id / key not found |
| 50003 | only rows created today or yesterday can be **deleted** |
| 50004 | only rows created today or yesterday can be **edited** |
| 50005 | unknown vat name |
| 50006 | payload is not valid JSON |
| 50007 | `measured_by` is required |
| 50008 | `line` is required (contamination) |
| 50009 | stale write / already exists — optimistic concurrency |
| 50010 | a required value is empty |
| 50011 | threshold shape invalid |

The application matches on the **code**, never the message.
