/* =====================================================================
 * 011_add_cobalt_dosing.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: SCHEMA change for the new per-electrode chemical Cobalt Sulphate
 *         (CoSO4*7H2O). Same wide, one-column-per-chemical design as TU/BA:
 *           - electrode_production_tracking + co_dose_g_per_electrode (nullable)
 *           - electrode_chemical_dosage     + co_value               (nullable)
 *           - vw_production_tracking         exposes [CoSO4 (g/electrode)]
 *           - usp_production_tracking_insert / _update gain @co_dose (after @ba_dose)
 *         Idempotent (COL_LENGTH guards + CREATE OR ALTER). Run 001-010 first.
 *
 * DATA is NOT touched here. The CoSO4*7H2O catalog row (chemical id 10) arrives
 * via the normal CSV load -- chemical.csv already contains it. On a fresh /
 * reset test DB the run order is:  reset -> 004 -> 011 -> load_data.py, so the
 * column adds land BEFORE the widened CSVs are loaded into the empty tables.
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

/* ---- 1. new columns (nullable; blank/NULL for all historical rows) --- */
IF COL_LENGTH(N'[qc].[electrode_production_tracking]', N'co_dose_g_per_electrode') IS NULL
    ALTER TABLE [qc].[electrode_production_tracking]
        ADD [co_dose_g_per_electrode] DECIMAL(8,1) NULL;   -- g/electrode, matches tu_dose sizing
GO
IF COL_LENGTH(N'[qc].[electrode_chemical_dosage]', N'co_value') IS NULL
    ALTER TABLE [qc].[electrode_chemical_dosage]
        ADD [co_value] INT NULL;                           -- g/electrode, matches tu_value/ba_value type
GO

/* ---- 2. view: expose the cobalt dose (same style as TU/BA) ----------- */
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
    t.ba_dose_g_per_electrode AS [BA (g/electrode)],
    t.co_dose_g_per_electrode AS [CoSO4 (g/electrode)]
FROM [qc].[electrode_production_tracking] t
LEFT JOIN [qc].[electrode_production_vat] ev ON ev.electrode_production_tracking_id = t.id
LEFT JOIN [qc].[vat] v                       ON v.id = ev.vat_id
GROUP BY t.id, t.shift, t.date,
         t.tu_dose_g_per_electrode, t.ba_dose_g_per_electrode, t.co_dose_g_per_electrode;
GO

/* ---- 3. procs: add @co_dose (after @ba_dose) ------------------------- */
/* insert -- identical to 008 plus @co_dose in the signature + INSERT.     */
CREATE OR ALTER PROCEDURE [qc].[usp_production_tracking_insert]
    @shift                    NVARCHAR(255) = NULL,
    @date                     DATE          = NULL,   -- required on insert (throws if NULL)
    @tu_dose                  DECIMAL(8,1)  = NULL,
    @ba_dose                  DECIMAL(7,1)  = NULL,
    @co_dose                  DECIMAL(8,1)  = NULL,
    @chemical_addition_log_id INT           = NULL,   -- provenance; optional
    @vats                     NVARCHAR(MAX) = NULL     -- JSON (see 008 header)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @date IS NULL THROW 50001, N'Date is required.', 1;
    IF @vats IS NOT NULL AND ISJSON(@vats) = 0 THROW 50006, N'@vats is not valid JSON.', 1;

    DECLARE @tracking_id INT, @i INT = 1, @n INT,
            @vat_name NVARCHAR(255), @vat_id INT,
            @prod_sum INT, @prod_shift INT, @msg NVARCHAR(300);
    DECLARE @vt TABLE (idx INT IDENTITY(1,1) PRIMARY KEY, vat_name NVARCHAR(255),
                       prod_sum INT, prod_shift INT);

    BEGIN TRAN;

    INSERT INTO [qc].[electrode_production_tracking]
        (chemical_addition_log_id, shift, date,
         tu_dose_g_per_electrode, ba_dose_g_per_electrode, co_dose_g_per_electrode)
    VALUES (@chemical_addition_log_id, @shift, @date, @tu_dose, @ba_dose, @co_dose);
    SET @tracking_id = SCOPE_IDENTITY();

    IF @vats IS NOT NULL
    BEGIN
        INSERT INTO @vt (vat_name, prod_sum, prod_shift)
        SELECT JSON_VALUE(v.value, '$.vat'),
               TRY_CAST(JSON_VALUE(v.value, '$.prod_electrodes_sum')   AS INT),
               TRY_CAST(JSON_VALUE(v.value, '$.prod_electrodes_shift') AS INT)
        FROM OPENJSON(@vats) v;

        SET @n = (SELECT COUNT(*) FROM @vt);
        WHILE @i <= @n
        BEGIN
            SELECT @vat_name = vat_name, @prod_sum = prod_sum, @prod_shift = prod_shift
            FROM @vt WHERE idx = @i;

            SET @vat_id = (SELECT id FROM [qc].[vat] WHERE name = @vat_name);
            IF @vat_id IS NULL
            BEGIN
                SET @msg = CONCAT(N'Unknown vat in payload: ', @vat_name);
                THROW 50005, @msg, 1;
            END

            INSERT INTO [qc].[electrode_production_vat]
                (electrode_production_tracking_id, vat_id, prod_electrodes_sum, prod_electrodes_shift)
            VALUES (@tracking_id, @vat_id, @prod_sum, @prod_shift);

            SET @i += 1;
        END
    END

    COMMIT TRAN;

    SELECT @tracking_id AS electrode_production_tracking_id;   -- new row id
