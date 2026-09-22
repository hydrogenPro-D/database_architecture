/* =====================================================================
 * 017_add_created_at_and_row_added.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: ADDITIVE half of the "Row added" feature (ROW_ADDED_DB_SPEC.md):
 *   1. created_at DATETIME2(0) NULL on the 7 event/log tables, with a DEFAULT so
 *      inserts auto-stamp it (insert procs need no change). Existing rows stay
 *      NULL (pre-feature history -- NOT backfilled).
 *   2. Each of the 9 qc.vw_* views returns created_at AS [Row added] (right after
 *      the id column). [Date] stays a real DATE for the app's chronological sort.
 *
 * Scope is the 7 event entities ONLY: pH, adding-chemicals, conductivity, and the
 * 4 baths. NOT production tracking / dosage / watermark.
 *
 * created_at is stored in NORWAY LOCAL time (not raw SYSDATETIME, which is UTC on
 * Azure) so the app's dd.MM.yyyy HH:mm display and the created-today/yesterday
 * edit window (migration 018) are both correct -- same convention as the existing
 * date guards.
 *
 * The behavioural half -- update/delete editability keyed on created_at instead
 * of the entered date -- is migration 018.
 *
 * Run this file UTF-8 (vw_conductivity aliases contain 'µ').
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

/* ---- 1. created_at on the 7 event/log tables ------------------------ */
/* Nullable + Norway-local DEFAULT: new rows auto-stamp, existing rows stay NULL. */
IF COL_LENGTH(N'[qc].[ph_log]', N'created_at') IS NULL
    ALTER TABLE [qc].[ph_log] ADD [created_at] DATETIME2(0) NULL
        CONSTRAINT [DF_ph_log_created_at]
        DEFAULT (CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATETIME2(0)));
IF COL_LENGTH(N'[qc].[chemical_addition_log]', N'created_at') IS NULL
    ALTER TABLE [qc].[chemical_addition_log] ADD [created_at] DATETIME2(0) NULL
        CONSTRAINT [DF_chemical_addition_log_created_at]
        DEFAULT (CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATETIME2(0)));
IF COL_LENGTH(N'[qc].[conductivity_log]', N'created_at') IS NULL
    ALTER TABLE [qc].[conductivity_log] ADD [created_at] DATETIME2(0) NULL
        CONSTRAINT [DF_conductivity_log_created_at]
        DEFAULT (CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATETIME2(0)));
IF COL_LENGTH(N'[qc].[cleaner_bath_log]', N'created_at') IS NULL
    ALTER TABLE [qc].[cleaner_bath_log] ADD [created_at] DATETIME2(0) NULL
        CONSTRAINT [DF_cleaner_bath_log_created_at]
        DEFAULT (CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATETIME2(0)));
IF COL_LENGTH(N'[qc].[activator_bath_log]', N'created_at') IS NULL
    ALTER TABLE [qc].[activator_bath_log] ADD [created_at] DATETIME2(0) NULL
        CONSTRAINT [DF_activator_bath_log_created_at]
        DEFAULT (CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATETIME2(0)));
IF COL_LENGTH(N'[qc].[strike_bath_log]', N'created_at') IS NULL
    ALTER TABLE [qc].[strike_bath_log] ADD [created_at] DATETIME2(0) NULL
        CONSTRAINT [DF_strike_bath_log_created_at]
        DEFAULT (CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATETIME2(0)));
IF COL_LENGTH(N'[qc].[plate_bath_log]', N'created_at') IS NULL
    ALTER TABLE [qc].[plate_bath_log] ADD [created_at] DATETIME2(0) NULL
        CONSTRAINT [DF_plate_bath_log_created_at]
        DEFAULT (CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATETIME2(0)));
GO

/* ---- 2. views expose created_at AS [Row added] (after the id column) - */

