/* =====================================================================
 * 028_create_measurement_limits.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: MEASUREMENT_LIMITS_DB_SPEC.md -- move the measurement limits out of
 *   config.json (and out of the hardcoded dicts/literals in the GUI) and into the
 *   database, so they can be edited from inside the app and stop disagreeing
 *   between the entry form and the plots.
 *     1. qc.measurement_section    -- one row per measured quantity (32 rows)
 *     2. qc.measurement_threshold  -- APPEND-ONLY history of every threshold
 *                                     value; seeded with 67 initial rows
 *     3. seed data for all four baths, exactly as the spec tabulates it
 *     4. qc.vw_measurement_thresholds        (read path, current values only)
 *     5. qc.usp_measurement_threshold_update (write path, appends a new version)
 *   Idempotent: tables are OBJECT_ID-guarded, the seed is NOT EXISTS-guarded (so
 *   re-running never duplicates and never overwrites an edited value), view and
 *   procedure are CREATE OR ALTER. Run 001-027 first.
 *
 * KEYED ON THE VAT, NOT A BATH NAME
 * ---------------------------------
 * The pH Control tab's vats 28-31 are the SAME physical vats the plate and strike
 * tabs use, so plate.ph and the pH tab's vat_28 collapse into one row that cannot
 * disagree. Seeding resolves the vat BY NAME rather than hard-coding vat_id, so
 * the script does not depend on the id ordering happening to be 1..6.
 *
 * THE TWO MISMATCHES THE SPEC SETTLED, AS SEEDED
 * ----------------------------------------------
 *   - Vat 31 pH is -0.5 to 1.0 (the pH tab's values). config.strike.ph's +-0.25 /
 *     +-0.1 is discarded.
 *   - Activator nickel is stored ONLY in g/L (7 and 8), never in titration mL.
 *     Both rows have lower_value NULL -- "up to 7" has no lower bound.
 *   - Plating cobalt: all three vats get vat 28's values (nominal 4, reaction
 *     3.4-4.6, tolerance 3.2-4.8). Vats 29/30's looser config values are discarded.
 *   - cleaner.titration's three suffixed keys become three ordinary sections named
 *     for what they measure: alkalinity_total, carbonate, hydroxide_silicate.
 *
 * ONE ADDITION TO THE SPEC'S VIEW
 * -------------------------------
 * The view also returns row_version. The spec's column list omits it, but
 * usp_measurement_threshold_update takes @expected_row_version and the app reads
 * exclusively through the view -- without it the caller has no way to obtain the
 * value the concurrency check demands, and the guard would be unusable.
 *
 * OPEN QUESTIONS, AS DECIDED
 * --------------------------
 *   1. Vat 31's pH band (-0.5 to 1.0) is seeded as 'tolerance'.
 *   2. HISTORY = THE TABLE ITSELF, append-only (decided; replaces the earlier
 *      update-in-place draft). qc.measurement_threshold is never updated: each
 *      edit appends a row and the highest id per (section, threshold_type) is the
 *      current value, the same precedent qc.electrode_chemical_dosage set. So
 *      there is no separate history table, the unique constraint on
 *      (measurement_section_id, threshold_type) is gone, and
 *      vw_measurement_thresholds collapses the table to the current values.
 *      Read the history by querying qc.measurement_threshold directly.
 *   3. Who may edit is still open: EXECUTE is granted to
 *      production_data_manager_role like every other write path, so it is
 *      currently "whoever can use the app". Add a check in the procedure if that
 *      changes.
 *
 * ALSO NOT INCLUDED
 * -----------------
 *   - No vw_change_watermark entity: the spec says thresholds change rarely and a
 *     refresh after an edit is enough, so they are deliberately not polled.
 *
 * NEW ERROR CODES: 50009 concurrency conflict, 50010 updated_by required,
 * 50011 threshold shape invalid. (50001-50008 are already in use elsewhere.)
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
    RAISERROR(N'Run 004 first (creates qc.vat, which the sections reference).', 16, 1);
    SET NOEXEC ON;
END;
GO

/* ---- 1. sections: one row per measured quantity --------------------- */
IF OBJECT_ID(N'[qc].[measurement_section]', N'U') IS NULL
CREATE TABLE [qc].[measurement_section] (
    [id]          INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    [vat_id]      INT NOT NULL
        CONSTRAINT [FK_measurement_section_vat] REFERENCES [qc].[vat]([id]),
    [section_key] NVARCHAR(40) NOT NULL,     -- ph, nickel, carbonate, cobalt, ...
    [unit]        NVARCHAR(20) NULL,         -- g/L, ml/L, pH, mol/L
    [row_version] ROWVERSION    NOT NULL,
    CONSTRAINT [UQ_measurement_section] UNIQUE ([vat_id], [section_key])
);
GO

