/* =====================================================================
 * 030_ph_before_after_reading.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: PH_BEFORE_AFTER_SPEC.md -- the pH Control tab now records each vat's pH
 *   as found, then the correction, then the pH after correcting.
 *   VIEW CHANGE ONLY, AND PURELY ADDITIVE. No table changes, no procedure
 *   changes, and NOT ONE ROW inserted, updated or deleted. qc.vw_ph_control gains
 *   three columns, read from measurement_number = 3:
 *         [pH Vat. 28 (after)]
 *         [pH Vat. 29 (after)]
 *         [pH Vat. 30 (after)]
 *   placed before [Notes], which is where the tab shows them.
 *   Idempotent (CREATE OR ALTER). Run 001-029 first.
 *
 * NOTHING EXISTING IS RENAMED OR REMOVED
 * --------------------------------------
 * [pH Vat. 28 1 meas.] and its 29/30 siblings stay as they are -- they are still
 * the reading as found. [pH Vat. 31 - Strike] keeps its name. The [... 2 meas.]
 * columns also stay: the app stops displaying them simply by not asking for them,
 * and their rows stay in qc.ph_measurement. The shorter labels the tab shows
 * ("pH Vat. 28", "pH Vat. 31 Strike") are applied in the app, not here.
 *
 * THE SPEC'S "PLEASE CHECK" -- ANSWERED: NO PROCEDURE CHANGE IS NEEDED
 * -------------------------------------------------------------------
 * Verified against the database and the proc bodies:
 *   - qc.ph_measurement has NO check constraints at all, so measurement_number 3
 *     is already storable.
 *   - usp_ph_control_insert (006) and usp_ph_control_update (018) both take the
 *     value straight from the payload with
 *         TRY_CAST(JSON_VALUE(r.value, '$.measurement_number') AS INT)
 *     and whitelist nothing. 1, 2 and 3 are all accepted as-is.
 * So the procedures are deliberately left exactly as they are.
 *
 * HISTORY IS NOT TOUCHED
 * ----------------------
 * Every existing measurement_number = 2 row stays exactly where it is. They are
 * repeat readings of the same sample, NOT corrected values -- migrating them into
 * 3 would put wrong numbers on the plots. Counts at the time of writing
 * (production):
 *     Vat 28: 961 x #1, 390 x #2      Vat 30: 788 x #1, 327 x #2
 *     Vat 29: 726 x #1, 318 x #2      Vat 31: 259 x #1, no #2 (never corrected)
 * The three new columns are NULL for all of that history, which is correct.
 *
 * DEPLOYMENT ORDER: EITHER WAY ROUND IS SAFE
 * ------------------------------------------
 * Because nothing existing changes, the currently installed exe keeps reading the
 * same columns it always did. A newer build shows the after-correction fields
 * blank until this lands, then they fill as operators use them. There is no need
 * to ship this migration and the exe together.
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
IF OBJECT_ID(N'[qc].[vw_ph_control]', N'V') IS NULL
BEGIN
    RAISERROR(N'Run 005/017 first (creates vw_ph_control).', 16, 1);
    SET NOEXEC ON;
END;
GO

/* ---- vw_ph_control + the three after-correction columns ------------- */
/* Reproduced from 017 with ONLY the three new columns added.
 * measurement_number 1 = as found, 2 = the old repeat reading (kept, unused by
 * the app), 3 = after the correction. Vat 31 (Strike) is never corrected, so it
 * has no (after) column. */
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
    -- NEW: the reading after correcting (NULL for all history; vats 28-30 only)
    MAX(CASE WHEN v.name = 'Vat. 28' AND m.measurement_number = 3 THEN m.ph_value END) AS [pH Vat. 28 (after)],
    MAX(CASE WHEN v.name = 'Vat. 29' AND m.measurement_number = 3 THEN m.ph_value END) AS [pH Vat. 29 (after)],
    MAX(CASE WHEN v.name = 'Vat. 30' AND m.measurement_number = 3 THEN m.ph_value END) AS [pH Vat. 30 (after)],
    l.notes                                       AS [Notes]
FROM [qc].[ph_log] l
LEFT JOIN [qc].[ph_log_vat] lv    ON lv.ph_log_id = l.id
LEFT JOIN [qc].[vat] v            ON v.id = lv.vat_id
LEFT JOIN [qc].[chemical] ch      ON ch.id = lv.chemical_id
LEFT JOIN [qc].[ph_measurement] m ON m.ph_log_vat_id = lv.id
GROUP BY l.id, l.created_at, l.date, l.measured_by, l.time_of_measurement,
         l.sample_taken_time, l.notes;
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'030_ph_before_after_reading.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'030_ph_before_after_reading.sql');
GO

SET NOEXEC OFF;
GO