/* --- pH Control --- */
CREATE OR ALTER VIEW [qc].[vw_ph_control] AS
SELECT
    l.id                                          AS ph_log_id,
    l.created_at                                  AS [Row added],
    l.date                                        AS [Date],
    l.measured_by                                 AS [Initials],
    MAX(CASE WHEN v.name = 'Vat. 28' AND m.measurement_number = 1 THEN m.ph_value END) AS [pH Vat. 28 1 meas.],
    MAX(CASE WHEN v.name = 'Vat. 28' AND m.measurement_number = 2 THEN m.ph_value END) AS [pH Vat. 28 2 meas.],
    MAX(CASE WHEN v.name = 'Vat. 29' AND m.measurement_number = 1 THEN m.ph_value END) AS [pH Vat. 29 1 meas.],
    MAX(CASE WHEN v.name = 'Vat. 29' AND m.measurement_number = 2 THEN m.ph_value END) AS [pH Vat. 29 2 meas.],
    MAX(CASE WHEN v.name = 'Vat. 30' AND m.measurement_number = 1 THEN m.ph_value END) AS [pH Vat. 30 1 meas.],
    MAX(CASE WHEN v.name = 'Vat. 30' AND m.measurement_number = 2 THEN m.ph_value END) AS [pH Vat. 30 2 meas.],
    MAX(CASE WHEN v.name = 'Vat. 31' AND m.measurement_number = 1 THEN m.ph_value END) AS [pH Vat. 31 - Strike],
    MAX(CASE WHEN v.name = 'Vat. 28' AND lv.chemical_id IS NOT NULL
             THEN CONCAT(lv.chemical_amount, ' ', ch.unit, ' ', ch.name) END) AS [Added to vat.28 (L)],
    MAX(CASE WHEN v.name = 'Vat. 29' AND lv.chemical_id IS NOT NULL
             THEN CONCAT(lv.chemical_amount, ' ', ch.unit, ' ', ch.name) END) AS [Added to vat.29 (L)],
    MAX(CASE WHEN v.name = 'Vat. 30' AND lv.chemical_id IS NOT NULL
             THEN CONCAT(lv.chemical_amount, ' ', ch.unit, ' ', ch.name) END) AS [Added to vat.30 (L)],
    MAX(CASE WHEN v.name = 'Vat. 31' AND lv.chemical_id IS NOT NULL
             THEN CONCAT(lv.chemical_amount, ' ', ch.unit, ' ', ch.name) END) AS [Added to vat.31 (kg)],
    l.time_of_measurement                         AS [Time of measurement],
    l.sample_taken_time                           AS [Sample taken time],
    MAX(lv.chemical_addition_time)                AS [Time when added],
    l.notes                                       AS [Notes]
FROM [qc].[ph_log] l
LEFT JOIN [qc].[ph_log_vat] lv    ON lv.ph_log_id = l.id
LEFT JOIN [qc].[vat] v            ON v.id = lv.vat_id
LEFT JOIN [qc].[chemical] ch      ON ch.id = lv.chemical_id
LEFT JOIN [qc].[ph_measurement] m ON m.ph_log_vat_id = lv.id
GROUP BY l.id, l.created_at, l.date, l.measured_by, l.time_of_measurement,
         l.sample_taken_time, l.notes;
GO