/* ---- 2. thresholds: APPEND-ONLY history, newest row wins ------------ */
/* This table is its own history, the same shape as qc.electrode_chemical_dosage:
 * a threshold is never UPDATEd. Every edit appends a new row, and the row with
 * the highest id for a given (section, type) is the current value.
 *   - There is deliberately NO unique constraint on (measurement_section_id,
 *     threshold_type): several rows per pair is the whole point.
 *   - "Latest" is ordered by id, not updated_at: IDENTITY is strictly monotonic,
 *     while two edits inside the same second would tie on DATETIME2(0).
 *   - updated_at / updated_by describe THE VERSION THAT ROW IS -- on the current
 *     row they read naturally as "last changed, by whom", which is what the view
 *     exposes.
 * decimal(12,5): strike chloride is already 101.2625 / 60.7575. Two decimals is
 * exactly what silently truncated plate_bath_measurement (see migration 025). */
IF OBJECT_ID(N'[qc].[measurement_threshold]', N'U') IS NULL
CREATE TABLE [qc].[measurement_threshold] (
    [id]                     INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    [measurement_section_id] INT NOT NULL
        CONSTRAINT [FK_measurement_threshold_section]
        REFERENCES [qc].[measurement_section]([id]),
    [threshold_type] NVARCHAR(20)  NOT NULL,  -- nominal | control | reaction | tolerance
    [middle_value]   DECIMAL(12,5) NULL,      -- the target; only for 'nominal'
    [lower_value]    DECIMAL(12,5) NULL,      -- NULL is meaningful: no lower bound
    [upper_value]    DECIMAL(12,5) NULL,
    [updated_at]     DATETIME2(0)  NOT NULL
        CONSTRAINT [DF_measurement_threshold_updated_at]
        DEFAULT (CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATETIME2(0))),
    [updated_by]     NVARCHAR(100) NOT NULL,
    [row_version]    ROWVERSION    NOT NULL,
    CONSTRAINT [CK_measurement_threshold_type]
        CHECK ([threshold_type] IN (N'nominal', N'control', N'reaction', N'tolerance')),
    CONSTRAINT [CK_measurement_threshold_order]
        CHECK ([lower_value] IS NULL OR [upper_value] IS NULL OR [lower_value] <= [upper_value]),
    -- keeps the shape honest: a nominal is a point, a band is an interval
    CONSTRAINT [CK_measurement_threshold_shape] CHECK (
        ([threshold_type] =  N'nominal' AND [middle_value] IS NOT NULL
             AND [lower_value] IS NULL AND [upper_value] IS NULL)
        OR
        ([threshold_type] <> N'nominal' AND [middle_value] IS NULL
             AND ([lower_value] IS NOT NULL OR [upper_value] IS NOT NULL))
    )
);
GO

