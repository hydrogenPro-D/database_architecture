/* =====================================================================
 * 026_plate_view_split_nickel_labels.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: PLATE_VIEW_SPLIT_SPEC.md -- VIEW CHANGE ONLY. No table, no procedure,
 *   no grant, and NOT ONE ROW inserted, updated or deleted.
 *     vw_plate_bath_28 / _29 / _30:
 *       1. [Ni2+ Titration 1st/2nd (ml)] are now fed ONLY by
 *          measurement_type = 'Ni2+ Titration_ml'.
 *       2. NEW pair fed ONLY by 'Ni2+ + Co2+ Titration_ml':
 *            [Ni2+ + Co2+ Titration 1st (ml)] / [... 2nd (ml)]
 *          placed immediately before [Ni Absorbance 445nm 1st].
 *   Idempotent (CREATE OR ALTER). Run 001-025 first.
 *
 * SUPERSEDES migration 025's merge. 025 deliberately fed BOTH labels into the
 * single [Ni2+ Titration ...] pair so the existing column would not break while
 * the cobalt split landed. The consequence was that from each vat's cutover
 * onward that column presented nickel + cobalt values under the nickel name --
 * the wrong number under the wrong name. The two labels partition cleanly (no log
 * row carries both, enforced by how 025 re-typed them), so they can now be split.
 *
 * COLUMN ORDER IS A CONTRACT: the application maps table rows back to ids by
 * position, so plate_bath_log_id stays first and [Row added] second, and every
 * pre-existing column keeps its place. The new pair is appended just before the
 * absorbance block, which is where the spec puts it.
 *
 * Expected non-null counts after this runs (dataloggingTest):
 *     vat 28: Ni2+ 55, Ni2+ + Co2+ 27, of 88 rows
 *     vat 29: Ni2+ 69, Ni2+ + Co2+  7, of 95 rows
 *     vat 30: Ni2+ 67, Ni2+ + Co2+ 10, of 95 rows
 *   and no row may have both populated.
 *
 * No grant needed: 002 granted SELECT ON SCHEMA::qc, which covers these views.
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
IF OBJECT_ID(N'[qc].[vw_plate_bath_28]', N'V') IS NULL
BEGIN
    RAISERROR(N'Run 025 first (creates the current plate views).', 16, 1);
    SET NOEXEC ON;
END;
GO

CREATE OR ALTER VIEW [qc].[vw_plate_bath_28] AS
SELECT
    l.id          AS plate_bath_log_id,
    l.created_at  AS [Row added],
    l.date        AS [Date],
    l.measured_by AS [Name],
    MAX(CASE WHEN m.measurement_type='pH'                  AND m.measurement_number=1 THEN m.measurement END) AS [pH 1st],
    MAX(CASE WHEN m.measurement_type='pH'                  AND m.measurement_number=2 THEN m.measurement END) AS [pH 2nd],
    -- pre-cutover nickel ONLY (the post-cutover label has its own pair below)
    MAX(CASE WHEN m.measurement_type='Ni2+ Titration_ml'      AND m.measurement_number=1 THEN m.measurement END) AS [Ni2+ Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Ni2+ Titration_ml'      AND m.measurement_number=2 THEN m.measurement END) AS [Ni2+ Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='Cl- Titration_ml'       AND m.measurement_number=1 THEN m.measurement END) AS [Cl- Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Cl- Titration_ml'       AND m.measurement_number=2 THEN m.measurement END) AS [Cl- Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='ThioUrea Titration_ml'  AND m.measurement_number=1 THEN m.measurement END) AS [ThioUrea Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='ThioUrea Titration_ml'  AND m.measurement_number=2 THEN m.measurement END) AS [ThioUrea Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='Boric Acid Titration_ml' AND m.measurement_number=1 THEN m.measurement END) AS [Boric Acid Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Boric Acid Titration_ml' AND m.measurement_number=2 THEN m.measurement END) AS [Boric Acid Titration 2nd (ml)],
    -- post-cutover: the same EDTA titration, now correctly named Ni + Co
    MAX(CASE WHEN m.measurement_type='Ni2+ + Co2+ Titration_ml' AND m.measurement_number=1 THEN m.measurement END) AS [Ni2+ + Co2+ Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Ni2+ + Co2+ Titration_ml' AND m.measurement_number=2 THEN m.measurement END) AS [Ni2+ + Co2+ Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='Ni Absorbance_445nm'    AND m.measurement_number=1 THEN m.measurement END) AS [Ni Absorbance 445nm 1st],
    MAX(CASE WHEN m.measurement_type='Ni Absorbance_445nm'    AND m.measurement_number=2 THEN m.measurement END) AS [Ni Absorbance 445nm 2nd],
    MAX(CASE WHEN m.measurement_type='Ni Absorbance_445nm'    AND m.measurement_number=3 THEN m.measurement END) AS [Ni Absorbance 445nm 3rd],
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
    MAX(CASE WHEN m.measurement_type='Ni2+ + Co2+ Titration_ml' AND m.measurement_number=1 THEN m.measurement END) AS [Ni2+ + Co2+ Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Ni2+ + Co2+ Titration_ml' AND m.measurement_number=2 THEN m.measurement END) AS [Ni2+ + Co2+ Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='Ni Absorbance_445nm'    AND m.measurement_number=1 THEN m.measurement END) AS [Ni Absorbance 445nm 1st],
    MAX(CASE WHEN m.measurement_type='Ni Absorbance_445nm'    AND m.measurement_number=2 THEN m.measurement END) AS [Ni Absorbance 445nm 2nd],
    MAX(CASE WHEN m.measurement_type='Ni Absorbance_445nm'    AND m.measurement_number=3 THEN m.measurement END) AS [Ni Absorbance 445nm 3rd],
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
    MAX(CASE WHEN m.measurement_type='Ni2+ + Co2+ Titration_ml' AND m.measurement_number=1 THEN m.measurement END) AS [Ni2+ + Co2+ Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Ni2+ + Co2+ Titration_ml' AND m.measurement_number=2 THEN m.measurement END) AS [Ni2+ + Co2+ Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='Ni Absorbance_445nm'    AND m.measurement_number=1 THEN m.measurement END) AS [Ni Absorbance 445nm 1st],
    MAX(CASE WHEN m.measurement_type='Ni Absorbance_445nm'    AND m.measurement_number=2 THEN m.measurement END) AS [Ni Absorbance 445nm 2nd],
    MAX(CASE WHEN m.measurement_type='Ni Absorbance_445nm'    AND m.measurement_number=3 THEN m.measurement END) AS [Ni Absorbance 445nm 3rd],
    l.notes       AS [Notes]
FROM [qc].[plate_bath_log] l
JOIN [qc].[vat] v                        ON v.id = l.vat_id
LEFT JOIN [qc].[plate_bath_measurement] m ON m.plate_bath_log_id = l.id
WHERE v.name = 'Vat. 30'
GROUP BY l.id, l.created_at, l.date, l.measured_by, l.notes;
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'026_plate_view_split_nickel_labels.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'026_plate_view_split_nickel_labels.sql');
GO

SET NOEXEC OFF;
GO
