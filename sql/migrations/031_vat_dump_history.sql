/* =====================================================================
 * 031_vat_dump_history.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: VAT_DUMP_HISTORY_DB_SPEC.md -- record when plating baths 28/29/30 were
 *   dumped, so the log can be read in the app and the acid calculator can tell
 *   that a bath's own additions predate a dump.
 *     1. qc.vat_dump_log (+ index on (vat_id, dumped_at DESC))
 *     2. qc.vw_vat_dump_28 / _29 / _30   -- one per tab, vat is the filter
 *     3. qc.vw_vat_dump_latest           -- last dump per vat, by name
 *     4. three vat_dump_* entities in qc.vw_change_watermark
 *     5. usp_vat_dump_insert (returns the new id) / _update / _delete
 *   Idempotent (OBJECT_ID / index guards + CREATE OR ALTER). Run 001-030 first.
 *   Nothing on the plate bath tables or views is touched.
 *
 * ONE COLUMN THE SPEC DID NOT LIST: row_version
 * ---------------------------------------------
 * Section 5 asks for watermark entities, and vw_change_watermark is built from
 * MAX(row_version) + COUNT_BIG(*). So vat_dump_log carries a ROWVERSION like
 * every other polled table (migration 013). Without it the three new entities
 * could not report max_row_version and the tabs would never auto-refresh.
 *
 * SECTION 6, PERMISSIONS -- ONE CORRECTION
 * ----------------------------------------
 * The spec says the login "must not have any rights on qc.vat_dump_log directly;
 * every other table is reached only through its procedures". That is not how this
 * database is actually set up: migration 002 granted SELECT ON SCHEMA::[qc],
 * which covers EVERY table in the schema, this one included. Reads are routed
 * through views by convention, not by permission, and WRITES are what is
 * genuinely proc-only (no table has INSERT/UPDATE/DELETE granted).
 * So this migration grants EXECUTE on the three procedures and nothing else:
 *   - the four views need no grant, SCHEMA::qc already covers them;
 *   - vat_dump_log is readable exactly like ph_log, plate_bath_log and the rest.
 * Making it genuinely unreadable would need an explicit
 *     DENY SELECT ON OBJECT::[qc].[vat_dump_log] TO [production_data_manager_role];
 * which would make it the only table in the schema treated that way. Say the word
 * if that is really wanted; it is deliberately NOT done here.
 *
 * GUARD WORDING
 * -------------
 * The spec quotes 'Only entries from today or yesterday can be edited. (50004)'.
 * That was the wording before migration 018; every update procedure now says
 * 'Only rows created today or yesterday can be edited.' Since the spec's stated
 * intent is "the same message the other update procedures use", the CURRENT
 * house wording is used. The error CODES are what the app maps and they are
 * unchanged: 50004 edit, 50003 delete, 50002 not found, 50005 unknown vat.
 *
 * created_at is NOT NULL here (the spec's shape), so unlike the measurement logs
 * there is no NULL "pre-feature history" that is permanently locked -- every row
 * is editable for its first two days and read-only after.
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
IF OBJECT_ID(N'[qc].[vat]', N'U') IS NULL
BEGIN
    RAISERROR(N'Run 004 first (creates qc.vat).', 16, 1);
    SET NOEXEC ON;
END;
GO

/* ---- 1. the log ----------------------------------------------------- */
/* The vat is a foreign key, never a name repeated in another table -- the same
 * way qc.measurement_section references it. The PROCEDURES still take the vat by
 * NAME and resolve it here, because the app has never held a vat id.
 * dumped_at is ONE value: a dump is a moment, not a measurement made on a day. */
IF OBJECT_ID(N'[qc].[vat_dump_log]', N'U') IS NULL
CREATE TABLE [qc].[vat_dump_log] (
    [vat_dump_log_id] INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    [vat_id]          INT NOT NULL
        CONSTRAINT [FK_vat_dump_log_vat] REFERENCES [qc].[vat]([id]),
    [dumped_at]       DATETIME2(0)  NOT NULL,     -- the day and time of the dump
    [initials]        VARCHAR(16)   NULL,
    [comment]         NVARCHAR(500) NULL,
    [created_at]      DATETIME2(0)  NOT NULL      -- "Row added"; never updated
        CONSTRAINT [DF_vat_dump_log_created_at]
        DEFAULT (CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATETIME2(0))),
    [row_version]     ROWVERSION    NOT NULL      -- feeds vw_change_watermark
);
GO