/* "latest version per (section, type)" is the hot path -- every read goes through
 * it. id DESC leading means the view's ROW_NUMBER can walk the index directly. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_measurement_threshold_latest'
                 AND object_id = OBJECT_ID(N'[qc].[measurement_threshold]'))
    CREATE NONCLUSTERED INDEX [IX_measurement_threshold_latest]
        ON [qc].[measurement_threshold] ([measurement_section_id], [threshold_type], [id] DESC);
GO

/* ---- 3. seed (idempotent: never duplicates, never overwrites edits) -- */
DECLARE @seed TABLE (
    vat_name       NVARCHAR(50),
    section_key    NVARCHAR(40),
    unit           NVARCHAR(20),
    threshold_type NVARCHAR(20),
    middle_value   DECIMAL(12,5),
    lower_value    DECIMAL(12,5),
    upper_value    DECIMAL(12,5));

/* Vat. 17 -- cleaner. The three suffixed config keys become three sections. */
INSERT INTO @seed VALUES
 (N'Vat. 17', N'ph',                 N'pH',    N'control',   NULL, 11.81,  14.43),
 (N'Vat. 17', N'ph',                 N'pH',    N'reaction',  NULL,  9.84,  16.4),
 (N'Vat. 17', N'alkalinity_total',   N'mol/L', N'control',   NULL,  0.77,   0.95),
 (N'Vat. 17', N'alkalinity_total',   N'mol/L', N'reaction',  NULL,  0.65,   1.08),
 (N'Vat. 17', N'carbonate',          N'mol/L', N'control',   NULL,  0.08,   0.09),
 (N'Vat. 17', N'carbonate',          N'mol/L', N'reaction',  NULL,  0.06,   0.11),
 (N'Vat. 17', N'hydroxide_silicate', N'mol/L', N'control',   NULL,  0.70,   0.85),
 (N'Vat. 17', N'hydroxide_silicate', N'mol/L', N'reaction',  NULL,  0.58,   0.97),
 (N'Vat. 17', N'schloetter',         N'g/L',   N'reaction',  NULL, 43,     58),
 (N'Vat. 17', N'schloetter',         N'g/L',   N'tolerance', NULL, 38,     62),
/* Vat. 18 -- activator. Nickel is g/L only, and has NO lower bound. */
 (N'Vat. 18', N'decasel5',           N'g/L',   N'nominal',     60, NULL,   NULL),
 (N'Vat. 18', N'decasel5',           N'g/L',   N'reaction',  NULL, 53,     67),
 (N'Vat. 18', N'decasel5',           N'g/L',   N'tolerance', NULL, 50,     70),
 (N'Vat. 18', N'nickel',             N'g/L',   N'reaction',  NULL, NULL,    7),
 (N'Vat. 18', N'nickel',             N'g/L',   N'tolerance', NULL, NULL,    8),
/* Vat. 31 -- strike. pH is the pH tab's -0.5 to 1.0 (open question 1). */
 (N'Vat. 31', N'ph',                 N'pH',    N'tolerance', NULL, -0.5,    1.0),
 (N'Vat. 31', N'nickel',             N'g/L',   N'control',   NULL, 34.668, 42.372),
 (N'Vat. 31', N'nickel',             N'g/L',   N'reaction',  NULL, 28.89,  48.15),
 (N'Vat. 31', N'chloride',           N'g/L',   N'control',   NULL, 72.909, 89.111),
 (N'Vat. 31', N'chloride',           N'g/L',   N'reaction',  NULL, 60.7575, 101.2625),
 (N'Vat. 31', N'hcl',                N'ml/L',  N'reaction',  NULL, 82,    134),
 (N'Vat. 31', N'hcl',                N'ml/L',  N'tolerance', NULL, 72,    144);

/* Vats 28/29/30 -- plating. Identical values, but THREE independent sets of rows
 * so they can diverge later without a schema change. */