/* --- Adding Chemicals (FORMAT amount, per migration 005/016) --- */
CREATE OR ALTER VIEW [qc].[vw_adding_chemicals] AS
WITH per_vat AS (
    SELECT
        lv.chemical_addition_log_id AS log_id,
        v.name                      AS vat_name,
        lv.water_level_reduction    AS water_level,
        STRING_AGG(
            CASE WHEN ca.id IS NOT NULL THEN
                CONCAT(
                    FORMAT(ca.chemical_amount, '0.###', 'en-US'),
                    ' ', ch.unit, ' ', ch.name,
                    CASE WHEN ca.concentration IS NOT NULL
                         THEN CONCAT(' ', ca.concentration, '%') ELSE '' END)
            END,
            CHAR(13) + CHAR(10)) AS chemicals
    FROM [qc].[chemical_addition_log_vat] lv
    JOIN [qc].[vat] v                ON v.id = lv.vat_id
    LEFT JOIN [qc].[chemical_addition] ca ON ca.chemical_addition_log_vat_id = lv.id
    LEFT JOIN [qc].[chemical] ch     ON ch.id = ca.chemical_id
    GROUP BY lv.chemical_addition_log_id, v.name, lv.water_level_reduction
)
SELECT
    l.id        AS chemical_addition_log_id,
    l.created_at AS [Row added],
    l.date      AS [Date],
    l.added_by  AS [Initials],
    MAX(CASE WHEN pv.vat_name = 'Vat. 17' THEN pv.chemicals END) AS [Vat. 17 (Cathodic) (kg)],
    MAX(CASE WHEN pv.vat_name = 'Vat. 18' THEN pv.chemicals END) AS [Vat. 18 (Activation ) (kg)],
    MAX(CASE WHEN pv.vat_name = 'Vat. 28' THEN pv.chemicals END) AS [Vat. 28 (Plating 1) (kg)],
    MAX(CASE WHEN pv.vat_name = 'Vat. 28' AND pv.water_level IS NOT NULL
             THEN CONCAT(pv.water_level, ' cm') END)             AS [Vat. 28 (Plating 1) Water Level Reduction (cm)],
    MAX(CASE WHEN pv.vat_name = 'Vat. 29' THEN pv.chemicals END) AS [Vat. 29 (Plating 2) (kg)],
    MAX(CASE WHEN pv.vat_name = 'Vat. 29' AND pv.water_level IS NOT NULL
             THEN CONCAT(pv.water_level, ' cm') END)             AS [Vat. 29 (Plating 2) Water Level Reduction (cm)],
    MAX(CASE WHEN pv.vat_name = 'Vat. 30' THEN pv.chemicals END) AS [Vat. 30 (Plating 3) (kg)],
    MAX(CASE WHEN pv.vat_name = 'Vat. 30' AND pv.water_level IS NOT NULL
             THEN CONCAT(pv.water_level, ' cm') END)             AS [Vat. 30 (Plating 3) Water Level Reduction (cm)],
    MAX(CASE WHEN pv.vat_name = 'Vat. 31' THEN pv.chemicals END) AS [Vat. 31 (Strike) (kg)],
    MAX(CASE WHEN pv.vat_name = 'Vat. 31' AND pv.water_level IS NOT NULL
             THEN CONCAT(pv.water_level, ' cm') END)             AS [Vat. 31 (Strike) Water Level Reduction (cm)],
    l.time_when_added AS [Time when added],
    l.notes           AS [Notes]
FROM [qc].[chemical_addition_log] l
LEFT JOIN per_vat pv ON pv.log_id = l.id
GROUP BY l.id, l.created_at, l.date, l.added_by, l.time_when_added, l.notes;
GO

