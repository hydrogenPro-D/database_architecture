/* =====================================================================
 * 032_app_settings.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: ACID_CALCULATOR_SETTINGS_DB_SPEC.md -- move the acid calculator's two
 *   settings out of config/acid_calculator.json, so the target pH and history
 *   window are one plant decision instead of one per machine.
 *     1. qc.app_setting          -- APPEND-ONLY key/value history, seeded with 2 keys
 *     2. qc.vw_app_setting       -- read path, CURRENT values only
 *     3. qc.usp_app_setting_set  -- appends a new version
 *     4. an 'app_setting' entity in qc.vw_change_watermark
 *   Idempotent (OBJECT_ID guard, NOT EXISTS seed, CREATE OR ALTER).
 *   Run 001-031 first -- the watermark below reads qc.vat_dump_log from 031.
 *
 * HISTORY IS KEPT -- APPEND-ONLY (decided; this replaces the spec's upsert shape)
 * -----------------------------------------------------------------------------
 * The spec proposed setting_key as the primary key with an upsert, justified by
 * "the limits keep only the current value". That justification was out of date:
 * migration 028 made qc.measurement_threshold append-only. This table follows the
 * SAME shape, so the two behave alike and a setting's whole trail survives:
 *     - a setting is NEVER updated or deleted. Each change APPENDS a row.
 *     - the current value of a key is the row with the highest app_setting_id.
 *     - "latest" is ordered by app_setting_id, NOT by updated_at: IDENTITY is
 *       strictly monotonic, while two writes inside the same second would tie on
 *       DATETIME2(0).
 *     - there is deliberately NO unique constraint on setting_key: several rows
 *       per key is the entire point.
 * That also closes the gap the spec's own rationale left open -- "a dose everyone
 * followed last week cannot be explained if the target has since moved" needs the
 * old value, which an upsert would have thrown away.
 *
 * ERROR CODES (reusing the existing numbers, as asked)
 * ----------------------------------------------------
 *   50009  @expected_row_version does not match the current row (stale write).
 *          Same code usp_measurement_threshold_update raises for a stale write.
 *   50010  a required value is empty -- @setting_key, @setting_value or
 *          @updated_by. Same code the measurement limit procedures use for a
 *          blank @updated_by; the spec groups both emptiness cases under one
 *          code, so this covers all three parameters.
 * No new numbers were invented. The app matches on the code, not the message.
 *
 * VALUES ARE TEXT ON PURPOSE
 * --------------------------
 * A decimal and an integer today, possibly neither tomorrow. The application
 * parses, validates (target pH 3.0-7.0; window 7/14/30/60/90) and falls back to
 * its defaults when a value will not parse -- the calculator is never left with
 * nothing to say because a setting is unreadable. The database stores text and
 * does not police the ranges.
 *
 * DOTTED KEYS
 * -----------
 * 'acid_calculator.target_ph.vat_28' would sit beside the plant-wide key with no
 * schema change, should a per-vat target ever be wanted. No such key exists and
 * the app does not look for one. The target is assumed plant-wide, as today.
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
IF OBJECT_ID(N'[qc].[vat_dump_log]', N'U') IS NULL
BEGIN
    RAISERROR(N'Run 031 first -- the change watermark here reads qc.vat_dump_log.', 16, 1);
    SET NOEXEC ON;
END;
GO

/* ---- 1. the table: append-only, newest row per key wins -------------- */
IF OBJECT_ID(N'[qc].[app_setting]', N'U') IS NULL
CREATE TABLE [qc].[app_setting] (
    [app_setting_id] INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    [setting_key]    NVARCHAR(64)  NOT NULL,    -- NOT unique: one row per version
    [setting_value]  NVARCHAR(200) NOT NULL,    -- text: the app parses it
    [updated_at]     DATETIME2(0)  NOT NULL
        CONSTRAINT [DF_app_setting_updated_at]
        DEFAULT (CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATETIME2(0))),
    [updated_by]     NVARCHAR(100) NOT NULL,
    [row_version]    ROWVERSION    NOT NULL     -- feeds vw_change_watermark
);
GO

/* "newest version of this key" is the hot path -- every read goes through it. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_app_setting_latest'
                 AND object_id = OBJECT_ID(N'[qc].[app_setting]'))
    CREATE NONCLUSTERED INDEX [IX_app_setting_latest]
        ON [qc].[app_setting] ([setting_key], [app_setting_id] DESC);
GO

/* ---- 2. seed today's defaults --------------------------------------- */
/* NOT EXISTS on the key, so a re-run never adds a second "initial" version and
 * never resurrects a default over a value somebody has since set. */
INSERT INTO [qc].[app_setting] ([setting_key], [setting_value], [updated_by])
SELECT x.k, x.v, N'032_seed'
FROM (VALUES
    (N'acid_calculator.target_ph',   N'4.1'),
    (N'acid_calculator.window_days', N'30')
) AS x(k, v)
WHERE NOT EXISTS (SELECT 1 FROM [qc].[app_setting] a WHERE a.[setting_key] = x.k);

