/* =====================================================================
 * 005_create_qc_views.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: create the 10 denormalizing UI views (one wide row per event) per
 *         UI_VIEWS_HANDOFF.md -- plate is split into one view per tab
 *         (28/29/30). Idempotent via CREATE OR ALTER. Run 001 first.
 *
 * PERMISSIONS: no new grant needed. 002 granted SELECT ON SCHEMA::qc to
 * qc_data_manager_role, which covers all objects in the qc schema -- including
 * these views (current and future). Views + tables share the qc owner, so
 * ownership chaining means SELECT on the view is sufficient.
 *
 * MULTI-BATCH GUARD: unlike 001-004 this file can't be a single batch --
 * CREATE VIEW must be the first statement in its batch, so views are separated
 * by GO. A single THROW therefore wouldn't stop later batches in SSMS. Instead
 * the guards below RAISERROR + SET NOEXEC ON, which makes SQL Server compile but
 * SKIP every subsequent batch in the session; SET NOEXEC OFF at the end resets.
 *
 * NOTE: column aliases contain spaces/symbols incl. 'µ' -- run this file as
 * UTF-8 so the micro sign is preserved.
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

/* ---- 1. pH Control --------------------------------------------------- */
CREATE OR ALTER VIEW [qc].[vw_ph_control] AS
SELECT
    l.id                                          AS ph_log_id,
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
GROUP BY l.id, l.date, l.measured_by, l.time_of_measurement,
         l.sample_taken_time, l.notes;
GO

/* ---- 2. Adding Chemicals -------------------------------------------- */
/* Two child grains: chemicals (chemical_addition) + water level
 * (chemical_addition_log_vat). Fold the chemicals to one string per (log, vat)
 * in a CTE FIRST, so the water-level value isn't fanned-out-multiplied. */
CREATE OR ALTER VIEW [qc].[vw_adding_chemicals] AS
WITH per_vat AS (
    SELECT
        lv.chemical_addition_log_id AS log_id,
        v.name                      AS vat_name,
        lv.water_level_reduction    AS water_level,
        STRING_AGG(
            CASE WHEN ca.id IS NOT NULL THEN
                CONCAT(
                    -- trim trailing zeros: 2.000 -> 2, 2.500 -> 2.5, 0.190 -> 0.19.
                    -- FORMAT (not TRIM TRAILING) so it parses below compat level 160
                    -- -- the production DB (dataloggingDev) is on an older level.
                    FORMAT(ca.chemical_amount, '0.###', 'en-US'),
                    ' ', ch.unit, ' ', ch.name,
                    CASE WHEN ca.concentration IS NOT NULL
                         THEN CONCAT(' ', ca.concentration, '%') ELSE '' END)
            END,
            CHAR(13) + CHAR(10)) AS chemicals   -- one chemical per line
    FROM [qc].[chemical_addition_log_vat] lv
    JOIN [qc].[vat] v                ON v.id = lv.vat_id
    LEFT JOIN [qc].[chemical_addition] ca ON ca.chemical_addition_log_vat_id = lv.id
    LEFT JOIN [qc].[chemical] ch     ON ch.id = ca.chemical_id
    GROUP BY lv.chemical_addition_log_id, v.name, lv.water_level_reduction
)
SELECT
    l.id        AS chemical_addition_log_id,
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
GROUP BY l.id, l.date, l.added_by, l.time_when_added, l.notes;
GO

/* ---- 3. Production Tracking ----------------------------------------- */
CREATE OR ALTER VIEW [qc].[vw_production_tracking] AS
SELECT
    t.id     AS electrode_production_tracking_id,
    t.shift  AS [Shift],
    t.date   AS [Date],
    MAX(CASE WHEN v.name = 'Vat. 28' THEN ev.prod_electrodes_sum END)   AS [Vat 28],
    MAX(CASE WHEN v.name = 'Vat. 29' THEN ev.prod_electrodes_sum END)   AS [Vat 29],
    MAX(CASE WHEN v.name = 'Vat. 30' THEN ev.prod_electrodes_sum END)   AS [Vat 30],
    MAX(CASE WHEN v.name = 'Vat. 28' THEN ev.prod_electrodes_shift END) AS [Vat 28 (shift)],
    MAX(CASE WHEN v.name = 'Vat. 29' THEN ev.prod_electrodes_shift END) AS [Vat 29 (shift)],
    MAX(CASE WHEN v.name = 'Vat. 30' THEN ev.prod_electrodes_shift END) AS [Vat 30 (shift)],
    t.tu_dose_g_per_electrode AS [TU (g/electrode)],
    t.ba_dose_g_per_electrode AS [BA (g/electrode)]