/* --- Conductivity (stage split, per migration 016) --- */
CREATE OR ALTER VIEW [qc].[vw_conductivity] AS
SELECT
    l.id         AS conductivity_log_id,
    l.created_at AS [Row added],
    l.date       AS [Date],
    l.logged_by  AS [Name],
    MAX(CASE WHEN v.name = 'Vat. 14' THEN cvl.conductivity END) AS [Cathodic Rinse 1 - pos.14 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 13' THEN cvl.conductivity END) AS [Cathodic Rinse 2 - pos.13 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 12' THEN cvl.conductivity END) AS [Cathodic Rinse 3 - pos.12 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 19' THEN cvl.conductivity END) AS [Activation Rinse 1 - pos.19 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 20' THEN cvl.conductivity END) AS [Activation Rinse 2 - pos.20 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 25' AND cvl.stage = 'Strike' THEN cvl.conductivity END) AS [Strike Rinse 1 - pos.25 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 24' THEN cvl.conductivity END) AS [Plating Rinse 1 - pos.24 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 23' THEN cvl.conductivity END) AS [Plating Rinse 2 - pos.23 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 22' THEN cvl.conductivity END) AS [Plating Rinse 3 - pos.22 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 21' THEN cvl.conductivity END) AS [Plating Rinse 4 - pos.21 (µS/cm)],
    l.observation AS [Additional observations]
FROM [qc].[conductivity_log] l
LEFT JOIN [qc].[conductivity_vat_log] cvl ON cvl.conductivity_log_id = l.id
LEFT JOIN [qc].[vat] v                    ON v.id = cvl.vat_id
GROUP BY l.id, l.created_at, l.date, l.logged_by, l.observation;
GO

/* --- Cleaner bath --- */
CREATE OR ALTER VIEW [qc].[vw_cleaner_bath] AS
SELECT
    l.id          AS cleaner_bath_log_id,
    l.created_at  AS [Row added],
    l.date        AS [Date],
    l.measured_by AS [Name],
    MAX(CASE WHEN m.measurement_type='pH'                  AND m.measurement_number=1 THEN m.measurement END) AS [pH 1st],
    MAX(CASE WHEN m.measurement_type='pH'                  AND m.measurement_number=2 THEN m.measurement END) AS [pH 2nd],
    MAX(CASE WHEN m.measurement_type='Titration step 1'    AND m.measurement_number=1 THEN m.measurement END) AS [Titration step 1 measurement 1],
    MAX(CASE WHEN m.measurement_type='Titration step 1'    AND m.measurement_number=2 THEN m.measurement END) AS [Titration step 1 measurement 2],
    MAX(CASE WHEN m.measurement_type='Titration step 2'    AND m.measurement_number=1 THEN m.measurement END) AS [Titration step 2 measurement 1],
    MAX(CASE WHEN m.measurement_type='Titration step 2'    AND m.measurement_number=2 THEN m.measurement END) AS [Titration step 2 measurement 2],
    MAX(CASE WHEN m.measurement_type='Schloetter protocol' AND m.measurement_number=1 THEN m.measurement END) AS [Schloetter protocol 1],
    MAX(CASE WHEN m.measurement_type='Schloetter protocol' AND m.measurement_number=2 THEN m.measurement END) AS [Schloetter protocol 2],
    l.notes       AS [Notes]
FROM [qc].[cleaner_bath_log] l
LEFT JOIN [qc].[cleaner_bath_measurement] m ON m.cleaner_bath_log_id = l.id
GROUP BY l.id, l.created_at, l.date, l.measured_by, l.notes;
GO

/* --- Activator bath --- */
CREATE OR ALTER VIEW [qc].[vw_activator_bath] AS
SELECT
    l.id          AS activator_bath_log_id,
    l.created_at  AS [Row added],
    l.date        AS [Date],
    l.measured_by AS [Name],
    MAX(CASE WHEN m.measurement_type='pH'                   AND m.measurement_number=1 THEN m.measurement END) AS [pH 1st],
    MAX(CASE WHEN m.measurement_type='pH'                   AND m.measurement_number=2 THEN m.measurement END) AS [pH 2nd],
    MAX(CASE WHEN m.measurement_type='Decasel5 Titration_ml' AND m.measurement_number=1 THEN m.measurement END) AS [Decasel5 Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Decasel5 Titration_ml' AND m.measurement_number=2 THEN m.measurement END) AS [Decasel5 Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='Nickel Titration_ml'   AND m.measurement_number=1 THEN m.measurement END) AS [Nickel Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Nickel Titration_ml'   AND m.measurement_number=2 THEN m.measurement END) AS [Nickel Titration 2nd (ml)],
    l.notes       AS [Notes]
FROM [qc].[activator_bath_log] l
LEFT JOIN [qc].[activator_bath_measurement] m ON m.activator_bath_log_id = l.id
GROUP BY l.id, l.created_at, l.date, l.measured_by, l.notes;
GO

/* --- Strike bath --- */
CREATE OR ALTER VIEW [qc].[vw_strike_bath] AS
SELECT
    l.id          AS strike_bath_log_id,
    l.created_at  AS [Row added],
    l.date        AS [Date],
    l.measured_by AS [Name],
    MAX(CASE WHEN m.measurement_type='pH'              AND m.measurement_number=1 THEN m.measurement END) AS [pH 1st],
    MAX(CASE WHEN m.measurement_type='pH'              AND m.measurement_number=2 THEN m.measurement END) AS [pH 2nd],
    MAX(CASE WHEN m.measurement_type='Ni2+ Titration_ml' AND m.measurement_number=1 THEN m.measurement END) AS [Ni2+ Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Ni2+ Titration_ml' AND m.measurement_number=2 THEN m.measurement END) AS [Ni2+ Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='Cl- Titration_ml'  AND m.measurement_number=1 THEN m.measurement END) AS [Cl- Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Cl- Titration_ml'  AND m.measurement_number=2 THEN m.measurement END) AS [Cl- Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='HCl+ Titration_ml' AND m.measurement_number=1 THEN m.measurement END) AS [HCl+ Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='HCl+ Titration_ml' AND m.measurement_number=2 THEN m.measurement END) AS [HCl+ Titration 2nd (ml)],
    l.notes       AS [Notes]
FROM [qc].[strike_bath_log] l
LEFT JOIN [qc].[strike_bath_measurement] m ON m.strike_bath_log_id = l.id
GROUP BY l.id, l.created_at, l.date, l.measured_by, l.notes;
GO

/* --- Plate baths: one view per tab (Vat. 28 / 29 / 30) --- */
CREATE OR ALTER VIEW [qc].[vw_plate_bath_28] AS
SELECT
    l.id          AS plate_bath_log_id,
    l.created_at  AS [Row added],
    l.date        AS [Date],
    l.measured_by AS [Name],
    MAX(CASE WHEN m.measurement_type='pH'                  AND m.measurement_number=1 THEN m.measurement END) AS [pH 1st],
    MAX(CASE WHEN m.measurement_type='pH'                  AND m.measurement_number=2 THEN m.measurement END) AS [pH 2nd],
    MAX(CASE WHEN m.measurement_type='Ni2+ Titration_ml'      AND m.measurement_number=1 THEN m.measurement END) AS [Ni2+ Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Ni2+ Titration_ml'      AND m.measurement_number=2 THEN m.measurement END) AS [Ni2+ Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='Cl- Titration_ml'       AND m.measurement_number=1 THEN m.measurement END) AS [Cl- Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Cl- Titration_ml'       AND m.measurement_number=2 THEN m.measurement END) AS [Cl- Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='ThioUrea Titration_ml'  AND m.measurement_number=1 THEN m.measurement END) AS [ThioUrea Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='ThioUrea Titration_ml'  AND m.measurement_number=2 THEN m.measurement END) AS [ThioUrea Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='Boric Acid Titration_ml' AND m.measurement_number=1 THEN m.measurement END) AS [Boric Acid Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Boric Acid Titration_ml' AND m.measurement_number=2 THEN m.measurement END) AS [Boric Acid Titration 2nd (ml)],
    l.notes       AS [Notes]
FROM [qc].[plate_bath_log] l
JOIN [qc].[vat] v                        ON v.id = l.vat_id
LEFT JOIN [qc].[plate_bath_measurement] m ON m.plate_bath_log_id = l.id
WHERE v.name = 'Vat. 28'
GROUP BY l.id, l.created_at, l.date, l.measured_by, l.notes;
GO

CREATE OR ALTER VIEW [qc].[vw_plate_bath_29] AS
SELECT
    l.id          AS plate_bath_log_id,
    l.created_at  AS [Row added],
    l.date        AS [Date],
    l.measured_by AS [Name],
    MAX(CASE WHEN m.measurement_type='pH'                  AND m.measurement_number=1 THEN m.measurement END) AS [pH 1st],
    MAX(CASE WHEN m.measurement_type='pH'                  AND m.measurement_number=2 THEN m.measurement END) AS [pH 2nd],
    MAX(CASE WHEN m.measurement_type='Ni2+ Titration_ml'      AND m.measurement_number=1 THEN m.measurement END) AS [Ni2+ Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Ni2+ Titration_ml'      AND m.measurement_number=2 THEN m.measurement END) AS [Ni2+ Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='Cl- Titration_ml'       AND m.measurement_number=1 THEN m.measurement END) AS [Cl- Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Cl- Titration_ml'       AND m.measurement_number=2 THEN m.measurement END) AS [Cl- Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='ThioUrea Titration_ml'  AND m.measurement_number=1 THEN m.measurement END) AS [ThioUrea Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='ThioUrea Titration_ml'  AND m.measurement_number=2 THEN m.measurement END) AS [ThioUrea Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='Boric Acid Titration_ml' AND m.measurement_number=1 THEN m.measurement END) AS [Boric Acid Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Boric Acid Titration_ml' AND m.measurement_number=2 THEN m.measurement END) AS [Boric Acid Titration 2nd (ml)],
    l.notes       AS [Notes]
FROM [qc].[plate_bath_log] l
JOIN [qc].[vat] v                        ON v.id = l.vat_id
LEFT JOIN [qc].[plate_bath_measurement] m ON m.plate_bath_log_id = l.id
WHERE v.name = 'Vat. 29'
GROUP BY l.id, l.created_at, l.date, l.measured_by, l.notes;
GO

CREATE OR ALTER VIEW [qc].[vw_plate_bath_30] AS
SELECT
    l.id          AS plate_bath_log_id,
    l.created_at  AS [Row added],
    l.date        AS [Date],
    l.measured_by AS [Name],
    MAX(CASE WHEN m.measurement_type='pH'                  AND m.measurement_number=1 THEN m.measurement END) AS [pH 1st],
    MAX(CASE WHEN m.measurement_type='pH'                  AND m.measurement_number=2 THEN m.measurement END) AS [pH 2nd],
    MAX(CASE WHEN m.measurement_type='Ni2+ Titration_ml'      AND m.measurement_number=1 THEN m.measurement END) AS [Ni2+ Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Ni2+ Titration_ml'      AND m.measurement_number=2 THEN m.measurement END) AS [Ni2+ Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='Cl- Titration_ml'       AND m.measurement_number=1 THEN m.measurement END) AS [Cl- Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Cl- Titration_ml'       AND m.measurement_number=2 THEN m.measurement END) AS [Cl- Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='ThioUrea Titration_ml'  AND m.measurement_number=1 THEN m.measurement END) AS [ThioUrea Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='ThioUrea Titration_ml'  AND m.measurement_number=2 THEN m.measurement END) AS [ThioUrea Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='Boric Acid Titration_ml' AND m.measurement_number=1 THEN m.measurement END) AS [Boric Acid Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Boric Acid Titration_ml' AND m.measurement_number=2 THEN m.measurement END) AS [Boric Acid Titration 2nd (ml)],
    l.notes       AS [Notes]
FROM [qc].[plate_bath_log] l
JOIN [qc].[vat] v                        ON v.id = l.vat_id
LEFT JOIN [qc].[plate_bath_measurement] m ON m.plate_bath_log_id = l.id
WHERE v.name = 'Vat. 30'
GROUP BY l.id, l.created_at, l.date, l.measured_by, l.notes;
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'017_add_created_at_and_row_added.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'017_add_created_at_and_row_added.sql');
GO

SET NOEXEC OFF;
GO
