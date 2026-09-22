# SQL Migration System — Implementation Playbook

A lightweight, **manual** database-migration convention for **Azure SQL Database**
(also works on SQL Server / Managed Instance). No framework, no runner required:
just ordered `.sql` files you run by hand in SSMS / Azure Data Studio. It gives you
idempotency, a wrong-database guard, and a self-maintained audit trail.

Hand this document to an AI (or a human) and ask them to apply these conventions
to a project. Replace the placeholders in **angle brackets**.

---

## Goals

1. **Identical structure across environments** (e.g. `<prod-db>` and `<test-db>`)
   by running the same files against each.
2. **Idempotent** — every file is safe to re-run; nothing is dropped, nothing
   duplicated.
3. **Wrong-DB protection** — a file aborts if run against an unexpected database.
4. **Audit trail** — each file records itself, so you always know what ran where.
5. **No secrets in source control.**

---

## Conventions

- One folder, e.g. `sql/migrations/`.
- Files are **zero-padded, numbered, descriptive**, applied in filename order:
  ```
  001_create_schema_and_ledger.sql
  002_create_role_<role>.sql
  003_create_user_<user>.sql
  004_create_<area>_tables.sql
  005_...
  ```
- **Append-only.** Never edit a file that has already been applied anywhere — add
  a new numbered file instead. (Editing applied history is how you get drift.)
- Pick a schema to own everything, e.g. `<schema>` (and the ledger lives in it).

---

## Rule 1 — every file is a SINGLE batch (no `GO` in the middle)

**Why this matters:** SSMS sends each `GO`-separated batch to the server
*independently* and, by default, **continues to the next batch even if one
fails**. So a guard like `IF DB_NAME() <> ... THROW` placed in its own batch will
throw *and then the rest of the file runs anyway*. Keeping the whole file in ONE
batch means a single `THROW` aborts everything.

Consequence: anything that "must be the only statement in its batch" (e.g.
`CREATE SCHEMA`) must be run via dynamic SQL `EXEC('...')` so it doesn't force a
batch break.

Put a single `GO` only at the very end of the file.

---

## Rule 2 — guard the database at the top of every file

```sql
IF DB_NAME() NOT IN (N'<prod-db>', N'<test-db>')
    THROW 50000, N'Refusing to run: not an expected database.', 1;
```

Azure SQL Database has **no `USE`** — you can't switch databases in a script. You
connect to the target DB, and this guard is what stops a wrong-DB run.

Non-bootstrap files should also fail fast if the ledger is missing:

```sql
IF OBJECT_ID(N'[<schema>].[schema_migrations]', N'U') IS NULL
    THROW 50000, N'Run 001 first (creates the schema + ledger).', 1;
```

---

## Rule 3 — the migration ledger (created by file 001)

The first migration creates the schema and the ledger table the others record into.
Keeping everything in one batch (note the `EXEC` for `CREATE SCHEMA`):

```sql
IF DB_NAME() NOT IN (N'<prod-db>', N'<test-db>')
    THROW 50000, N'Refusing to run: not an expected database.', 1;

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'<schema>')
    EXEC (N'CREATE SCHEMA [<schema>]');

IF OBJECT_ID(N'[<schema>].[schema_migrations]', N'U') IS NULL
    CREATE TABLE [<schema>].[schema_migrations] (
        [id]             INT IDENTITY PRIMARY KEY,
        [filename]       NVARCHAR(260) NOT NULL UNIQUE,
        [applied_at_utc] DATETIME2     NOT NULL
                         CONSTRAINT [DF_schema_migrations_at] DEFAULT SYSUTCDATETIME(),
        [applied_by]     NVARCHAR(256) NOT NULL
                         CONSTRAINT [DF_schema_migrations_by] DEFAULT SUSER_SNAME()
    );

IF NOT EXISTS (SELECT 1 FROM [<schema>].[schema_migrations]
               WHERE filename = N'001_create_schema_and_ledger.sql')
    INSERT INTO [<schema>].[schema_migrations] (filename)
    VALUES (N'001_create_schema_and_ledger.sql');
GO
```

Check progress anytime: `SELECT * FROM <schema>.schema_migrations ORDER BY id;`

---

## Rule 4 — every file self-records (last thing it does)

```sql
IF NOT EXISTS (SELECT 1 FROM [<schema>].[schema_migrations]
               WHERE filename = N'<THIS_EXACT_FILENAME>.sql')
    INSERT INTO [<schema>].[schema_migrations] (filename)
    VALUES (N'<THIS_EXACT_FILENAME>.sql');
GO
```

