/* =====================================================================
 * 010_create_qc_bath_procedures.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: CRUD procedures for the FOUR bath wide rows (cleaner / activator /
 *         strike / plate), each fanning out to
 *           <bath>_bath_log -> <bath>_bath_measurement
 *         plus a GRANT EXECUTE on each (12 procs total) to qc_data_manager_role.
 *         Idempotent via CREATE OR ALTER. Run 001 + 002 first.
 *
 * The four baths share one structure, so the 4 sets are identical except for the
 * table names. ALL take @vat (no hardcoded vat): cleaner='Vat. 17',
 * activator='Vat. 18', strike='Vat. 31', plate='Vat. 28'/'29'/'30'.
 *
 * Measurements are one child grain (all under the single log), so they go in via
 * one set-based INSERT..SELECT from OPENJSON -- no loop:
 *   [ {"measurement_type": "pH", "measurement_number": 1, "measurement": 4.58},
 *     {"measurement_type": "Ni2+ Titration_ml", "measurement_number": 1, "measurement": 10.14} ]
 *
 * Required (NOT NULL columns): @date, @vat, @measured_by.
 * UPDATE = REPLACE CHILDREN. UPDATE + DELETE enforce the today/yesterday date
 * guard (DELETION_HANDOFF.md) on <bath>_bath_log.date.
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

/* =====================  CLEANER  ===================================== */
CREATE OR ALTER PROCEDURE [qc].[usp_cleaner_bath_insert]
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
    INSERT INTO [qc].[cleaner_bath_log] (date, vat_id, measured_by, notes)
    VALUES (@date, @vat_id, @measured_by, @notes);
    SET @log_id = SCOPE_IDENTITY();

    IF @measurements IS NOT NULL
        INSERT INTO [qc].[cleaner_bath_measurement] (cleaner_bath_log_id, measurement_number, measurement, measurement_type)
        SELECT @log_id,
               TRY_CAST(JSON_VALUE(m.value, '$.measurement_number') AS INT),
               TRY_CAST(JSON_VALUE(m.value, '$.measurement')        AS DECIMAL(8,2)),
               JSON_VALUE(m.value, '$.measurement_type')
        FROM OPENJSON(@measurements) m;
    COMMIT TRAN;

    SELECT @log_id AS cleaner_bath_log_id;
END
GO
CREATE OR ALTER PROCEDURE [qc].[usp_cleaner_bath_update]
    @cleaner_bath_log_id INT, @date DATE, @vat NVARCHAR(255), @measured_by NVARCHAR(255),
    @notes NVARCHAR(255) = NULL, @measurements NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF @date IS NULL THROW 50001, N'Date is required.', 1;
    IF @measured_by IS NULL THROW 50007, N'Measured by is required.', 1;
    IF @measurements IS NOT NULL AND ISJSON(@measurements) = 0 THROW 50006, N'@measurements is not valid JSON.', 1;

    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    DECLARE @row_date DATE = (SELECT [date] FROM [qc].[cleaner_bath_log] WHERE id = @cleaner_bath_log_id);
    IF @row_date IS NULL THROW 50002, N'cleaner_bath_log id not found.', 1;
    IF @row_date < DATEADD(DAY, -1, @today) OR @row_date > @today
        THROW 50004, N'Only entries from today or yesterday can be edited.', 1;

    DECLARE @vat_id INT = (SELECT id FROM [qc].[vat] WHERE name = @vat), @msg NVARCHAR(300);
    IF @vat_id IS NULL BEGIN SET @msg = CONCAT(N'Unknown vat: ', @vat); THROW 50005, @msg, 1; END

    BEGIN TRAN;
    UPDATE [qc].[cleaner_bath_log]
       SET date = @date, vat_id = @vat_id, measured_by = @measured_by, notes = @notes
     WHERE id = @cleaner_bath_log_id;
    DELETE FROM [qc].[cleaner_bath_measurement] WHERE cleaner_bath_log_id = @cleaner_bath_log_id;
    IF @measurements IS NOT NULL
        INSERT INTO [qc].[cleaner_bath_measurement] (cleaner_bath_log_id, measurement_number, measurement, measurement_type)
        SELECT @cleaner_bath_log_id,
               TRY_CAST(JSON_VALUE(m.value, '$.measurement_number') AS INT),
               TRY_CAST(JSON_VALUE(m.value, '$.measurement')        AS DECIMAL(8,2)),
               JSON_VALUE(m.value, '$.measurement_type')
        FROM OPENJSON(@measurements) m;
    COMMIT TRAN;