END
GO

/* update (replace children) -- identical to 008 plus @co_dose.           */
CREATE OR ALTER PROCEDURE [qc].[usp_production_tracking_update]
    @electrode_production_tracking_id INT,
    @shift                    NVARCHAR(255) = NULL,
    @date                     DATE          = NULL,
    @tu_dose                  DECIMAL(8,1)  = NULL,
    @ba_dose                  DECIMAL(7,1)  = NULL,
    @co_dose                  DECIMAL(8,1)  = NULL,
    @chemical_addition_log_id INT           = NULL,
    @vats                     NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @date IS NULL THROW 50001, N'Date is required.', 1;
    IF @vats IS NOT NULL AND ISJSON(@vats) = 0 THROW 50006, N'@vats is not valid JSON.', 1;

    -- Edit date guard. date is NULLABLE here, so check existence separately and
    -- treat a NULL (blank) date as LOCKED (matches the app's blank -> not editable).
    IF NOT EXISTS (SELECT 1 FROM [qc].[electrode_production_tracking] WHERE id = @electrode_production_tracking_id)
        THROW 50002, N'electrode_production_tracking id not found.', 1;

    DECLARE @today    DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    DECLARE @row_date DATE = (SELECT [date] FROM [qc].[electrode_production_tracking] WHERE id = @electrode_production_tracking_id);

    IF @row_date IS NULL OR @row_date < DATEADD(DAY, -1, @today) OR @row_date > @today
        THROW 50004, N'Only entries from today or yesterday can be edited.', 1;

    DECLARE @i INT = 1, @n INT, @vat_name NVARCHAR(255), @vat_id INT,
            @prod_sum INT, @prod_shift INT, @msg NVARCHAR(300);
    DECLARE @vt TABLE (idx INT IDENTITY(1,1) PRIMARY KEY, vat_name NVARCHAR(255),
                       prod_sum INT, prod_shift INT);

    BEGIN TRAN;

    UPDATE [qc].[electrode_production_tracking]
       SET chemical_addition_log_id = @chemical_addition_log_id,
           shift                     = @shift,
           date                      = @date,
           tu_dose_g_per_electrode   = @tu_dose,
           ba_dose_g_per_electrode   = @ba_dose,
           co_dose_g_per_electrode   = @co_dose
     WHERE id = @electrode_production_tracking_id;

    DELETE FROM [qc].[electrode_production_vat]
     WHERE electrode_production_tracking_id = @electrode_production_tracking_id;

    IF @vats IS NOT NULL
    BEGIN
        INSERT INTO @vt (vat_name, prod_sum, prod_shift)
        SELECT JSON_VALUE(v.value, '$.vat'),
               TRY_CAST(JSON_VALUE(v.value, '$.prod_electrodes_sum')   AS INT),
               TRY_CAST(JSON_VALUE(v.value, '$.prod_electrodes_shift') AS INT)
        FROM OPENJSON(@vats) v;

        SET @n = (SELECT COUNT(*) FROM @vt);
        WHILE @i <= @n
        BEGIN
            SELECT @vat_name = vat_name, @prod_sum = prod_sum, @prod_shift = prod_shift
            FROM @vt WHERE idx = @i;

            SET @vat_id = (SELECT id FROM [qc].[vat] WHERE name = @vat_name);
            IF @vat_id IS NULL
            BEGIN
                SET @msg = CONCAT(N'Unknown vat in payload: ', @vat_name);
                THROW 50005, @msg, 1;
            END

            INSERT INTO [qc].[electrode_production_vat]
                (electrode_production_tracking_id, vat_id, prod_electrodes_sum, prod_electrodes_shift)
            VALUES (@electrode_production_tracking_id, @vat_id, @prod_sum, @prod_shift);

            SET @i += 1;
        END
    END

    COMMIT TRAN;
END
GO

/* ---- grants: re-assert EXECUTE on the two altered procs (idempotent) - */
GRANT EXECUTE ON OBJECT::[qc].[usp_production_tracking_insert] TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_production_tracking_update] TO [qc_data_manager_role];
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'011_add_cobalt_dosing.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'011_add_cobalt_dosing.sql');
GO

SET NOEXEC OFF;
GO
