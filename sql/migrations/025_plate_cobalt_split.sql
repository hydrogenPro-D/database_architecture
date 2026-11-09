/* =====================================================================
 * 025_plate_cobalt_split.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: PLATE_COBALT_DB_SPEC.md changes 1-4 for the plate baths:
 *     1. plate_bath_measurement.measurement  DECIMAL(8,2) -> DECIMAL(10,5)
 *        (it is silently rounding existing values). The column is an INCLUDE
 *        column of IX_plate_bath_measurement_log_id, so that index is dropped
 *        and recreated around the ALTER -- SQL Server blocks ALTER COLUMN while
 *        an index depends on the column.
 *     2. Re-type post-cutover 'Ni2+ Titration_ml' rows to
 *        'Ni2+ + Co2+ Titration_ml' (values unchanged, label only).
 *     3. vw_plate_bath_28/_29/_30 gain the three Ni Absorbance columns and
 *        accept BOTH Ni labels in the existing Ni2+ columns.
 *     4. usp_plate_bath_insert / _update widen their JSON cast to DECIMAL(10,5).
 *   Idempotent (type/index guards + CREATE OR ALTER + self-nulling UPDATE).
 *   Run 001-024 first.
 *
 * WHY DATE-BASED RE-TYPING IS SAFE (change 2)
 * -------------------------------------------
 * The spec warns to key on (Vat, Seq) because dates repeat. That applies to
 * matching INDIVIDUAL rows (e.g. attaching absorbance). For the bulk re-type the
 * cutover is a clean date boundary -- verified against the four CSVs: the last
 * pre-cutover plate row is 2026-06-03 for all three vats, and no date appears in
 * both plate_old_nickel.csv and plate_nickel_cobalt.csv. So "all Ni2+ rows on or
 * after this vat's cutover" is unambiguous and needs no Seq mapping.
 *   Vat 28 -> 2026-07-15   Vat 29 -> 2026-08-14   Vat 30 -> 2026-08-18
 * The UPDATE is re-runnable: re-typed rows no longer match. RE-RUN IT AFTER THE
 * BACKFILL (change 5) if that backfill inserts Ni2+ rows with the old label.
 *
 * ANSWERS TO THE SPEC'S OPEN QUESTIONS ABOUT THE PROCEDURES (change 4)
 * --------------------------------------------------------------------
 * Confirmed by reading the proc bodies (the spec author lacked VIEW DEFINITION):
 *   - The payload parser does NOT whitelist measurement_type or
 *     measurement_number: both are taken straight from the JSON. So the new
 *     'Ni Absorbance_445nm' type and measurement_number = 3 are accepted as-is,
 *     and no CHECK constraint on measurement_number exists to block a third row.
 *   - The signature therefore does NOT change. The ONE real blocker was the cast
 *     TRY_CAST(... AS DECIMAL(8,2)), which would have rounded absorbance 0.677 to
 *     0.68 no matter how wide the column is. Widened to DECIMAL(10,5) below.
 *   - usp_plate_bath_update DELETES ALL measurements for the log row and rebuilds
 *     them from @measurements. Absorbance is handled like any other type, but
 *     this also means the app MUST send the full payload (absorbance included) on
 *     every edit, or those rows are dropped. That is existing "replace children"
 *     behaviour, unchanged here -- flagged because the spec asked about it.
 *
 * NOT IN THIS MIGRATION
 * ---------------------
 *   - Change 5 (backfill): needs data/weekly_result_scheme_plate*.csv, which is
 *     not in this repo, plus the Seq->log_id mapping and the three open
 *     decisions. That is a data script, not DDL.
 *   - strike_bath_measurement is ALSO silently rounding (Cl- Titration_ml has 4
 *     decimals in the source data) and should get the same DECIMAL(10,5) change.
 *     Left out to keep this migration to the spec's subject. activator (2
 *     decimals) does not need it; cleaner's 15-decimal values are float division
 *     noise the ETL deliberately caps at scale 2.
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
IF OBJECT_ID(N'[qc].[plate_bath_measurement]', N'U') IS NULL
BEGIN
    RAISERROR(N'Run 004 first (creates the bath tables).', 16, 1);
    SET NOEXEC ON;
END;
GO

/* ---- 1. widen measurement to DECIMAL(10,5) -------------------------- */
/* Needed scale, measured across the real plate data:
 *   Cl- Titration 2nd = 5 dp (1.44661), Boric Acid = 4 dp, absorbance = 3 dp.
 * Largest magnitude anywhere is 27.17, so only the SCALE was ever the problem.
 * NOTE: this cannot recover precision already lost in rows stored under (8,2);
 * re-importing those is a separate decision. */
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID(N'[qc].[plate_bath_measurement]')
             AND name = N'measurement'
             AND (precision <> 10 OR scale <> 5))