INSERT INTO @seed (vat_name, section_key, unit, threshold_type, middle_value, lower_value, upper_value)
SELECT v.name, p.section_key, p.unit, p.threshold_type, p.middle_value, p.lower_value, p.upper_value
FROM (VALUES (N'Vat. 28'), (N'Vat. 29'), (N'Vat. 30')) AS v(name)
CROSS JOIN (VALUES
 (N'ph',                  N'pH',  N'reaction',  NULL,  3.7,  4.3),
 (N'ph',                  N'pH',  N'tolerance', NULL,  3.5,  4.5),
 (N'nickel',              N'g/L', N'reaction',  NULL, 30,   38),
 (N'nickel',              N'g/L', N'tolerance', NULL, 29,   40),
 (N'chloride',            N'g/L', N'reaction',  NULL, 12,   18),
 (N'chloride',            N'g/L', N'tolerance', NULL, 10,   20),
 (N'thiourea',            N'g/L', N'reaction',  NULL, 45,   55),
 (N'thiourea',            N'g/L', N'tolerance', NULL, 43,   57),
 (N'boric_acid',          N'g/L', N'reaction',  NULL, 34,   42),
 (N'boric_acid',          N'g/L', N'tolerance', NULL, 33,   43),
 (N'spectroquant_nickel', N'g/L', N'reaction',  NULL, 30,   38),
 (N'spectroquant_nickel', N'g/L', N'tolerance', NULL, 29,   40),
 (N'cobalt',              N'g/L', N'nominal',      4, NULL, NULL),
 (N'cobalt',              N'g/L', N'reaction',  NULL,  3.4,  4.6),
 (N'cobalt',              N'g/L', N'tolerance', NULL,  3.2,  4.8)
) AS p(section_key, unit, threshold_type, middle_value, lower_value, upper_value);

INSERT INTO [qc].[measurement_section] ([vat_id], [section_key], [unit])
SELECT DISTINCT v.[id], s.section_key, s.unit
FROM @seed s
JOIN [qc].[vat] v ON v.[name] = s.vat_name
WHERE NOT EXISTS (SELECT 1 FROM [qc].[measurement_section] ms
                  WHERE ms.[vat_id] = v.[id] AND ms.[section_key] = s.section_key);

INSERT INTO [qc].[measurement_threshold]
    ([measurement_section_id], [threshold_type], [middle_value], [lower_value], [upper_value], [updated_by])
SELECT ms.[id], s.threshold_type, s.middle_value, s.lower_value, s.upper_value, N'028_seed'
FROM @seed s
JOIN [qc].[vat] v                      ON v.[name]  = s.vat_name
JOIN [qc].[measurement_section] ms     ON ms.[vat_id] = v.[id] AND ms.[section_key] = s.section_key
WHERE NOT EXISTS (SELECT 1 FROM [qc].[measurement_threshold] mt
                  WHERE mt.[measurement_section_id] = ms.[id]
                    AND mt.[threshold_type] = s.threshold_type);

/* PRINT only accepts a scalar expression -- a subquery inline is a parse error
 * (Msg 1046), so the counts are read into variables first. */
DECLARE @n_sections   INT = (SELECT COUNT(*) FROM [qc].[measurement_section]);
DECLARE @n_thresholds INT = (SELECT COUNT(*) FROM [qc].[measurement_threshold]);
PRINT CONCAT(N'measurement_section rows: ',   @n_sections,   N' (expected 32)');
PRINT CONCAT(N'measurement_threshold rows: ', @n_thresholds, N' (expected 67)');
GO

/* ---- 4. read path: CURRENT values only ------------------------------ */
/* The table is append-only, so the view collapses it to the newest row per
 * (section, threshold_type) -- that is what "current" means here. Callers never
 * see superseded versions; to read the history, query qc.measurement_threshold
 * directly (002's SELECT ON SCHEMA::qc already covers it).
 *
 * One row per threshold; a section with two bands returns two rows and the app
 * pivots them. qc.vat is joined in so no caller has to. row_version is exposed
 * because the update procedure's @expected_row_version needs it. */