END
GO
CREATE OR ALTER PROCEDURE [qc].[usp_cleaner_bath_delete]
    @cleaner_bath_log_id INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    DECLARE @row_date DATE = (SELECT [date] FROM [qc].[cleaner_bath_log] WHERE id = @cleaner_bath_log_id);
    IF @row_date IS NULL THROW 50002, N'cleaner_bath_log id not found.', 1;
    IF @row_date < DATEADD(DAY, -1, @today) OR @row_date > @today
        THROW 50003, N'Only entries from today or yesterday can be deleted.', 1;

    BEGIN TRAN;
    DELETE FROM [qc].[cleaner_bath_measurement] WHERE cleaner_bath_log_id = @cleaner_bath_log_id;
    DELETE FROM [qc].[cleaner_bath_log]         WHERE id = @cleaner_bath_log_id;
    COMMIT TRAN;
END
GO

/* =====================  ACTIVATOR  ================================== */
CREATE OR ALTER PROCEDURE [qc].[usp_activator_bath_insert]
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
    INSERT INTO [qc].[activator_bath_log] (date, vat_id, measured_by, notes)
    VALUES (@date, @vat_id, @measured_by, @notes);
    SET @log_id = SCOPE_IDENTITY();

    IF @measurements IS NOT NULL
        INSERT INTO [qc].[activator_bath_measurement] (activator_bath_log_id, measurement_number, measurement, measurement_type)
        SELECT @log_id,
               TRY_CAST(JSON_VALUE(m.value, '$.measurement_number') AS INT),
               TRY_CAST(JSON_VALUE(m.value, '$.measurement')        AS DECIMAL(8,2)),
               JSON_VALUE(m.value, '$.measurement_type')
        FROM OPENJSON(@measurements) m;
    COMMIT TRAN;

    SELECT @log_id AS activator_bath_log_id;
END
GO
CREATE OR ALTER PROCEDURE [qc].[usp_activator_bath_update]
    @activator_bath_log_id INT, @date DATE, @vat NVARCHAR(255), @measured_by NVARCHAR(255),
    @notes NVARCHAR(255) = NULL, @measurements NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF @date IS NULL THROW 50001, N'Date is required.', 1;
    IF @measured_by IS NULL THROW 50007, N'Measured by is required.', 1;
    IF @measurements IS NOT NULL AND ISJSON(@measurements) = 0 THROW 50006, N'@measurements is not valid JSON.', 1;

    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    DECLARE @row_date DATE = (SELECT [date] FROM [qc].[activator_bath_log] WHERE id = @activator_bath_log_id);
    IF @row_date IS NULL THROW 50002, N'activator_bath_log id not found.', 1;
    IF @row_date < DATEADD(DAY, -1, @today) OR @row_date > @today
        THROW 50004, N'Only entries from today or yesterday can be edited.', 1;

    DECLARE @vat_id INT = (SELECT id FROM [qc].[vat] WHERE name = @vat), @msg NVARCHAR(300);
    IF @vat_id IS NULL BEGIN SET @msg = CONCAT(N'Unknown vat: ', @vat); THROW 50005, @msg, 1; END

    BEGIN TRAN;
    UPDATE [qc].[activator_bath_log]
       SET date = @date, vat_id = @vat_id, measured_by = @measured_by, notes = @notes
     WHERE id = @activator_bath_log_id;
    DELETE FROM [qc].[activator_bath_measurement] WHERE activator_bath_log_id = @activator_bath_log_id;
    IF @measurements IS NOT NULL
        INSERT INTO [qc].[activator_bath_measurement] (activator_bath_log_id, measurement_number, measurement, measurement_type)
        SELECT @activator_bath_log_id,
               TRY_CAST(JSON_VALUE(m.value, '$.measurement_number') AS INT),
               TRY_CAST(JSON_VALUE(m.value, '$.measurement')        AS DECIMAL(8,2)),
               JSON_VALUE(m.value, '$.measurement_type')
        FROM OPENJSON(@measurements) m;
    COMMIT TRAN;