/* Serves both the per-vat views and vw_vat_dump_latest. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_vat_dump_log_vat_dumped_at'
                 AND object_id = OBJECT_ID(N'[qc].[vat_dump_log]'))
    CREATE NONCLUSTERED INDEX [IX_vat_dump_log_vat_dumped_at]
        ON [qc].[vat_dump_log] ([vat_id], [dumped_at] DESC);
GO

/* ---- 2. one view per tab -------------------------------------------- */
/* The id MUST be column 1: the app maps a table row back to its id by position
 * (ORDER BY [Time of dump], 1). Both timestamps stay DATETIME2 -- the app
 * formats them dd.MM.yyyy HH:mm itself and needs them sortable.
 * The vat is the filter, not a column. */
CREATE OR ALTER VIEW [qc].[vw_vat_dump_28] AS
SELECT
    d.[vat_dump_log_id] AS vat_dump_log_id,
    d.[created_at]      AS [Row added],
    d.[dumped_at]       AS [Time of dump],
    d.[initials]        AS [Initials],
    d.[comment]         AS [Comment]
FROM [qc].[vat_dump_log] d
JOIN [qc].[vat] v ON v.id = d.[vat_id]
WHERE v.name = 'Vat. 28';
GO

CREATE OR ALTER VIEW [qc].[vw_vat_dump_29] AS
SELECT
    d.[vat_dump_log_id] AS vat_dump_log_id,
    d.[created_at]      AS [Row added],
    d.[dumped_at]       AS [Time of dump],
    d.[initials]        AS [Initials],
    d.[comment]         AS [Comment]
FROM [qc].[vat_dump_log] d
JOIN [qc].[vat] v ON v.id = d.[vat_id]
WHERE v.name = 'Vat. 29';
GO

CREATE OR ALTER VIEW [qc].[vw_vat_dump_30] AS
SELECT
    d.[vat_dump_log_id] AS vat_dump_log_id,
    d.[created_at]      AS [Row added],
    d.[dumped_at]       AS [Time of dump],
    d.[initials]        AS [Initials],
    d.[comment]         AS [Comment]
FROM [qc].[vat_dump_log] d
JOIN [qc].[vat] v ON v.id = d.[vat_id]
WHERE v.name = 'Vat. 30';
GO

/* ---- 3. last dump per vat, by name ---------------------------------- */
/* Three values for the acid calculator to read on every data load, instead of
 * pulling three logs it does not otherwise need. A vat never dumped is simply
 * absent, which the app treats the same as "not recently dumped". */
CREATE OR ALTER VIEW [qc].[vw_vat_dump_latest] AS
SELECT
    v.name            AS vat,
    MAX(d.[dumped_at]) AS last_dump
FROM [qc].[vat_dump_log] d
JOIN [qc].[vat] v ON v.id = d.[vat_id]
GROUP BY v.name;
GO

/* ---- 4. watermark: reproduce 022's view + three vat_dump entities ---- */
/* entity keys are a stable contract with the app -- do NOT rename. */
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
UNION ALL
SELECT 'plate_28', CONVERT(BIGINT, ISNULL(MAX(l.row_version), 0)), COUNT_BIG(*)
FROM [qc].[plate_bath_log] l JOIN [qc].[vat] v ON v.id = l.vat_id WHERE v.name = 'Vat. 28'
UNION ALL
SELECT 'plate_29', CONVERT(BIGINT, ISNULL(MAX(l.row_version), 0)), COUNT_BIG(*)
FROM [qc].[plate_bath_log] l JOIN [qc].[vat] v ON v.id = l.vat_id WHERE v.name = 'Vat. 29'
UNION ALL
SELECT 'plate_30', CONVERT(BIGINT, ISNULL(MAX(l.row_version), 0)), COUNT_BIG(*)
FROM [qc].[plate_bath_log] l JOIN [qc].[vat] v ON v.id = l.vat_id WHERE v.name = 'Vat. 30'
UNION ALL
SELECT 'chemical_change_log', CONVERT(BIGINT, ISNULL(MAX(row_version), 0)), COUNT_BIG(*)
FROM [qc].[electrode_chemical_dosage]
UNION ALL
SELECT 'water_quality',      CONVERT(BIGINT, ISNULL(MAX(row_version), 0)), COUNT_BIG(*)
FROM [qc].[water_quality_log]
UNION ALL
SELECT 'contamination',      CONVERT(BIGINT, ISNULL(MAX(row_version), 0)), COUNT_BIG(*)
FROM [qc].[contamination_log]
-- NEW: one per plating tab's dumping history
UNION ALL
SELECT 'vat_dump_28', CONVERT(BIGINT, ISNULL(MAX(d.row_version), 0)), COUNT_BIG(*)
FROM [qc].[vat_dump_log] d JOIN [qc].[vat] v ON v.id = d.vat_id WHERE v.name = 'Vat. 28'
UNION ALL
SELECT 'vat_dump_29', CONVERT(BIGINT, ISNULL(MAX(d.row_version), 0)), COUNT_BIG(*)
FROM [qc].[vat_dump_log] d JOIN [qc].[vat] v ON v.id = d.vat_id WHERE v.name = 'Vat. 29'
UNION ALL
SELECT 'vat_dump_30', CONVERT(BIGINT, ISNULL(MAX(d.row_version), 0)), COUNT_BIG(*)
FROM [qc].[vat_dump_log] d JOIN [qc].[vat] v ON v.id = d.vat_id WHERE v.name = 'Vat. 30';
GO