DECLARE @keys INT = (SELECT COUNT(DISTINCT [setting_key]) FROM [qc].[app_setting]);
DECLARE @rows INT = (SELECT COUNT(*) FROM [qc].[app_setting]);
PRINT CONCAT(N'app_setting: ', @keys, N' key(s) (expected 2), ', @rows, N' row(s) incl. history');
GO

/* ---- 3. read path: CURRENT values only ------------------------------ */
/* The table is append-only, so the view collapses it to the newest row per key.
 * The app reads the whole view -- two rows today -- so there is no filtering.
 * row_version is exposed because the app passes it back on a write, exactly as
 * it does for a measurement threshold.
 * To read a setting's history, query qc.app_setting directly (002's
 * SELECT ON SCHEMA::qc already covers it). */
CREATE OR ALTER VIEW [qc].[vw_app_setting] AS
WITH latest AS (
    SELECT s.*,
           ROW_NUMBER() OVER (PARTITION BY s.[setting_key]
                              ORDER BY s.[app_setting_id] DESC) AS rn
    FROM [qc].[app_setting] s
)
SELECT
    l.[setting_key]   AS [Setting],
    l.[setting_value] AS [Value],
    l.[updated_at]    AS [Updated at],
    l.[updated_by]    AS [Updated by],
    l.[row_version]   AS row_version
FROM latest l
WHERE l.rn = 1;
GO

/* ---- 4. write path: APPENDS a new version --------------------------- */
/* Nothing is ever updated. The procedure appends a row, which becomes the
 * current value because it has the highest id; the previous row stays as
 * history. Signature is unchanged from the spec.
 *
 * @expected_row_version is OPTIONAL: NULL means "no check", so the app can adopt
 * this procedure before it starts round-tripping the version, without needing a
 * second migration. When supplied it is compared against the CURRENT row -- if a
 * newer version has been appended since the caller read it, that is a stale
 * write and raises 50009. */
CREATE OR ALTER PROCEDURE [qc].[usp_app_setting_set]
    @setting_key          NVARCHAR(64),
    @setting_value        NVARCHAR(200),
    @updated_by           NVARCHAR(100),
    @expected_row_version BINARY(8) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @setting_key IS NULL OR LTRIM(RTRIM(@setting_key)) = N''
        THROW 50010, N'Setting key is required.', 1;
    IF @setting_value IS NULL OR LTRIM(RTRIM(@setting_value)) = N''
        THROW 50010, N'Setting value is required.', 1;
    IF @updated_by IS NULL OR LTRIM(RTRIM(@updated_by)) = N''
        THROW 50010, N'Updated by is required.', 1;

    -- the CURRENT version = highest app_setting_id for this key
    DECLARE @current BINARY(8);
    SELECT TOP 1 @current = s.[row_version]
    FROM [qc].[app_setting] s
    WHERE s.[setting_key] = @setting_key
    ORDER BY s.[app_setting_id] DESC;

    -- NULL = no check. Given but not matching (including the key not existing
    -- yet) means somebody else wrote it first.
    IF @expected_row_version IS NOT NULL
       AND (@current IS NULL OR @current <> @expected_row_version)
        THROW 50009, N'This setting was changed by someone else -- refresh and try again.', 1;

    -- append: the new row becomes current, the old one remains as history
    INSERT INTO [qc].[app_setting] ([setting_key], [setting_value], [updated_by])
    VALUES (@setting_key, @setting_value, @updated_by);
END
GO

/* ---- 5. watermark: reproduce 031's view + an app_setting entity ----- */
/* entity keys are a stable contract with the app -- do NOT rename.
 * row_count here counts every version, which is exactly what is wanted: it moves
 * whenever a setting is changed. */
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
UNION ALL
SELECT 'vat_dump_28', CONVERT(BIGINT, ISNULL(MAX(d.row_version), 0)), COUNT_BIG(*)
FROM [qc].[vat_dump_log] d JOIN [qc].[vat] v ON v.id = d.vat_id WHERE v.name = 'Vat. 28'
UNION ALL
SELECT 'vat_dump_29', CONVERT(BIGINT, ISNULL(MAX(d.row_version), 0)), COUNT_BIG(*)
FROM [qc].[vat_dump_log] d JOIN [qc].[vat] v ON v.id = d.vat_id WHERE v.name = 'Vat. 29'
UNION ALL
SELECT 'vat_dump_30', CONVERT(BIGINT, ISNULL(MAX(d.row_version), 0)), COUNT_BIG(*)
FROM [qc].[vat_dump_log] d JOIN [qc].[vat] v ON v.id = d.vat_id WHERE v.name = 'Vat. 30'
-- NEW: a setting changed on one machine reaches every other within one poll
UNION ALL
SELECT 'app_setting',        CONVERT(BIGINT, ISNULL(MAX(row_version), 0)), COUNT_BIG(*)
FROM [qc].[app_setting];
GO

/* ---- grants --------------------------------------------------------- */
/* The view needs none: 002 granted SELECT ON SCHEMA::qc. Writes stay proc-only. */
GRANT EXECUTE ON OBJECT::[qc].[usp_app_setting_set] TO [production_data_manager_role];
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'032_app_settings.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'032_app_settings.sql');
GO

SET NOEXEC OFF;
GO