The `filename` string must match the actual file name exactly.

---

## Rule 5 — idempotency cheat-sheet (only create if absent)

```sql
-- schema (via EXEC so it doesn't need its own batch)
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'<schema>')
    EXEC (N'CREATE SCHEMA [<schema>]');

-- table
IF OBJECT_ID(N'[<schema>].[<table>]', N'U') IS NULL
    CREATE TABLE [<schema>].[<table>] ( ... );

-- column (add if missing)
IF COL_LENGTH(N'[<schema>].[<table>]', N'<column>') IS NULL
    ALTER TABLE [<schema>].[<table>] ADD [<column>] <type> NULL;

-- role
IF NOT EXISTS (SELECT 1 FROM sys.database_principals
               WHERE name = N'<role>' AND type = 'R')
    CREATE ROLE [<role>];

-- contained user (see Rule 6 for the password)
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'<user>')
    EXEC (N'CREATE USER [<user>] WITH PASSWORD = N''' + @escaped_pw + N'''');

-- role membership
IF NOT EXISTS (
    SELECT 1 FROM sys.database_role_members rm
    JOIN sys.database_principals r ON rm.role_principal_id   = r.principal_id
    JOIN sys.database_principals m ON rm.member_principal_id = m.principal_id
    WHERE r.name = N'<role>' AND m.name = N'<user>')
    ALTER ROLE [<role>] ADD MEMBER [<user>];

-- index
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'<index>' AND object_id = OBJECT_ID(N'[<schema>].[<table>]'))
    CREATE INDEX [<index>] ON [<schema>].[<table>] ([<column>]);

-- GRANT is naturally idempotent -- just run it:
GRANT SELECT ON SCHEMA::[<schema>] TO [<role>];
```

---

## Rule 6 — secrets are typed at run time, never saved

For statements needing a password (e.g. `CREATE USER ... WITH PASSWORD`):

```sql
DECLARE @pw NVARCHAR(128) = N'<<SET_PASSWORD_HERE_THEN_DO_NOT_SAVE>>';

IF @pw LIKE N'%<<%' OR @pw LIKE N'%>>%' OR LEN(@pw) < 8
    THROW 50000, N'Set a real password before running this file.', 1;

-- WITH PASSWORD needs a literal, and EXEC() cannot contain function calls,
-- so escape into a variable FIRST, then EXEC the variable.
DECLARE @sql NVARCHAR(MAX) =
    N'CREATE USER [<user>] WITH PASSWORD = N'''
    + REPLACE(@pw, N'''', N'''''') + N'''';
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'<user>')
    EXEC (@sql);
```

Workflow: type the password into `@pw`, run the file, **close it without saving**.
The committed file keeps only the placeholder, and the guard throws if you forget.

Two gotchas this encodes:
- `EXEC(...)` accepts only concatenated **string literals + variables** — NOT
  function calls. Do the `REPLACE` escaping in a variable assignment, then `EXEC`
  the variable.
- `REPLACE(@pw, '''', '''''')` doubles single quotes so the password can't break
  out of the string literal.

---

## How to run (manual)

1. Connect SSMS / Azure Data Studio to the **target database**.
2. Open and run the migration files **in order** (`001`, `002`, ...).
3. For any file with a password, set it, run, and don't save.
4. `SELECT * FROM <schema>.schema_migrations ORDER BY id;` to confirm.
5. Repeat against the other environment. Apply to **test first**, prod last.

---

## Azure SQL Database caveats (EngineEdition = 5)

- **No `USE`** — connect per database; rely on the `DB_NAME()` guard.
- **Contained users** (`CREATE USER ... WITH PASSWORD`) instead of server logins,
  if you want each DB self-contained.
- **`CREATE DATABASE`** is a separate one-off against `master` (or via the portal),
  not part of these per-database migrations.
- **`BULK INSERT` cannot read local files** — load data from Azure Blob, or load
  client-side through a driver (e.g. Python + pyodbc) instead.

---

## What you are NOT getting (and why that's fine here)

- No automatic ordering/skip engine — you run files yourself; numbering + the
  ledger make state obvious.
- No hash/drift detection — that needs automation. The append-only rule plus
  "never edit applied files" covers it manually.

If a project outgrows this (many migrations, frequent applies, CI, a team),
graduate to a real tool (Flyway, DbUp, sqlpackage/DACPAC). For a small,
occasionally-changed schema, this convention is enough.
