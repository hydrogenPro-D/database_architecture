/* =====================================================================
 * 001_create_schema_qc.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: create the [qc] schema AND the [qc].[schema_migrations] ledger that
 *         every migration records itself into. Run this FIRST.
 * Safe to re-run (idempotent). Records itself in the ledger.
 *
 * Run it in SSMS / Azure Data Studio. Single batch on purpose: SSMS executes
 * GO-separated batches independently, so a guard in its own batch would NOT
 * stop the rest. Keeping everything in one batch means the THROW below aborts
 * the whole script on the wrong database.
 * ===================================================================== */

IF DB_NAME() NOT IN (N'dataloggingDev', N'dataloggingTest')
    THROW 50000, N'Refusing to run: not a datalogging database.', 1;

-- CREATE SCHEMA must normally be alone in its batch; EXEC sidesteps that so we
-- can keep this whole migration in a single batch.
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'qc')
    EXEC (N'CREATE SCHEMA [qc]');

-- The migration ledger. Each migration appends one row when it runs, so even
-- running a single file by hand keeps an audit trail of what ran where & when.
IF OBJECT_ID(N'[qc].[schema_migrations]', N'U') IS NULL
    CREATE TABLE [qc].[schema_migrations] (
        [id]             INT IDENTITY PRIMARY KEY,
        [filename]       NVARCHAR(260) NOT NULL UNIQUE,
        [applied_at_utc] DATETIME2     NOT NULL
                         CONSTRAINT [DF_schema_migrations_at] DEFAULT SYSUTCDATETIME(),
        [applied_by]     NVARCHAR(256) NOT NULL
                         CONSTRAINT [DF_schema_migrations_by] DEFAULT SUSER_SNAME()
    );

IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'001_create_schema_qc.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'001_create_schema_qc.sql');
GO