BEGIN
    -- measurement is an INCLUDE column of this index; ALTER COLUMN is blocked
    -- while it exists, so drop it here and recreate it below.
    DROP INDEX IF EXISTS [IX_plate_bath_measurement_log_id] ON [qc].[plate_bath_measurement];
    ALTER TABLE [qc].[plate_bath_measurement] ALTER COLUMN [measurement] DECIMAL(10,5) NOT NULL;
END
GO

/* recreate the index (same definition as migration 012) if the ALTER dropped it */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_plate_bath_measurement_log_id'
                 AND object_id = OBJECT_ID(N'[qc].[plate_bath_measurement]'))
    CREATE NONCLUSTERED INDEX [IX_plate_bath_measurement_log_id]
        ON [qc].[plate_bath_measurement] ([plate_bath_log_id])
        INCLUDE ([measurement_number], [measurement], [measurement_type]);
GO

/* ---- 2. re-type post-cutover Ni2+ rows ------------------------------ */
/* Values are NOT touched -- the same millilitres simply mean Ni+Co from the
 * cutover on, because the EDTA titration complexes both metals. */
UPDATE m
   SET m.measurement_type = N'Ni2+ + Co2+ Titration_ml'
FROM [qc].[plate_bath_measurement] m
JOIN [qc].[plate_bath_log] l ON l.id = m.plate_bath_log_id
JOIN [qc].[vat] v            ON v.id = l.vat_id
WHERE m.measurement_type = N'Ni2+ Titration_ml'
  AND (   (v.name = N'Vat. 28' AND l.[date] >= '2026-07-15')
       OR (v.name = N'Vat. 29' AND l.[date] >= '2026-08-14')
       OR (v.name = N'Vat. 30' AND l.[date] >= '2026-08-18'));
PRINT CONCAT(N'Re-typed to Ni2+ + Co2+ Titration_ml: ', @@ROWCOUNT, N' row(s).');
GO

/* ---- 3. views: 3 absorbance columns + accept both Ni labels --------- */
/* Column ORDER is a contract: the app maps table rows back to ids by position,
 * so plate_bath_log_id stays first and [Row added] second. The absorbance
 * columns go after [Boric Acid Titration 2nd (ml)] and before [Notes]. */

