/* =====================================================================
 * 014_add_dosage_change_log.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: dosage-rate change log app surface (POLLING_AND_CHANGELOG_HANDOFF.md,
 *         Part 2) -- moves config/chemicals_log.csv onto the DB. The table
 *         electrode_chemical_dosage already exists (co_value added in 011,
 *         row_version added in 013); this only adds the read + write surface:
 *     - qc.vw_electrode_chemical_dosage: read view, splits DATETIME2 -> date/time
 *     - qc.usp_electrode_chemical_dosage_insert: append-only insert (+EXECUTE grant)
 *   Idempotent via CREATE OR ALTER. Run 001-013 first.
 *
 * Append-only in the app -- no update/delete proc (a mistake is corrected with a
 * new appended row, matching the old CSV's behaviour).
 *
 * Reads need no new grant: 002 granted SELECT ON SCHEMA::qc (covers the view).
 * Only the proc needs an explicit GRANT EXECUTE.
 *
 * Multi-batch (CREATE VIEW/PROCEDURE must lead its batch) -> RAISERROR + SET NOEXEC.
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

/* ---- 1. read view: split the DATETIME2 back into date + time -------- */
/* Unordered like every qc view -- app applies ORDER BY [date], [time], id. */
CREATE OR ALTER VIEW [qc].[vw_electrode_chemical_dosage] AS
SELECT
    id,
    CONVERT(date, [date]) AS [date],   -- 'YYYY-MM-DD'
    CONVERT(time, [date]) AS [time],   -- 'HH:MM:SS'
    name,
    tu_value,
    ba_value,
    co_value
FROM [qc].[electrode_chemical_dosage];
GO

/* ---- 2. append-only insert proc ------------------------------------- */
CREATE OR ALTER PROCEDURE [qc].[usp_electrode_chemical_dosage_insert]
    @date     DATETIME2,             -- full timestamp (date + time of the change)
    @name     NVARCHAR(255),
    @tu_value INT,
    @ba_value INT,
    @co_value INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    INSERT INTO [qc].[electrode_chemical_dosage] ([date], name, tu_value, ba_value, co_value)
    VALUES (@date, @name, @tu_value, @ba_value, @co_value);

    SELECT CAST(SCOPE_IDENTITY() AS INT) AS id;   -- new row id for the caller
END
GO

/* ---- grant: only the new proc (view rides the schema-wide SELECT) ---- */
GRANT EXECUTE ON OBJECT::[qc].[usp_electrode_chemical_dosage_insert] TO [qc_data_manager_role];
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'014_add_dosage_change_log.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'014_add_dosage_change_log.sql');
GO

SET NOEXEC OFF;
GO
