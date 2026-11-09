/* =====================================================================
 * 022_create_contamination.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: NEW "Contamination Log" tab (CONTAMINATION_DB_SPEC.md) -- foreign-metal
 *   analysis, a parent/child event entity (one log row per sampling date fans out
 *   to many (vat, metal, value) readings). Adds:
 *     1. qc.contamination_log (parent, created_at "Row added" + row_version)
 *        + qc.contamination_measurement (child, one row per reading).
 *     2. qc.vw_contamination -- wide pivot, id first, filtered to Plating Line 1,
 *        exact 20 [Pos.xx Metal] columns.
 *     3. usp_contamination_insert (returns id) / _update / _delete -- children
 *        passed as a JSON @measurements array (OPENJSON), so vat/metal sets can
 *        change without a signature change.
 *     4. a 'contamination' branch in qc.vw_change_watermark (polling).
 *     5. GRANT EXECUTE on the 3 procs to the data-manager role.
 *   Idempotent (OBJECT_ID guards + CREATE OR ALTER). Run 001-021 first.
 *
 * value is TEXT on purpose (NVARCHAR): readings mix numbers with censored/
 * qualitative markers ('<2', '<0.01', '*', 'N/A') -- never coerce to numeric.
 *
 * The [line] column lets the R&D Plating Line analysis drop in later (its own vats
 * + a second Line-filtered view) with no structural change. This migration ships
 * Line 1 only.
 *
 * Same 4 house conventions as water_quality (020), all deliberate vs the spec's
 * literal SQL:
 *   a) created_at stamped NORWAY LOCAL via column DEFAULT (017), not SYSDATETIME()
 *      (= UTC on Azure); the insert proc does NOT set it. UPDATE never touches it.
 *   b) _update/_delete enforce the created_at today/yesterday EDIT GUARD (018) --
 *      keyed on when the ROW was added, not on sampling_date. Defense-in-depth,
 *      matching every sibling entity. (Delete the guard blocks to drop it.)
 *   c) grants go to [production_data_manager_role] (the 019 rename).
 *   d) the view needs no SELECT grant: 002 granted SELECT ON SCHEMA::qc.
 *
 * NOT included: the optional qc.contamination_limit table (spec 6) -- limits stay
 * in the app (ContaminationProcessor.CRITICAL_UPPER). Say the word to add it.
 *
 * Run this file UTF-8. Multi-batch (CREATE TABLE w/ FK is fine inline, but
 * CREATE VIEW/PROCEDURE must lead its batch) -> RAISERROR + SET NOEXEC.
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

/* ---- 1. tables ------------------------------------------------------ */
/* Parent: created_at Norway-local DEFAULT (auto-stamp) + row_version for polling. */
IF OBJECT_ID(N'[qc].[contamination_log]', N'U') IS NULL
    CREATE TABLE [qc].[contamination_log] (
        [id]              INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        [line]            NVARCHAR(50)  NOT NULL,       -- 'Plating Line 1' | 'R&D Plating Line'
        [sampling_date]   DATE          NOT NULL,
        [sample_taken_by] NVARCHAR(100) NULL,           -- free text, may be NULL
        [created_at]      DATETIME2(0)  NULL            -- "Row added"
            CONSTRAINT [DF_contamination_log_created_at]
            DEFAULT (CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATETIME2(0))),
        [row_version]     ROWVERSION    NOT NULL
    );
GO

/* Child: one row per (vat, metal) reading; value kept verbatim as text. */
IF OBJECT_ID(N'[qc].[contamination_measurement]', N'U') IS NULL
    CREATE TABLE [qc].[contamination_measurement] (
        [id]                   INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        [contamination_log_id] INT NOT NULL
            CONSTRAINT [FK_contamination_measurement_log]
            REFERENCES [qc].[contamination_log](id),
        [vat]                  NVARCHAR(20) NOT NULL,   -- 'Pos.28' .. 'Pos.31'
        [metal]                NVARCHAR(4)  NOT NULL,   -- 'Cr','Cu','Fe','Zn','Pb'
        [value]                NVARCHAR(30) NULL        -- verbatim: '2.5','<2','*','N/A'...
    );
GO

/* FK-join index (parent id is the view join + delete key; child grows fast). */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_contamination_measurement_log_id'
                 AND object_id = OBJECT_ID(N'[qc].[contamination_measurement]'))
    CREATE NONCLUSTERED INDEX [IX_contamination_measurement_log_id]
        ON [qc].[contamination_measurement] (contamination_log_id);