END
GO
CREATE OR ALTER PROCEDURE [qc].[usp_activator_bath_delete]
    @activator_bath_log_id INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    DECLARE @row_date DATE = (SELECT [date] FROM [qc].[activator_bath_log] WHERE id = @activator_bath_log_id);
    IF @row_date IS NULL THROW 50002, N'activator_bath_log id not found.', 1;
    IF @row_date < DATEADD(DAY, -1, @today) OR @row_date > @today
        THROW 50003, N'Only entries from today or yesterday can be deleted.', 1;

    BEGIN TRAN;
    DELETE FROM [qc].[activator_bath_measurement] WHERE activator_bath_log_id = @activator_bath_log_id;
    DELETE FROM [qc].[activator_bath_log]         WHERE id = @activator_bath_log_id;
    COMMIT TRAN;
END
GO

/* =====================  STRIKE  ===================================== */
CREATE OR ALTER PROCEDURE [qc].[usp_strike_bath_insert]
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
    INSERT INTO [qc].[strike_bath_log] (date, vat_id, measured_by, notes)
    VALUES (@date, @vat_id, @measured_by, @notes);
    SET @log_id = SCOPE_IDENTITY();

    IF @measurements IS NOT NULL
        INSERT INTO [qc].[strike_bath_measurement] (strike_bath_log_id, measurement_number, measurement, measurement_type)
        SELECT @log_id,
               TRY_CAST(JSON_VALUE(m.value, '$.measurement_number') AS INT),
               TRY_CAST(JSON_VALUE(m.value, '$.measurement')        AS DECIMAL(8,2)),
               JSON_VALUE(m.value, '$.measurement_type')
        FROM OPENJSON(@measurements) m;
    COMMIT TRAN;

    SELECT @log_id AS strike_bath_log_id;
END
GO
CREATE OR ALTER PROCEDURE [qc].[usp_strike_bath_update]
    @strike_bath_log_id INT, @date DATE, @vat NVARCHAR(255), @measured_by NVARCHAR(255),
    @notes NVARCHAR(255) = NULL, @measurements NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF @date IS NULL THROW 50001, N'Date is required.', 1;
    IF @measured_by IS NULL THROW 50007, N'Measured by is required.', 1;
    IF @measurements IS NOT NULL AND ISJSON(@measurements) = 0 THROW 50006, N'@measurements is not valid JSON.', 1;

    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    DECLARE @row_date DATE = (SELECT [date] FROM [qc].[strike_bath_log] WHERE id = @strike_bath_log_id);
    IF @row_date IS NULL THROW 50002, N'strike_bath_log id not found.', 1;
    IF @row_date < DATEADD(DAY, -1, @today) OR @row_date > @today
        THROW 50004, N'Only entries from today or yesterday can be edited.', 1;

    DECLARE @vat_id INT = (SELECT id FROM [qc].[vat] WHERE name = @vat), @msg NVARCHAR(300);
    IF @vat_id IS NULL BEGIN SET @msg = CONCAT(N'Unknown vat: ', @vat); THROW 50005, @msg, 1; END

    BEGIN TRAN;
    UPDATE [qc].[strike_bath_log]
       SET date = @date, vat_id = @vat_id, measured_by = @measured_by, notes = @notes
     WHERE id = @strike_bath_log_id;
    DELETE FROM [qc].[strike_bath_measurement] WHERE strike_bath_log_id = @strike_bath_log_id;
    IF @measurements IS NOT NULL
        INSERT INTO [qc].[strike_bath_measurement] (strike_bath_log_id, measurement_number, measurement, measurement_type)
        SELECT @strike_bath_log_id,
               TRY_CAST(JSON_VALUE(m.value, '$.measurement_number') AS INT),
               TRY_CAST(JSON_VALUE(m.value, '$.measurement')        AS DECIMAL(8,2)),
               JSON_VALUE(m.value, '$.measurement_type')
        FROM OPENJSON(@measurements) m;
    COMMIT TRAN;
