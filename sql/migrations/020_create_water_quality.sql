/* =====================================================================
 * 020_create_water_quality.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: NEW "Water Quality" tab (WATER_QUALITY_DB_SPEC.md) -- WWTP effluent
 *   daily log (conductivity + pH), an 8th editable event entity. Adds:
 *     1. qc.water_quality_log  (with created_at "Row added" + row_version).
 *     2. qc.vw_water_quality   (id first; Date/Time kept as real DATE/TIME).
 *     3. usp_water_quality_insert (returns new id) / _update / _delete.
 *     4. a 'water_quality' branch in qc.vw_change_watermark (polling).
 *     5. GRANT EXECUTE on the 3 procs to the data-manager role.
 *   Idempotent (OBJECT_ID / COL_LENGTH guards + CREATE OR ALTER). Run 001-019 first.
 *
 * FOUR deliberate deviations from the spec's literal SQL, to stay consistent
 * with the conventions the other 7 event entities already follow:
 *   a) created_at is stamped in NORWAY LOCAL time via a column DEFAULT (as in
 *      017), NOT raw SYSDATETIME() (= UTC on Azure). The insert proc therefore
 *      does NOT set created_at -- the default stamps it. This keeps the
 *      created-today/yesterday edit window (below) from drifting a day at
 *      midnight. UPDATE still never touches created_at.
 *   b) _update / _delete enforce the created_at today/yesterday EDIT GUARD (as
 *      in 018): created_at NULL or older -> locked. The app already blocks this
 *      client-side; the guard is defense-in-depth, matching every sibling entity.
 *      (If you truly want the DB to be guardless here, delete the two guard
 *      blocks -- nothing else depends on them.)
 *   c) grants go to [production_data_manager_role] -- the role's NEW name after
 *      019 (was qc_data_manager_role).
 *   d) the view needs NO SELECT grant: 002 granted SELECT ON SCHEMA::qc, which
 *      already covers it (same as every other vw_*).
 *
 * Run this file UTF-8 (the view alias contains 'µ').
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

/* ---- 1. table ------------------------------------------------------- */
/* created_at: nullable + Norway-local DEFAULT so inserts auto-stamp (017 pattern).
 * row_version: auto-maintained ROWVERSION feeding the watermark view (013 pattern). */
IF OBJECT_ID(N'[qc].[water_quality_log]', N'U') IS NULL
    CREATE TABLE [qc].[water_quality_log] (
        [id]                  INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        [date]                DATE          NOT NULL,
        [time_of_measurement] TIME          NULL,          -- clock time, no date
        [operator]            NVARCHAR(255) NULL,
        [conductivity]        DECIMAL(12,2) NULL,          -- µS/cm, non-negative
        [ph]                  DECIMAL(4,2)  NULL,          -- app enforces -1..14
        [created_at]          DATETIME2(0)  NULL           -- "Row added"
            CONSTRAINT [DF_water_quality_log_created_at]
            DEFAULT (CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATETIME2(0))),
        [row_version]         ROWVERSION    NOT NULL
    );
GO

/* ---- 2. read view --------------------------------------------------- */
/* id MUST stay column 1 (app's ORDER BY tie-breaker). Date/Time kept as real
 * DATE/TIME so the app can sort chronologically. Column names are an exact
 * contract, incl. 'Conductivity (µS/cm)' and 'Row added'. */
CREATE OR ALTER VIEW [qc].[vw_water_quality] AS
SELECT
    l.id                  AS id,                        -- MUST stay column 1
    l.date                AS [Date],                    -- real DATE
    l.time_of_measurement AS [Time of measurement],     -- real TIME
    l.operator            AS [Operator],
    l.conductivity        AS [Conductivity (µS/cm)],
    l.ph                  AS [pH],
    l.created_at          AS [Row added]
FROM [qc].[water_quality_log] AS l;
GO

/* ---- 3. watermark: reproduce 013's view + a water_quality branch ----- */
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
-- NEW: Water Quality tab
UNION ALL
SELECT 'water_quality',      CONVERT(BIGINT, ISNULL(MAX(row_version), 0)), COUNT_BIG(*)
FROM [qc].[water_quality_log];
GO

/* ---- 4. insert (returns new id) ------------------------------------- */
CREATE OR ALTER PROCEDURE [qc].[usp_water_quality_insert]
    @date                DATE,
    @time_of_measurement TIME          = NULL,
    @operator            NVARCHAR(255) = NULL,
    @conductivity        DECIMAL(12,2) = NULL,
    @ph                  DECIMAL(4,2)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @date IS NULL THROW 50001, N'Date is required.', 1;

    -- created_at is stamped by the column DEFAULT (Norway local) -- do not set it here.
    INSERT INTO [qc].[water_quality_log] (date, time_of_measurement, operator, conductivity, ph)
    VALUES (@date, @time_of_measurement, @operator, @conductivity, @ph);

    SELECT CAST(SCOPE_IDENTITY() AS INT) AS id;   -- app reads fetchone()[0]
END
GO

/* ---- 5. update (leaves created_at; today/yesterday edit guard) ------- */
CREATE OR ALTER PROCEDURE [qc].[usp_water_quality_update]
    @water_quality_log_id INT,
    @date                 DATE,
    @time_of_measurement  TIME          = NULL,
    @operator             NVARCHAR(255) = NULL,
    @conductivity         DECIMAL(12,2) = NULL,
    @ph                   DECIMAL(4,2)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @date IS NULL THROW 50001, N'Date is required.', 1;

    -- Edit guard (018 pattern): editable only if CREATED today or yesterday
    -- (created_at, Norway local). NULL created_at (pre-feature history) is locked.
    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    IF NOT EXISTS (SELECT 1 FROM [qc].[water_quality_log] WHERE id = @water_quality_log_id)
        THROW 50002, N'water_quality_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[water_quality_log] WHERE id = @water_quality_log_id);
    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50004, N'Only rows created today or yesterday can be edited.', 1;

    UPDATE [qc].[water_quality_log]
       SET date                = @date,
           time_of_measurement = @time_of_measurement,
           operator            = @operator,
           conductivity        = @conductivity,
           ph                  = @ph
     WHERE id = @water_quality_log_id;   -- created_at intentionally untouched
END
GO

/* ---- 6. delete (today/yesterday guard) ------------------------------ */
CREATE OR ALTER PROCEDURE [qc].[usp_water_quality_delete]
    @water_quality_log_id INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    IF NOT EXISTS (SELECT 1 FROM [qc].[water_quality_log] WHERE id = @water_quality_log_id)
        THROW 50002, N'water_quality_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[water_quality_log] WHERE id = @water_quality_log_id);
    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50003, N'Only rows created today or yesterday can be deleted.', 1;

    DELETE FROM [qc].[water_quality_log] WHERE id = @water_quality_log_id;
END
GO

/* ---- 7. grants: the 3 procs, to the data-manager role --------------- */
/* Role was renamed in 019 (qc_data_manager_role -> production_data_manager_role).
 * SELECT on the view is already covered by GRANT SELECT ON SCHEMA::qc (002). */
GRANT EXECUTE ON OBJECT::[qc].[usp_water_quality_insert] TO [production_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_water_quality_update] TO [production_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_water_quality_delete] TO [production_data_manager_role];
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'020_create_water_quality.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'020_create_water_quality.sql');
GO

SET NOEXEC OFF;
GO