GO

/* ---- 2. wide view (Plating Line 1) ---------------------------------- */
/* id MUST stay column 1. Sampling date kept a real DATE for chronological sort.
 * Exact 20 [Pos.xx Metal] column names (space between vat and metal). */
CREATE OR ALTER VIEW [qc].[vw_contamination] AS
SELECT
    l.id              AS id,                        -- MUST stay column 1
    l.sampling_date   AS [Sampling date],           -- real DATE
    l.sample_taken_by AS [Sample taken by],
    MAX(CASE WHEN m.vat='Pos.28' AND m.metal='Cr' THEN m.value END) AS [Pos.28 Cr],
    MAX(CASE WHEN m.vat='Pos.28' AND m.metal='Cu' THEN m.value END) AS [Pos.28 Cu],
    MAX(CASE WHEN m.vat='Pos.28' AND m.metal='Fe' THEN m.value END) AS [Pos.28 Fe],
    MAX(CASE WHEN m.vat='Pos.28' AND m.metal='Zn' THEN m.value END) AS [Pos.28 Zn],
    MAX(CASE WHEN m.vat='Pos.28' AND m.metal='Pb' THEN m.value END) AS [Pos.28 Pb],
    MAX(CASE WHEN m.vat='Pos.29' AND m.metal='Cr' THEN m.value END) AS [Pos.29 Cr],
    MAX(CASE WHEN m.vat='Pos.29' AND m.metal='Cu' THEN m.value END) AS [Pos.29 Cu],
    MAX(CASE WHEN m.vat='Pos.29' AND m.metal='Fe' THEN m.value END) AS [Pos.29 Fe],
    MAX(CASE WHEN m.vat='Pos.29' AND m.metal='Zn' THEN m.value END) AS [Pos.29 Zn],
    MAX(CASE WHEN m.vat='Pos.29' AND m.metal='Pb' THEN m.value END) AS [Pos.29 Pb],
    MAX(CASE WHEN m.vat='Pos.30' AND m.metal='Cr' THEN m.value END) AS [Pos.30 Cr],
    MAX(CASE WHEN m.vat='Pos.30' AND m.metal='Cu' THEN m.value END) AS [Pos.30 Cu],
    MAX(CASE WHEN m.vat='Pos.30' AND m.metal='Fe' THEN m.value END) AS [Pos.30 Fe],
    MAX(CASE WHEN m.vat='Pos.30' AND m.metal='Zn' THEN m.value END) AS [Pos.30 Zn],
    MAX(CASE WHEN m.vat='Pos.30' AND m.metal='Pb' THEN m.value END) AS [Pos.30 Pb],
    MAX(CASE WHEN m.vat='Pos.31' AND m.metal='Cr' THEN m.value END) AS [Pos.31 Cr],
    MAX(CASE WHEN m.vat='Pos.31' AND m.metal='Cu' THEN m.value END) AS [Pos.31 Cu],
    MAX(CASE WHEN m.vat='Pos.31' AND m.metal='Fe' THEN m.value END) AS [Pos.31 Fe],
    MAX(CASE WHEN m.vat='Pos.31' AND m.metal='Zn' THEN m.value END) AS [Pos.31 Zn],
    MAX(CASE WHEN m.vat='Pos.31' AND m.metal='Pb' THEN m.value END) AS [Pos.31 Pb],
    l.created_at      AS [Row added]
FROM [qc].[contamination_log] AS l
LEFT JOIN [qc].[contamination_measurement] AS m ON m.contamination_log_id = l.id
WHERE l.line = 'Plating Line 1'
GROUP BY l.id, l.sampling_date, l.sample_taken_by, l.created_at;
GO

/* ---- 3. watermark: reproduce 020's view + a contamination branch ----- */
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
-- NEW: Contamination Log tab
UNION ALL
SELECT 'contamination',      CONVERT(BIGINT, ISNULL(MAX(row_version), 0)), COUNT_BIG(*)
FROM [qc].[contamination_log];
GO