END
GO
CREATE OR ALTER PROCEDURE [qc].[usp_strike_bath_delete]
    @strike_bath_log_id INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    DECLARE @row_date DATE = (SELECT [date] FROM [qc].[strike_bath_log] WHERE id = @strike_bath_log_id);
    IF @row_date IS NULL THROW 50002, N'strike_bath_log id not found.', 1;
    IF @row_date < DATEADD(DAY, -1, @today) OR @row_date > @today
        THROW 50003, N'Only entries from today or yesterday can be deleted.', 1;

    BEGIN TRAN;
    DELETE FROM [qc].[strike_bath_measurement] WHERE strike_bath_log_id = @strike_bath_log_id;
    DELETE FROM [qc].[strike_bath_log]         WHERE id = @strike_bath_log_id;
    COMMIT TRAN;
END
GO

/* =====================  PLATE (vat 28/29/30 via @vat)  ============== */
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

    IF @measurements IS NOT NULL
        INSERT INTO [qc].[plate_bath_measurement] (plate_bath_log_id, measurement_number, measurement, measurement_type)
        SELECT @log_id,
               TRY_CAST(JSON_VALUE(m.value, '$.measurement_number') AS INT),
               TRY_CAST(JSON_VALUE(m.value, '$.measurement')        AS DECIMAL(8,2)),
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
    DECLARE @row_date DATE = (SELECT [date] FROM [qc].[plate_bath_log] WHERE id = @plate_bath_log_id);
    IF @row_date IS NULL THROW 50002, N'plate_bath_log id not found.', 1;
    IF @row_date < DATEADD(DAY, -1, @today) OR @row_date > @today
        THROW 50004, N'Only entries from today or yesterday can be edited.', 1;

    DECLARE @vat_id INT = (SELECT id FROM [qc].[vat] WHERE name = @vat), @msg NVARCHAR(300);
    IF @vat_id IS NULL BEGIN SET @msg = CONCAT(N'Unknown vat: ', @vat); THROW 50005, @msg, 1; END

    BEGIN TRAN;
    UPDATE [qc].[plate_bath_log]
       SET date = @date, vat_id = @vat_id, measured_by = @measured_by, notes = @notes
     WHERE id = @plate_bath_log_id;
    DELETE FROM [qc].[plate_bath_measurement] WHERE plate_bath_log_id = @plate_bath_log_id;
    IF @measurements IS NOT NULL
        INSERT INTO [qc].[plate_bath_measurement] (plate_bath_log_id, measurement_number, measurement, measurement_type)
        SELECT @plate_bath_log_id,
               TRY_CAST(JSON_VALUE(m.value, '$.measurement_number') AS INT),
               TRY_CAST(JSON_VALUE(m.value, '$.measurement')        AS DECIMAL(8,2)),
               JSON_VALUE(m.value, '$.measurement_type')
        FROM OPENJSON(@measurements) m;
    COMMIT TRAN;
END
GO
CREATE OR ALTER PROCEDURE [qc].[usp_plate_bath_delete]
    @plate_bath_log_id INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    DECLARE @row_date DATE = (SELECT [date] FROM [qc].[plate_bath_log] WHERE id = @plate_bath_log_id);
    IF @row_date IS NULL THROW 50002, N'plate_bath_log id not found.', 1;
    IF @row_date < DATEADD(DAY, -1, @today) OR @row_date > @today
        THROW 50003, N'Only entries from today or yesterday can be deleted.', 1;

    BEGIN TRAN;
    DELETE FROM [qc].[plate_bath_measurement] WHERE plate_bath_log_id = @plate_bath_log_id;
    DELETE FROM [qc].[plate_bath_log]         WHERE id = @plate_bath_log_id;
    COMMIT TRAN;
END
GO

/* ---- grants: ONLY these twelve procedures --------------------------- */
GRANT EXECUTE ON OBJECT::[qc].[usp_cleaner_bath_insert]   TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_cleaner_bath_update]   TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_cleaner_bath_delete]   TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_activator_bath_insert] TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_activator_bath_update] TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_activator_bath_delete] TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_strike_bath_insert]    TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_strike_bath_update]    TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_strike_bath_delete]    TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_plate_bath_insert]     TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_plate_bath_update]     TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_plate_bath_delete]     TO [qc_data_manager_role];
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'010_create_qc_bath_procedures.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'010_create_qc_bath_procedures.sql');
GO

SET NOEXEC OFF;
GO