FROM [qc].[electrode_production_tracking] t
LEFT JOIN [qc].[electrode_production_vat] ev ON ev.electrode_production_tracking_id = t.id
LEFT JOIN [qc].[vat] v                       ON v.id = ev.vat_id
GROUP BY t.id, t.shift, t.date, t.tu_dose_g_per_electrode, t.ba_dose_g_per_electrode;
GO

/* ---- 4. Conductivity ------------------------------------------------ */
CREATE OR ALTER VIEW [qc].[vw_conductivity] AS
SELECT
    l.id         AS conductivity_log_id,
    l.date       AS [Date],
    l.logged_by  AS [Name],
    MAX(CASE WHEN v.name = 'Vat. 14' THEN cvl.conductivity END) AS [Cathodic Rinse 1 - pos.14 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 13' THEN cvl.conductivity END) AS [Cathodic Rinse 2 - pos.13 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 12' THEN cvl.conductivity END) AS [Cathodic Rinse 3 - pos.12 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 19' THEN cvl.conductivity END) AS [Activation Rinse 1 - pos.19 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 20' THEN cvl.conductivity END) AS [Activation Rinse 2 - pos.20 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 25' THEN cvl.conductivity END) AS [Plating Rinse 1 - pos.25 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 24' THEN cvl.conductivity END) AS [Plating Rinse 2 - pos.24 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 23' THEN cvl.conductivity END) AS [Plating Rinse 3 - pos.23 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 22' THEN cvl.conductivity END) AS [Plating Rinse 4 - pos.22 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 21' THEN cvl.conductivity END) AS [Plating Rinse 5 - pos.21 (µS/cm)],
    l.observation AS [Additional observations]
FROM [qc].[conductivity_log] l
LEFT JOIN [qc].[conductivity_vat_log] cvl ON cvl.conductivity_log_id = l.id
LEFT JOIN [qc].[vat] v                    ON v.id = cvl.vat_id
GROUP BY l.id, l.date, l.logged_by, l.observation;
GO

/* ---- 5. Cleaner bath (single bath: Vat. 17) ------------------------- */
CREATE OR ALTER VIEW [qc].[vw_cleaner_bath] AS
SELECT
    l.id          AS cleaner_bath_log_id,
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
GROUP BY l.id, l.date, l.measured_by, l.notes;
GO

/* ---- 6. Activator bath (single bath: Vat. 18) ----------------------- */
CREATE OR ALTER VIEW [qc].[vw_activator_bath] AS
SELECT
    l.id          AS activator_bath_log_id,
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
GROUP BY l.id, l.date, l.measured_by, l.notes;
GO

/* ---- 7. Strike bath (single bath: Vat. 31) -------------------------- */
CREATE OR ALTER VIEW [qc].[vw_strike_bath] AS
SELECT
    l.id          AS strike_bath_log_id,
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
GROUP BY l.id, l.date, l.measured_by, l.notes;
GO

/* ---- 8. Plate baths -- one view per plate tab (Vat. 28 / 29 / 30) --- */
/* Same shape as the single-bath views; each filters plate_bath_log to its vat.
 * The three differ ONLY in the WHERE vat name. */

CREATE OR ALTER VIEW [qc].[vw_plate_bath_28] AS
SELECT
    l.id          AS plate_bath_log_id,
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
GROUP BY l.id, l.date, l.measured_by, l.notes;
GO

CREATE OR ALTER VIEW [qc].[vw_plate_bath_29] AS
SELECT
    l.id          AS plate_bath_log_id,
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
GROUP BY l.id, l.date, l.measured_by, l.notes;
GO

CREATE OR ALTER VIEW [qc].[vw_plate_bath_30] AS
SELECT
    l.id          AS plate_bath_log_id,
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
GROUP BY l.id, l.date, l.measured_by, l.notes;
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'005_create_qc_views.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'005_create_qc_views.sql');
GO

SET NOEXEC OFF;
GO