/* ---- 4. insert (returns new id) ------------------------------------- */
CREATE OR ALTER PROCEDURE [qc].[usp_contamination_insert]
    @line            NVARCHAR(50),
    @sampling_date   DATE,
    @sample_taken_by NVARCHAR(100) = NULL,
    @measurements    NVARCHAR(MAX) = NULL   -- JSON: [{"vat":"Pos.28","metal":"Cr","value":"<2"}, ...]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @sampling_date IS NULL THROW 50001, N'Sampling date is required.', 1;
    IF @line IS NULL THROW 50008, N'Line is required.', 1;
    IF @measurements IS NOT NULL AND ISJSON(@measurements) = 0 THROW 50006, N'@measurements is not valid JSON.', 1;

    DECLARE @id INT;

    BEGIN TRAN;
    -- created_at is stamped by the column DEFAULT (Norway local) -- do not set it here.
    INSERT INTO [qc].[contamination_log] (line, sampling_date, sample_taken_by)
    VALUES (@line, @sampling_date, @sample_taken_by);
    SET @id = CAST(SCOPE_IDENTITY() AS INT);

    IF @measurements IS NOT NULL
        INSERT INTO [qc].[contamination_measurement] (contamination_log_id, vat, metal, value)
        SELECT @id, j.vat, j.metal, j.value
        FROM OPENJSON(@measurements)
             WITH (vat NVARCHAR(20), metal NVARCHAR(4), value NVARCHAR(30)) AS j;
    COMMIT TRAN;

    SELECT @id AS id;   -- app reads fetchone()[0]
END
GO

/* ---- 5. update (replace children; leaves created_at + line; guard) --- */
CREATE OR ALTER PROCEDURE [qc].[usp_contamination_update]
    @contamination_log_id INT,
    @sampling_date        DATE,
    @sample_taken_by      NVARCHAR(100) = NULL,
    @measurements         NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @sampling_date IS NULL THROW 50001, N'Sampling date is required.', 1;
    IF @measurements IS NOT NULL AND ISJSON(@measurements) = 0 THROW 50006, N'@measurements is not valid JSON.', 1;

    -- Edit guard (018 pattern): editable only if CREATED today or yesterday
    -- (created_at, Norway local). NULL created_at (pre-feature history) is locked.
    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    IF NOT EXISTS (SELECT 1 FROM [qc].[contamination_log] WHERE id = @contamination_log_id)
        THROW 50002, N'contamination_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[contamination_log] WHERE id = @contamination_log_id);
    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50004, N'Only rows created today or yesterday can be edited.', 1;

    BEGIN TRAN;
    UPDATE [qc].[contamination_log]
       SET sampling_date   = @sampling_date,
           sample_taken_by = @sample_taken_by
     WHERE id = @contamination_log_id;   -- created_at + line intentionally untouched

    DELETE FROM [qc].[contamination_measurement] WHERE contamination_log_id = @contamination_log_id;

    IF @measurements IS NOT NULL
        INSERT INTO [qc].[contamination_measurement] (contamination_log_id, vat, metal, value)
        SELECT @contamination_log_id, j.vat, j.metal, j.value
        FROM OPENJSON(@measurements)
             WITH (vat NVARCHAR(20), metal NVARCHAR(4), value NVARCHAR(30)) AS j;
    COMMIT TRAN;
END
GO

/* ---- 6. delete (children first per FK; today/yesterday guard) -------- */
CREATE OR ALTER PROCEDURE [qc].[usp_contamination_delete]
    @contamination_log_id INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    IF NOT EXISTS (SELECT 1 FROM [qc].[contamination_log] WHERE id = @contamination_log_id)
        THROW 50002, N'contamination_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[contamination_log] WHERE id = @contamination_log_id);
    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50003, N'Only rows created today or yesterday can be deleted.', 1;

    BEGIN TRAN;
    DELETE FROM [qc].[contamination_measurement] WHERE contamination_log_id = @contamination_log_id;
    DELETE FROM [qc].[contamination_log]         WHERE id = @contamination_log_id;
    COMMIT TRAN;
END
GO

/* ---- 7. grants: the 3 procs, to the data-manager role --------------- */
/* Role renamed in 019. SELECT on the view already covered by SCHEMA::qc (002). */
GRANT EXECUTE ON OBJECT::[qc].[usp_contamination_insert] TO [production_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_contamination_update] TO [production_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_contamination_delete] TO [production_data_manager_role];
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'022_create_contamination.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'022_create_contamination.sql');
GO

SET NOEXEC OFF;
GO