/* ---- 5. insert (returns the new id) --------------------------------- */
CREATE OR ALTER PROCEDURE [qc].[usp_vat_dump_insert]
    @vat          NVARCHAR(255),
    @time_of_dump DATETIME2(0),
    @initials     VARCHAR(16)   = NULL,
    @comment      NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @time_of_dump IS NULL THROW 50001, N'Time of dump is required.', 1;

    DECLARE @vat_id INT = (SELECT [id] FROM [qc].[vat] WHERE [name] = @vat), @msg NVARCHAR(300);
    IF @vat_id IS NULL BEGIN SET @msg = CONCAT(N'Unknown vat: ', @vat); THROW 50005, @msg, 1; END

    -- created_at is stamped by the column DEFAULT (Norway local) -- not set here.
    INSERT INTO [qc].[vat_dump_log] ([vat_id], [dumped_at], [initials], [comment])
    VALUES (@vat_id, @time_of_dump, @initials, @comment);

    SELECT CAST(SCOPE_IDENTITY() AS INT) AS vat_dump_log_id;   -- app reads fetchone()[0]
END
GO

/* ---- 6. update (today/yesterday guard on created_at) ---------------- */
CREATE OR ALTER PROCEDURE [qc].[usp_vat_dump_update]
    @vat_dump_log_id INT,
    @vat             NVARCHAR(255),
    @time_of_dump    DATETIME2(0),
    @initials        VARCHAR(16)   = NULL,
    @comment         NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @time_of_dump IS NULL THROW 50001, N'Time of dump is required.', 1;

    -- Judged on created_at, NOT on dumped_at: a dump entered today for a date
    -- last week is still a row created today, and the app will offer the edit.
    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    IF NOT EXISTS (SELECT 1 FROM [qc].[vat_dump_log] WHERE [vat_dump_log_id] = @vat_dump_log_id)
        THROW 50002, N'vat_dump_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[vat_dump_log]
                              WHERE [vat_dump_log_id] = @vat_dump_log_id);
    IF @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50004, N'Only rows created today or yesterday can be edited.', 1;

    DECLARE @vat_id INT = (SELECT [id] FROM [qc].[vat] WHERE [name] = @vat), @msg NVARCHAR(300);
    IF @vat_id IS NULL BEGIN SET @msg = CONCAT(N'Unknown vat: ', @vat); THROW 50005, @msg, 1; END

    UPDATE [qc].[vat_dump_log]
       SET [vat_id]    = @vat_id,
           [dumped_at] = @time_of_dump,
           [initials]  = @initials,
           [comment]   = @comment
     WHERE [vat_dump_log_id] = @vat_dump_log_id;   -- created_at intentionally untouched
END
GO

/* ---- 7. delete (same guard; a real delete, no soft delete) ---------- */
CREATE OR ALTER PROCEDURE [qc].[usp_vat_dump_delete]
    @vat_dump_log_id INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    IF NOT EXISTS (SELECT 1 FROM [qc].[vat_dump_log] WHERE [vat_dump_log_id] = @vat_dump_log_id)
        THROW 50002, N'vat_dump_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[vat_dump_log]
                              WHERE [vat_dump_log_id] = @vat_dump_log_id);
    IF @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50003, N'Only rows created today or yesterday can be deleted.', 1;

    DELETE FROM [qc].[vat_dump_log] WHERE [vat_dump_log_id] = @vat_dump_log_id;
END
GO

/* ---- grants: the three procedures only ------------------------------ */
/* The four views need none: 002 granted SELECT ON SCHEMA::qc. See the header on
 * why qc.vat_dump_log is NOT denied. */
GRANT EXECUTE ON OBJECT::[qc].[usp_vat_dump_insert] TO [production_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_vat_dump_update] TO [production_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_vat_dump_delete] TO [production_data_manager_role];
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'031_vat_dump_history.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'031_vat_dump_history.sql');
GO

SET NOEXEC OFF;
GO