CREATE OR ALTER VIEW [qc].[vw_measurement_thresholds] AS
WITH latest AS (
    SELECT mt.*,
           ROW_NUMBER() OVER (PARTITION BY mt.[measurement_section_id], mt.[threshold_type]
                              ORDER BY mt.[id] DESC) AS rn
    FROM [qc].[measurement_threshold] mt
)
SELECT
    v.id   AS vat_id,
    v.name AS vat_name,
    ms.section_key,
    ms.unit,
    l.threshold_type,
    l.middle_value,
    l.lower_value,
    l.upper_value,
    l.updated_at,
    l.updated_by,
    l.row_version
FROM latest l
JOIN [qc].[measurement_section] ms ON ms.id = l.measurement_section_id
JOIN [qc].[vat] v                  ON v.id = ms.vat_id
WHERE l.rn = 1;
GO

/* ---- 5. write path: APPENDS a new version --------------------------- */
/* Nothing is ever updated in place. The procedure appends a row, which becomes
 * the current value because it has the highest id; the previous row stays as
 * history. Signature is unchanged from the spec.
 *
 * Optimistic locking: @expected_row_version is the row_version the caller last
 * read from the view, i.e. of the row that was current then. If a newer version
 * has been appended since, it no longer matches -- throw 50009 and let the app
 * refresh and say so, rather than silently stacking an edit on stale values. */
CREATE OR ALTER PROCEDURE [qc].[usp_measurement_threshold_update]
    @vat_id               INT,
    @section_key          NVARCHAR(40),
    @threshold_type       NVARCHAR(20),
    @middle_value         DECIMAL(12,5) = NULL,
    @lower_value          DECIMAL(12,5) = NULL,
    @upper_value          DECIMAL(12,5) = NULL,
    @updated_by           NVARCHAR(100),
    @expected_row_version BINARY(8)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @updated_by IS NULL OR LTRIM(RTRIM(@updated_by)) = N''
        THROW 50010, N'Updated by is required.', 1;

    -- Mirror of CK_measurement_threshold_shape, so a bad payload gets a clear
    -- message instead of a raw constraint violation.
    IF (@threshold_type = N'nominal'
            AND (@middle_value IS NULL OR @lower_value IS NOT NULL OR @upper_value IS NOT NULL))
       OR (@threshold_type <> N'nominal'
            AND (@middle_value IS NOT NULL OR (@lower_value IS NULL AND @upper_value IS NULL)))
        THROW 50011, N'A nominal needs middle_value only; a band needs a lower and/or upper value.', 1;

    -- the CURRENT version = highest id for this (section, threshold_type)
    DECLARE @section_id INT, @current BINARY(8);
    SELECT TOP 1 @section_id = ms.[id], @current = mt.[row_version]
    FROM [qc].[measurement_threshold] mt
    JOIN [qc].[measurement_section] ms ON ms.[id] = mt.[measurement_section_id]
    WHERE ms.[vat_id] = @vat_id
      AND ms.[section_key] = @section_key
      AND mt.[threshold_type] = @threshold_type
    ORDER BY mt.[id] DESC;

    IF @section_id IS NULL
        THROW 50002, N'No threshold for that vat / section_key / threshold_type.', 1;
    IF @expected_row_version IS NULL OR @current <> @expected_row_version
        THROW 50009, N'This threshold was changed by someone else -- refresh and try again.', 1;

    -- append: the new row becomes current, the old one remains as history
    INSERT INTO [qc].[measurement_threshold]
        ([measurement_section_id], [threshold_type], [middle_value],
         [lower_value], [upper_value], [updated_by])
    VALUES (@section_id, @threshold_type, @middle_value,
            @lower_value, @upper_value, @updated_by);
END
GO

/* ---- grants --------------------------------------------------------- */
/* The view needs none: 002 granted SELECT ON SCHEMA::qc. Writes stay proc-only. */
GRANT EXECUTE ON OBJECT::[qc].[usp_measurement_threshold_update] TO [production_data_manager_role];
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'028_create_measurement_limits.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'028_create_measurement_limits.sql');
GO

SET NOEXEC OFF;
GO