CREATE OR ALTER VIEW [qc].[vw_plate_bath_28] AS
SELECT
    l.id          AS plate_bath_log_id,
    l.created_at  AS [Row added],
    l.date        AS [Date],
    l.measured_by AS [Name],
    MAX(CASE WHEN m.measurement_type='pH'                  AND m.measurement_number=1 THEN m.measurement END) AS [pH 1st],
    MAX(CASE WHEN m.measurement_type='pH'                  AND m.measurement_number=2 THEN m.measurement END) AS [pH 2nd],
    -- both labels land in the same column: pre-cutover Ni2+, post-cutover Ni2+ + Co2+
    MAX(CASE WHEN m.measurement_type IN ('Ni2+ Titration_ml','Ni2+ + Co2+ Titration_ml') AND m.measurement_number=1 THEN m.measurement END) AS [Ni2+ Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type IN ('Ni2+ Titration_ml','Ni2+ + Co2+ Titration_ml') AND m.measurement_number=2 THEN m.measurement END) AS [Ni2+ Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='Cl- Titration_ml'       AND m.measurement_number=1 THEN m.measurement END) AS [Cl- Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Cl- Titration_ml'       AND m.measurement_number=2 THEN m.measurement END) AS [Cl- Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='ThioUrea Titration_ml'  AND m.measurement_number=1 THEN m.measurement END) AS [ThioUrea Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='ThioUrea Titration_ml'  AND m.measurement_number=2 THEN m.measurement END) AS [ThioUrea Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='Boric Acid Titration_ml' AND m.measurement_number=1 THEN m.measurement END) AS [Boric Acid Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Boric Acid Titration_ml' AND m.measurement_number=2 THEN m.measurement END) AS [Boric Acid Titration 2nd (ml)],
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
    MAX(CASE WHEN m.measurement_type IN ('Ni2+ Titration_ml','Ni2+ + Co2+ Titration_ml') AND m.measurement_number=1 THEN m.measurement END) AS [Ni2+ Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type IN ('Ni2+ Titration_ml','Ni2+ + Co2+ Titration_ml') AND m.measurement_number=2 THEN m.measurement END) AS [Ni2+ Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='Cl- Titration_ml'       AND m.measurement_number=1 THEN m.measurement END) AS [Cl- Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Cl- Titration_ml'       AND m.measurement_number=2 THEN m.measurement END) AS [Cl- Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='ThioUrea Titration_ml'  AND m.measurement_number=1 THEN m.measurement END) AS [ThioUrea Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='ThioUrea Titration_ml'  AND m.measurement_number=2 THEN m.measurement END) AS [ThioUrea Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='Boric Acid Titration_ml' AND m.measurement_number=1 THEN m.measurement END) AS [Boric Acid Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Boric Acid Titration_ml' AND m.measurement_number=2 THEN m.measurement END) AS [Boric Acid Titration 2nd (ml)],
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
    MAX(CASE WHEN m.measurement_type IN ('Ni2+ Titration_ml','Ni2+ + Co2+ Titration_ml') AND m.measurement_number=1 THEN m.measurement END) AS [Ni2+ Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type IN ('Ni2+ Titration_ml','Ni2+ + Co2+ Titration_ml') AND m.measurement_number=2 THEN m.measurement END) AS [Ni2+ Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='Cl- Titration_ml'       AND m.measurement_number=1 THEN m.measurement END) AS [Cl- Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Cl- Titration_ml'       AND m.measurement_number=2 THEN m.measurement END) AS [Cl- Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='ThioUrea Titration_ml'  AND m.measurement_number=1 THEN m.measurement END) AS [ThioUrea Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='ThioUrea Titration_ml'  AND m.measurement_number=2 THEN m.measurement END) AS [ThioUrea Titration 2nd (ml)],
    MAX(CASE WHEN m.measurement_type='Boric Acid Titration_ml' AND m.measurement_number=1 THEN m.measurement END) AS [Boric Acid Titration 1st (ml)],
    MAX(CASE WHEN m.measurement_type='Boric Acid Titration_ml' AND m.measurement_number=2 THEN m.measurement END) AS [Boric Acid Titration 2nd (ml)],
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

/* ---- 4. procedures: widen the JSON cast to DECIMAL(10,5) ------------ */
/* Signatures unchanged. Bodies reproduced from their LATEST versions (insert
 * from 010, update from 018) with ONLY the cast changed. */

CREATE OR ALTER PROCEDURE [qc].[usp_plate_bath_insert]
    @date DATE, @vat NVARCHAR(255), @measured_by NVARCHAR(255),
    @notes NVARCHAR(255) = NULL, @measurements NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF @date IS NULL THROW 50001, N'Date is required.', 1;
    IF @measured_by IS NULL THROW 50007, N'Measured by is required.', 1;
    IF @measurements IS NOT NULL AND ISJSON(@measurements) = 0 THROW 50006, N'@measurements is not valid JSON.', 1;

    DECLARE @vat_id INT = (SELECT id FROM [qc].[vat] WHERE name = @vat), @log_id INT, @msg NVARCHAR(300);
    IF @vat_id IS NULL BEGIN SET @msg = CONCAT(N'Unknown vat: ', @vat); THROW 50005, @msg, 1; END

    BEGIN TRAN;
    INSERT INTO [qc].[plate_bath_log] (date, vat_id, measured_by, notes)
    VALUES (@date, @vat_id, @measured_by, @notes);
    SET @log_id = SCOPE_IDENTITY();

    -- measurement_type / measurement_number are taken verbatim from the payload:
    -- 'Ni Absorbance_445nm' and measurement_number = 3 need no special handling.
    IF @measurements IS NOT NULL
        INSERT INTO [qc].[plate_bath_measurement] (plate_bath_log_id, measurement_number, measurement, measurement_type)
        SELECT @log_id,
               TRY_CAST(JSON_VALUE(m.value, '$.measurement_number') AS INT),
               TRY_CAST(JSON_VALUE(m.value, '$.measurement')        AS DECIMAL(10,5)),
               JSON_VALUE(m.value, '$.measurement_type')
        FROM OPENJSON(@measurements) m;
    COMMIT TRAN;

    SELECT @log_id AS plate_bath_log_id;
END
GO

CREATE OR ALTER PROCEDURE [qc].[usp_plate_bath_update]
    @plate_bath_log_id INT, @date DATE, @vat NVARCHAR(255), @measured_by NVARCHAR(255),
    @notes NVARCHAR(255) = NULL, @measurements NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF @date IS NULL THROW 50001, N'Date is required.', 1;
    IF @measured_by IS NULL THROW 50007, N'Measured by is required.', 1;
    IF @measurements IS NOT NULL AND ISJSON(@measurements) = 0 THROW 50006, N'@measurements is not valid JSON.', 1;

    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    IF NOT EXISTS (SELECT 1 FROM [qc].[plate_bath_log] WHERE id = @plate_bath_log_id)
        THROW 50002, N'plate_bath_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[plate_bath_log] WHERE id = @plate_bath_log_id);
    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50004, N'Only rows created today or yesterday can be edited.', 1;

    DECLARE @vat_id INT = (SELECT id FROM [qc].[vat] WHERE name = @vat), @msg NVARCHAR(300);
    IF @vat_id IS NULL BEGIN SET @msg = CONCAT(N'Unknown vat: ', @vat); THROW 50005, @msg, 1; END

    BEGIN TRAN;
    UPDATE [qc].[plate_bath_log]
       SET date = @date, vat_id = @vat_id, measured_by = @measured_by, notes = @notes
     WHERE id = @plate_bath_log_id;
    -- REPLACE CHILDREN: every measurement row is rebuilt from @measurements, so
    -- the caller must resend absorbance rows too or they are dropped.
    DELETE FROM [qc].[plate_bath_measurement] WHERE plate_bath_log_id = @plate_bath_log_id;
    IF @measurements IS NOT NULL
        INSERT INTO [qc].[plate_bath_measurement] (plate_bath_log_id, measurement_number, measurement, measurement_type)
        SELECT @plate_bath_log_id,
               TRY_CAST(JSON_VALUE(m.value, '$.measurement_number') AS INT),
               TRY_CAST(JSON_VALUE(m.value, '$.measurement')        AS DECIMAL(10,5)),
               JSON_VALUE(m.value, '$.measurement_type')
        FROM OPENJSON(@measurements) m;
    COMMIT TRAN;
END
GO

/* ---- grants: re-assert on the altered procs (role renamed in 019) ---- */
GRANT EXECUTE ON OBJECT::[qc].[usp_plate_bath_insert] TO [production_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_plate_bath_update] TO [production_data_manager_role];
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'025_plate_cobalt_split.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'025_plate_cobalt_split.sql');
GO

SET NOEXEC OFF;
GO
