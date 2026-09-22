/* =====================================================================
 * 009_create_qc_conductivity_procedures.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: CRUD procedures for the Conductivity wide row (vw_conductivity),
 *         fanning one wide row out to
 *           conductivity_log -> conductivity_vat_log
 *         and a GRANT EXECUTE on each to qc_data_manager_role.
 *         Idempotent via CREATE OR ALTER. Run 001 + 002 first.
 *
 * Per-rinse readings are passed as ONE JSON parameter:
 *   [ { "vat": "Vat. 14", "rinse_number": 1, "conductivity": 3680 },
 *     { "vat": "Vat. 13", "rinse_number": 2, "conductivity": 808 },
 *     { "vat": "Vat. 11", "rinse_number": 2, "conductivity": 65.7 } ]
 * rinse_number and conductivity are required (NOT NULL). The view maps each vat
 * to its display column; the proc just stores vat + rinse_number + conductivity.
 *
 * UPDATE = REPLACE CHILDREN. UPDATE + DELETE enforce the today/yesterday date
 * guard (DELETION_HANDOFF.md) on conductivity_log.date (NOT NULL here).
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
CREATE OR ALTER PROCEDURE [qc].[usp_conductivity_insert]
    @date        DATE,
    @logged_by   NVARCHAR(255) = NULL,   -- "Name" in the UI
    @observation NVARCHAR(255) = NULL,   -- "Additional observations"
    @vats        NVARCHAR(MAX) = NULL     -- JSON (see header)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @date IS NULL THROW 50001, N'Date is required.', 1;
    IF @vats IS NOT NULL AND ISJSON(@vats) = 0 THROW 50006, N'@vats is not valid JSON.', 1;

    DECLARE @log_id INT, @i INT = 1, @n INT,
            @vat_name NVARCHAR(255), @vat_id INT,
            @rinse_number INT, @conductivity DECIMAL(11,1), @msg NVARCHAR(300);
    DECLARE @vt TABLE (idx INT IDENTITY(1,1) PRIMARY KEY, vat_name NVARCHAR(255),
                       rinse_number INT, conductivity DECIMAL(11,1));

    BEGIN TRAN;

    INSERT INTO [qc].[conductivity_log] (date, logged_by, observation)
    VALUES (@date, @logged_by, @observation);
    SET @log_id = SCOPE_IDENTITY();

    IF @vats IS NOT NULL
    BEGIN
        INSERT INTO @vt (vat_name, rinse_number, conductivity)
        SELECT JSON_VALUE(v.value, '$.vat'),
               TRY_CAST(JSON_VALUE(v.value, '$.rinse_number') AS INT),
               TRY_CAST(JSON_VALUE(v.value, '$.conductivity') AS DECIMAL(11,1))
        FROM OPENJSON(@vats) v;

        SET @n = (SELECT COUNT(*) FROM @vt);
        WHILE @i <= @n
        BEGIN
            SELECT @vat_name = vat_name, @rinse_number = rinse_number, @conductivity = conductivity
            FROM @vt WHERE idx = @i;

            SET @vat_id = (SELECT id FROM [qc].[vat] WHERE name = @vat_name);
            IF @vat_id IS NULL
            BEGIN
                SET @msg = CONCAT(N'Unknown vat in payload: ', @vat_name);
                THROW 50005, @msg, 1;
            END

            INSERT INTO [qc].[conductivity_vat_log] (conductivity_log_id, vat_id, rinse_number, conductivity)
            VALUES (@log_id, @vat_id, @rinse_number, @conductivity);

            SET @i += 1;
        END
    END

    COMMIT TRAN;

    SELECT @log_id AS conductivity_log_id;   -- new row id for the caller
END
GO

/* ---- update (replace children) ------------------------------------- */
CREATE OR ALTER PROCEDURE [qc].[usp_conductivity_update]
    @conductivity_log_id INT,
    @date        DATE,
    @logged_by   NVARCHAR(255) = NULL,
    @observation NVARCHAR(255) = NULL,
    @vats        NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @date IS NULL THROW 50001, N'Date is required.', 1;
    IF @vats IS NOT NULL AND ISJSON(@vats) = 0 THROW 50006, N'@vats is not valid JSON.', 1;

    -- Edit date guard (DELETION_HANDOFF.md): editable only if the row's CURRENT
    -- date is today or yesterday (Norwegian local; Azure runs UTC).
    DECLARE @today    DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    DECLARE @row_date DATE = (SELECT [date] FROM [qc].[conductivity_log] WHERE id = @conductivity_log_id);

    IF @row_date IS NULL
        THROW 50002, N'conductivity_log id not found.', 1;
    IF @row_date < DATEADD(DAY, -1, @today) OR @row_date > @today
        THROW 50004, N'Only entries from today or yesterday can be edited.', 1;

    DECLARE @i INT = 1, @n INT, @vat_name NVARCHAR(255), @vat_id INT,
            @rinse_number INT, @conductivity DECIMAL(11,1), @msg NVARCHAR(300);
    DECLARE @vt TABLE (idx INT IDENTITY(1,1) PRIMARY KEY, vat_name NVARCHAR(255),
                       rinse_number INT, conductivity DECIMAL(11,1));

    BEGIN TRAN;

    UPDATE [qc].[conductivity_log]
       SET date        = @date,
           logged_by   = @logged_by,
           observation = @observation
     WHERE id = @conductivity_log_id;

    DELETE FROM [qc].[conductivity_vat_log] WHERE conductivity_log_id = @conductivity_log_id;

    IF @vats IS NOT NULL
    BEGIN
        INSERT INTO @vt (vat_name, rinse_number, conductivity)
        SELECT JSON_VALUE(v.value, '$.vat'),
               TRY_CAST(JSON_VALUE(v.value, '$.rinse_number') AS INT),
               TRY_CAST(JSON_VALUE(v.value, '$.conductivity') AS DECIMAL(11,1))
        FROM OPENJSON(@vats) v;

        SET @n = (SELECT COUNT(*) FROM @vt);
        WHILE @i <= @n
        BEGIN
            SELECT @vat_name = vat_name, @rinse_number = rinse_number, @conductivity = conductivity
            FROM @vt WHERE idx = @i;

            SET @vat_id = (SELECT id FROM [qc].[vat] WHERE name = @vat_name);
            IF @vat_id IS NULL
            BEGIN
                SET @msg = CONCAT(N'Unknown vat in payload: ', @vat_name);
                THROW 50005, @msg, 1;
            END

            INSERT INTO [qc].[conductivity_vat_log] (conductivity_log_id, vat_id, rinse_number, conductivity)
            VALUES (@conductivity_log_id, @vat_id, @rinse_number, @conductivity);

            SET @i += 1;
        END
    END

    COMMIT TRAN;
END
GO

/* ---- delete -------------------------------------------------------- */
CREATE OR ALTER PROCEDURE [qc].[usp_conductivity_delete]
    @conductivity_log_id INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @today    DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    DECLARE @row_date DATE = (SELECT [date] FROM [qc].[conductivity_log] WHERE id = @conductivity_log_id);

    IF @row_date IS NULL
        THROW 50002, N'conductivity_log id not found.', 1;
    IF @row_date < DATEADD(DAY, -1, @today) OR @row_date > @today
        THROW 50003, N'Only entries from today or yesterday can be deleted.', 1;

    BEGIN TRAN;
    DELETE FROM [qc].[conductivity_vat_log] WHERE conductivity_log_id = @conductivity_log_id;
    DELETE FROM [qc].[conductivity_log]     WHERE id = @conductivity_log_id;
    COMMIT TRAN;
END
GO

/* ---- grants: ONLY these three procedures ---------------------------- */
GRANT EXECUTE ON OBJECT::[qc].[usp_conductivity_insert] TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_conductivity_update] TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_conductivity_delete] TO [qc_data_manager_role];
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'009_create_qc_conductivity_procedures.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'009_create_qc_conductivity_procedures.sql');
GO

SET NOEXEC OFF;
GO
