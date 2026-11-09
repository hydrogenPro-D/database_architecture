/* =====================================================================
 * 008_create_qc_production_procedures.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: CRUD procedures for the Production Tracking wide row
 *         (vw_production_tracking), fanning one wide row out to
 *           electrode_production_tracking -> electrode_production_vat
 *         and a GRANT EXECUTE on each to qc_data_manager_role.
 *         Idempotent via CREATE OR ALTER. Run 001 + 002 first.
 *
 * Per-vat counts (plating vats 28/29/30) are passed as ONE JSON parameter:
 *   [ { "vat": "Vat. 28", "prod_electrodes_sum": 1200, "prod_electrodes_shift": 40 },
 *     { "vat": "Vat. 30", "prod_electrodes_sum": 1000, "prod_electrodes_shift": -2 } ]
 * prod_electrodes_sum is required (cumulative); prod_electrodes_shift is optional
 * and may be negative (a known source typo, kept as-is).
 *
 * TWO production-specific points:
 *  - electrode_production_tracking.date is NULLABLE in the table (some loaded
 *    rows have no date). NEW writes still REQUIRE @date (insert + update), so we
 *    don't create blank-dated rows. The date guard checks existence separately
 *    and treats any existing NULL/blank date as LOCKED -- matching the app rule
 *    (blank/unparseable -> not editable/deletable), which covers legacy rows.
 *  - @chemical_addition_log_id is provenance (not shown in the UI); optional.
 *
 * UPDATE = REPLACE CHILDREN. UPDATE + DELETE enforce the today/yesterday date
 * guard (DELETION_HANDOFF.md) on electrode_production_tracking.date.
 *
 * Multi-batch (CREATE PROCEDURE must lead its batch) -> RAISERROR + SET NOEXEC.
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

/* ---- insert -------------------------------------------------------- */
CREATE OR ALTER PROCEDURE [qc].[usp_production_tracking_insert]
    @shift                    NVARCHAR(255) = NULL,
    @date                     DATE          = NULL,   -- required on insert (throws if NULL)
    @tu_dose                  DECIMAL(8,1)  = NULL,
    @ba_dose                  DECIMAL(7,1)  = NULL,
    @chemical_addition_log_id INT           = NULL,   -- provenance; optional
    @vats                     NVARCHAR(MAX) = NULL     -- JSON (see header)
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
        (chemical_addition_log_id, shift, date, tu_dose_g_per_electrode, ba_dose_g_per_electrode)
    VALUES (@chemical_addition_log_id, @shift, @date, @tu_dose, @ba_dose);
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

/* ---- update (replace children) ------------------------------------- */
CREATE OR ALTER PROCEDURE [qc].[usp_production_tracking_update]
    @electrode_production_tracking_id INT,
    @shift                    NVARCHAR(255) = NULL,
    @date                     DATE          = NULL,
    @tu_dose                  DECIMAL(8,1)  = NULL,
    @ba_dose                  DECIMAL(7,1)  = NULL,
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
           ba_dose_g_per_electrode   = @ba_dose
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

/* ---- delete -------------------------------------------------------- */
CREATE OR ALTER PROCEDURE [qc].[usp_production_tracking_delete]
    @electrode_production_tracking_id INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM [qc].[electrode_production_tracking] WHERE id = @electrode_production_tracking_id)
        THROW 50002, N'electrode_production_tracking id not found.', 1;

    DECLARE @today    DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    DECLARE @row_date DATE = (SELECT [date] FROM [qc].[electrode_production_tracking] WHERE id = @electrode_production_tracking_id);

    IF @row_date IS NULL OR @row_date < DATEADD(DAY, -1, @today) OR @row_date > @today
        THROW 50003, N'Only entries from today or yesterday can be deleted.', 1;

    BEGIN TRAN;
    DELETE FROM [qc].[electrode_production_vat]
     WHERE electrode_production_tracking_id = @electrode_production_tracking_id;
    DELETE FROM [qc].[electrode_production_tracking]
     WHERE id = @electrode_production_tracking_id;
    COMMIT TRAN;
END
GO

/* ---- grants: ONLY these three procedures ---------------------------- */
GRANT EXECUTE ON OBJECT::[qc].[usp_production_tracking_insert] TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_production_tracking_update] TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_production_tracking_delete] TO [qc_data_manager_role];
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'008_create_qc_production_procedures.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'008_create_qc_production_procedures.sql');
GO

SET NOEXEC OFF;
GO
