/* =====================================================================
 * 013_add_change_polling.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: POLLING support (POLLING_AND_CHANGELOG_HANDOFF.md, Part 1):
 *     - row_version ROWVERSION on the 8 parent "log" tables AND on
 *       electrode_chemical_dosage (its watermark entity lives in the view below).
 *     - qc.vw_change_watermark: one row per UI tab = MAX(row_version)+COUNT(*),
 *       polled every few seconds so the app learns which tab changed without
 *       re-pulling the heavy pivot views.
 *   Idempotent (COL_LENGTH guards + CREATE OR ALTER). Run 001-012 first.
 *
 * §1.4 of the handoff (a child-only edit must still bump the parent's
 * row_version) is ALREADY satisfied: every usp_*_update in 006-010 re-writes its
 * parent log row's scalars before rebuilding children, so no proc changes here.
 *
 * ROWVERSION is auto-generated and can never be inserted -- load_data.py was
 * updated to skip timestamp columns so bulk reloads still work.
 *
 * Reads need no new grant: 002 granted SELECT ON SCHEMA::qc (covers the view).
 *
 * Multi-batch (CREATE VIEW must lead its batch) -> RAISERROR + SET NOEXEC.
 * ===================================================================== */

IF DB_NAME() NOT IN (N'dataloggingDev', N'dataloggingTest')
BEGIN
    RAISERROR(N'Refusing to run: not a datalogging database.', 16, 1);
    SET NOEXEC ON;
END;
GO
IF OBJECT_ID(N'[qc].[schema_migrations]', N'U') IS NULL
BEGIN
    RAISERROR(N'Run 001 first (creates the qc schema + ledger).', 16, 1);
    SET NOEXEC ON;
END;
GO

/* ---- 1. row_version on the 8 log tables + the dosage-rate log -------- */
/* Auto-maintained 8-byte counter; adding it stamps every existing row at once. */
IF COL_LENGTH(N'[qc].[ph_log]', N'row_version') IS NULL
    ALTER TABLE [qc].[ph_log]                        ADD [row_version] ROWVERSION NOT NULL;
IF COL_LENGTH(N'[qc].[chemical_addition_log]', N'row_version') IS NULL
    ALTER TABLE [qc].[chemical_addition_log]         ADD [row_version] ROWVERSION NOT NULL;
IF COL_LENGTH(N'[qc].[electrode_production_tracking]', N'row_version') IS NULL
    ALTER TABLE [qc].[electrode_production_tracking] ADD [row_version] ROWVERSION NOT NULL;
IF COL_LENGTH(N'[qc].[conductivity_log]', N'row_version') IS NULL
    ALTER TABLE [qc].[conductivity_log]              ADD [row_version] ROWVERSION NOT NULL;
IF COL_LENGTH(N'[qc].[cleaner_bath_log]', N'row_version') IS NULL
    ALTER TABLE [qc].[cleaner_bath_log]              ADD [row_version] ROWVERSION NOT NULL;
IF COL_LENGTH(N'[qc].[activator_bath_log]', N'row_version') IS NULL
    ALTER TABLE [qc].[activator_bath_log]            ADD [row_version] ROWVERSION NOT NULL;
IF COL_LENGTH(N'[qc].[strike_bath_log]', N'row_version') IS NULL
    ALTER TABLE [qc].[strike_bath_log]               ADD [row_version] ROWVERSION NOT NULL;
IF COL_LENGTH(N'[qc].[plate_bath_log]', N'row_version') IS NULL
    ALTER TABLE [qc].[plate_bath_log]                ADD [row_version] ROWVERSION NOT NULL;
IF COL_LENGTH(N'[qc].[electrode_chemical_dosage]', N'row_version') IS NULL
    ALTER TABLE [qc].[electrode_chemical_dosage]     ADD [row_version] ROWVERSION NOT NULL;
GO

/* ---- 2. consolidated watermark view (one row per UI tab) ------------- */
/* The app polls exactly: SELECT entity, max_row_version, row_count FROM this view.
 * entity keys are a stable contract -- do NOT rename without telling the app side.
 * Reads only the small parent tables; never touches the heavy pivot views. */
CREATE OR ALTER VIEW [qc].[vw_change_watermark] AS
SELECT 'ph_control'          AS entity,
       CONVERT(BIGINT, ISNULL(MAX(row_version), 0)) AS max_row_version,
       COUNT_BIG(*)          AS row_count
FROM [qc].[ph_log]
UNION ALL
SELECT 'adding_chemicals',   CONVERT(BIGINT, ISNULL(MAX(row_version), 0)), COUNT_BIG(*)
FROM [qc].[chemical_addition_log]
UNION ALL
SELECT 'production_tracking', CONVERT(BIGINT, ISNULL(MAX(row_version), 0)), COUNT_BIG(*)
FROM [qc].[electrode_production_tracking]
UNION ALL
SELECT 'conductivity',       CONVERT(BIGINT, ISNULL(MAX(row_version), 0)), COUNT_BIG(*)
FROM [qc].[conductivity_log]
UNION ALL
SELECT 'cleaner',            CONVERT(BIGINT, ISNULL(MAX(row_version), 0)), COUNT_BIG(*)
FROM [qc].[cleaner_bath_log]
UNION ALL
SELECT 'activator',          CONVERT(BIGINT, ISNULL(MAX(row_version), 0)), COUNT_BIG(*)
FROM [qc].[activator_bath_log]
UNION ALL
SELECT 'strike',             CONVERT(BIGINT, ISNULL(MAX(row_version), 0)), COUNT_BIG(*)
FROM [qc].[strike_bath_log]
-- Plate is one table but three UI tabs (Vat 28/29/30): split by vat.
UNION ALL
SELECT 'plate_28', CONVERT(BIGINT, ISNULL(MAX(l.row_version), 0)), COUNT_BIG(*)
FROM [qc].[plate_bath_log] l JOIN [qc].[vat] v ON v.id = l.vat_id WHERE v.name = 'Vat. 28'
UNION ALL
SELECT 'plate_29', CONVERT(BIGINT, ISNULL(MAX(l.row_version), 0)), COUNT_BIG(*)
FROM [qc].[plate_bath_log] l JOIN [qc].[vat] v ON v.id = l.vat_id WHERE v.name = 'Vat. 29'
UNION ALL
SELECT 'plate_30', CONVERT(BIGINT, ISNULL(MAX(l.row_version), 0)), COUNT_BIG(*)
FROM [qc].[plate_bath_log] l JOIN [qc].[vat] v ON v.id = l.vat_id WHERE v.name = 'Vat. 30'
-- dosage-rate change log (see 014), so its history panel can auto-refresh too.
UNION ALL
SELECT 'chemical_change_log', CONVERT(BIGINT, ISNULL(MAX(row_version), 0)), COUNT_BIG(*)
FROM [qc].[electrode_chemical_dosage];
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'013_add_change_polling.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'013_add_change_polling.sql');
GO

SET NOEXEC OFF;
GO
