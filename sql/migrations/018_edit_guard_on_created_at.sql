/* =====================================================================
 * 018_edit_guard_on_created_at.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: BEHAVIOURAL half of the "Row added" feature (ROW_ADDED_DB_SPEC.md req 2).
 *   The update + delete procs of the 7 event entities now gate editability on
 *   created_at (created today/yesterday) instead of the user-entered date. This
 *   fixes the bug where a row created today but back-dated a week could not be
 *   edited. Rules:
 *     - created_at today or yesterday  -> allowed
 *     - created_at IS NULL (pre-feature history) -> LOCKED (matches the app
 *       treating a blank "Row added" as non-editable)
 *     - existence is now checked separately, so a missing id is 50002 (not found)
 *       while a real row with NULL/old created_at is 50004/50003 (locked).
 *   "Today" is Norway local (Azure runs UTC), same convention as before.
 *
 * Insert procs are unchanged: 017 gave created_at a DEFAULT, so inserts auto-stamp.
 * Each proc below is reproduced from its LATEST version (adding-chemicals from 015,
 * conductivity from 016) with ONLY the guard block changed. Idempotent via
 * CREATE OR ALTER. Run 001-017 first.
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

/* =====================  pH CONTROL  ================================== */
CREATE OR ALTER PROCEDURE [qc].[usp_ph_control_update]
    @ph_log_id           INT,
    @date                DATE,
    @initials            NVARCHAR(255) = NULL,
    @time_of_measurement TIME          = NULL,
    @sample_taken_time   TIME          = NULL,
    @time_when_added     TIME          = NULL,
    @notes               NVARCHAR(255) = NULL,
    @vats                NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @date IS NULL THROW 50001, N'Date is required.', 1;
    IF @vats IS NOT NULL AND ISJSON(@vats) = 0 THROW 50006, N'@vats is not valid JSON.', 1;

    -- Edit guard: editable only if the row was CREATED today or yesterday
    -- (created_at, Norway local). NULL created_at (pre-feature history) is locked.
    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    IF NOT EXISTS (SELECT 1 FROM [qc].[ph_log] WHERE id = @ph_log_id)
        THROW 50002, N'ph_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[ph_log] WHERE id = @ph_log_id);
    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50004, N'Only rows created today or yesterday can be edited.', 1;

    DECLARE @lv_id INT, @i INT = 1, @n INT,
            @vat_name NVARCHAR(255), @vat_id INT,
            @chem_id INT, @amount DECIMAL(8,2), @readings NVARCHAR(MAX), @msg NVARCHAR(300);
    DECLARE @vt TABLE (idx INT IDENTITY(1,1) PRIMARY KEY, vat_name NVARCHAR(255),
                       chemical_id INT, amount DECIMAL(8,2), readings NVARCHAR(MAX));

    BEGIN TRAN;

    UPDATE [qc].[ph_log]
       SET date                = @date,
           sample_taken_time   = @sample_taken_time,
           time_of_measurement = @time_of_measurement,
           measured_by         = @initials,
           notes               = @notes
     WHERE id = @ph_log_id;

    DELETE FROM [qc].[ph_measurement]
     WHERE ph_log_vat_id IN (SELECT id FROM [qc].[ph_log_vat] WHERE ph_log_id = @ph_log_id);
    DELETE FROM [qc].[ph_log_vat] WHERE ph_log_id = @ph_log_id;

    IF @vats IS NOT NULL
    BEGIN
        INSERT INTO @vt (vat_name, chemical_id, amount, readings)
        SELECT JSON_VALUE(v.value, '$.vat'),
               TRY_CAST(JSON_VALUE(v.value, '$.chemical_id') AS INT),
               TRY_CAST(JSON_VALUE(v.value, '$.amount')      AS DECIMAL(8,2)),
               JSON_QUERY(v.value, '$.readings')
        FROM OPENJSON(@vats) v;

        SET @n = (SELECT COUNT(*) FROM @vt);
        WHILE @i <= @n
        BEGIN
            SELECT @vat_name = vat_name, @chem_id = chemical_id, @amount = amount, @readings = readings
            FROM @vt WHERE idx = @i;

            SET @vat_id = (SELECT id FROM [qc].[vat] WHERE name = @vat_name);
            IF @vat_id IS NULL
            BEGIN
                SET @msg = CONCAT(N'Unknown vat in payload: ', @vat_name);
                THROW 50005, @msg, 1;
            END

            INSERT INTO [qc].[ph_log_vat] (vat_id, ph_log_id, chemical_id, chemical_amount, chemical_addition_time)
            VALUES (@vat_id, @ph_log_id, @chem_id, @amount,
                    CASE WHEN @chem_id IS NOT NULL OR @amount IS NOT NULL THEN @time_when_added END);
            SET @lv_id = SCOPE_IDENTITY();

            IF @readings IS NOT NULL
                INSERT INTO [qc].[ph_measurement] (ph_log_vat_id, measurement_number, ph_value)
                SELECT @lv_id,
                       TRY_CAST(JSON_VALUE(r.value, '$.measurement_number') AS INT),
                       TRY_CAST(JSON_VALUE(r.value, '$.ph_value')           AS DECIMAL(7,2))
                FROM OPENJSON(@readings) r;

            SET @i += 1;
        END
    END

    COMMIT TRAN;
END
GO

CREATE OR ALTER PROCEDURE [qc].[usp_ph_control_delete]
    @ph_log_id INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Delete guard: deletable only if CREATED today or yesterday (created_at).
    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    IF NOT EXISTS (SELECT 1 FROM [qc].[ph_log] WHERE id = @ph_log_id)
        THROW 50002, N'ph_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[ph_log] WHERE id = @ph_log_id);
    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50003, N'Only rows created today or yesterday can be deleted.', 1;

    BEGIN TRAN;
    DELETE FROM [qc].[ph_measurement]
     WHERE ph_log_vat_id IN (SELECT id FROM [qc].[ph_log_vat] WHERE ph_log_id = @ph_log_id);
    DELETE FROM [qc].[ph_log_vat] WHERE ph_log_id = @ph_log_id;
    DELETE FROM [qc].[ph_log]     WHERE id = @ph_log_id;
    COMMIT TRAN;
END
GO

/* =====================  ADDING CHEMICALS (body from 015)  =========== */
CREATE OR ALTER PROCEDURE [qc].[usp_adding_chemicals_update]
    @chemical_addition_log_id INT,
    @date            DATE,
    @added_by        NVARCHAR(255) = NULL,
    @time_when_added TIME          = NULL,
    @notes           NVARCHAR(255) = NULL,
    @vats            NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @date IS NULL THROW 50001, N'Date is required.', 1;
    IF @vats IS NOT NULL AND ISJSON(@vats) = 0 THROW 50006, N'@vats is not valid JSON.', 1;

    -- Edit guard: editable only if CREATED today or yesterday (created_at).
    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    IF NOT EXISTS (SELECT 1 FROM [qc].[chemical_addition_log] WHERE id = @chemical_addition_log_id)
        THROW 50002, N'chemical_addition_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[chemical_addition_log] WHERE id = @chemical_addition_log_id);
    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50004, N'Only rows created today or yesterday can be edited.', 1;

    DECLARE @lv_id INT, @i INT = 1, @n INT,
            @vat_name NVARCHAR(255), @vat_id INT, @water INT,
            @chems NVARCHAR(MAX), @msg NVARCHAR(300);
    DECLARE @vt TABLE (idx INT IDENTITY(1,1) PRIMARY KEY,
                       vat_name NVARCHAR(255), water_level INT, chemicals NVARCHAR(MAX));

    BEGIN TRAN;

    UPDATE [qc].[chemical_addition_log]
       SET date            = @date,
           time_when_added = @time_when_added,
           added_by        = @added_by,
           notes           = @notes
     WHERE id = @chemical_addition_log_id;

    DELETE FROM [qc].[chemical_addition]
     WHERE chemical_addition_log_vat_id IN
           (SELECT id FROM [qc].[chemical_addition_log_vat] WHERE chemical_addition_log_id = @chemical_addition_log_id);
    DELETE FROM [qc].[chemical_addition_log_vat]
     WHERE chemical_addition_log_id = @chemical_addition_log_id;

    IF @vats IS NOT NULL
    BEGIN
        INSERT INTO @vt (vat_name, water_level, chemicals)
        SELECT JSON_VALUE(v.value, '$.vat'),
               TRY_CAST(JSON_VALUE(v.value, '$.water_level') AS INT),
               JSON_QUERY(v.value, '$.chemicals')
        FROM OPENJSON(@vats) v;

        SET @n = (SELECT COUNT(*) FROM @vt);
        WHILE @i <= @n
        BEGIN
            SELECT @vat_name = vat_name, @water = water_level, @chems = chemicals
            FROM @vt WHERE idx = @i;

            SET @vat_id = (SELECT id FROM [qc].[vat] WHERE name = @vat_name);
            IF @vat_id IS NULL
            BEGIN
                SET @msg = CONCAT(N'Unknown vat in payload: ', @vat_name);
                THROW 50005, @msg, 1;
            END

            INSERT INTO [qc].[chemical_addition_log_vat] (vat_id, chemical_addition_log_id, water_level_reduction)
            VALUES (@vat_id, @chemical_addition_log_id, @water);
            SET @lv_id = SCOPE_IDENTITY();

            IF @chems IS NOT NULL
                INSERT INTO [qc].[chemical_addition] (chemical_addition_log_vat_id, chemical_id, chemical_amount, concentration)
                SELECT @lv_id,
                       TRY_CAST(JSON_VALUE(c.value, '$.chemical_id')   AS INT),
                       TRY_CAST(JSON_VALUE(c.value, '$.amount')        AS DECIMAL(10,3)),
                       TRY_CAST(JSON_VALUE(c.value, '$.concentration') AS DECIMAL(5,2))
                FROM OPENJSON(@chems) c;

            SET @i += 1;
        END
    END

    COMMIT TRAN;
END
GO

CREATE OR ALTER PROCEDURE [qc].[usp_adding_chemicals_delete]
    @chemical_addition_log_id INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    IF NOT EXISTS (SELECT 1 FROM [qc].[chemical_addition_log] WHERE id = @chemical_addition_log_id)
        THROW 50002, N'chemical_addition_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[chemical_addition_log] WHERE id = @chemical_addition_log_id);
    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50003, N'Only rows created today or yesterday can be deleted.', 1;

    BEGIN TRAN;
    DELETE FROM [qc].[chemical_addition]
     WHERE chemical_addition_log_vat_id IN
           (SELECT id FROM [qc].[chemical_addition_log_vat] WHERE chemical_addition_log_id = @chemical_addition_log_id);
    DELETE FROM [qc].[chemical_addition_log_vat]
     WHERE chemical_addition_log_id = @chemical_addition_log_id;
    DELETE FROM [qc].[chemical_addition_log]
     WHERE id = @chemical_addition_log_id;
    COMMIT TRAN;
END
GO

/* =====================  CONDUCTIVITY (body from 016)  =============== */
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

    -- Edit guard: editable only if CREATED today or yesterday (created_at).
    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    IF NOT EXISTS (SELECT 1 FROM [qc].[conductivity_log] WHERE id = @conductivity_log_id)
        THROW 50002, N'conductivity_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[conductivity_log] WHERE id = @conductivity_log_id);
    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50004, N'Only rows created today or yesterday can be edited.', 1;

    DECLARE @i INT = 1, @n INT, @vat_name NVARCHAR(255), @vat_id INT, @stage NVARCHAR(20),
            @rinse_number INT, @conductivity DECIMAL(11,1), @msg NVARCHAR(300);
    DECLARE @vt TABLE (idx INT IDENTITY(1,1) PRIMARY KEY, vat_name NVARCHAR(255),
                       stage NVARCHAR(20), rinse_number INT, conductivity DECIMAL(11,1));

    BEGIN TRAN;

    UPDATE [qc].[conductivity_log]
       SET date        = @date,
           logged_by   = @logged_by,
           observation = @observation
     WHERE id = @conductivity_log_id;

    DELETE FROM [qc].[conductivity_vat_log] WHERE conductivity_log_id = @conductivity_log_id;

    IF @vats IS NOT NULL
    BEGIN
        INSERT INTO @vt (vat_name, stage, rinse_number, conductivity)
        SELECT JSON_VALUE(v.value, '$.vat'),
               JSON_VALUE(v.value, '$.stage'),
               TRY_CAST(JSON_VALUE(v.value, '$.rinse_number') AS INT),
               TRY_CAST(JSON_VALUE(v.value, '$.conductivity') AS DECIMAL(11,1))
        FROM OPENJSON(@vats) v;

        SET @n = (SELECT COUNT(*) FROM @vt);
        WHILE @i <= @n
        BEGIN
            SELECT @vat_name = vat_name, @stage = stage,
                   @rinse_number = rinse_number, @conductivity = conductivity
            FROM @vt WHERE idx = @i;

            SET @vat_id = (SELECT id FROM [qc].[vat] WHERE name = @vat_name);
            IF @vat_id IS NULL
            BEGIN
                SET @msg = CONCAT(N'Unknown vat in payload: ', @vat_name);
                THROW 50005, @msg, 1;
            END

            INSERT INTO [qc].[conductivity_vat_log] (conductivity_log_id, vat_id, stage, rinse_number, conductivity)
            VALUES (@conductivity_log_id, @vat_id, @stage, @rinse_number, @conductivity);

            SET @i += 1;
        END
    END

    COMMIT TRAN;
END
GO

CREATE OR ALTER PROCEDURE [qc].[usp_conductivity_delete]
    @conductivity_log_id INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    IF NOT EXISTS (SELECT 1 FROM [qc].[conductivity_log] WHERE id = @conductivity_log_id)
        THROW 50002, N'conductivity_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[conductivity_log] WHERE id = @conductivity_log_id);
    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50003, N'Only rows created today or yesterday can be deleted.', 1;

    BEGIN TRAN;
    DELETE FROM [qc].[conductivity_vat_log] WHERE conductivity_log_id = @conductivity_log_id;
    DELETE FROM [qc].[conductivity_log]     WHERE id = @conductivity_log_id;
    COMMIT TRAN;
END
GO

/* =====================  BATHS: CLEANER / ACTIVATOR / STRIKE / PLATE == */
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
    IF NOT EXISTS (SELECT 1 FROM [qc].[cleaner_bath_log] WHERE id = @cleaner_bath_log_id)
        THROW 50002, N'cleaner_bath_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[cleaner_bath_log] WHERE id = @cleaner_bath_log_id);
    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50004, N'Only rows created today or yesterday can be edited.', 1;

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
    IF NOT EXISTS (SELECT 1 FROM [qc].[cleaner_bath_log] WHERE id = @cleaner_bath_log_id)
        THROW 50002, N'cleaner_bath_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[cleaner_bath_log] WHERE id = @cleaner_bath_log_id);
    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50003, N'Only rows created today or yesterday can be deleted.', 1;

    BEGIN TRAN;
    DELETE FROM [qc].[cleaner_bath_measurement] WHERE cleaner_bath_log_id = @cleaner_bath_log_id;
    DELETE FROM [qc].[cleaner_bath_log]         WHERE id = @cleaner_bath_log_id;
    COMMIT TRAN;
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
    IF NOT EXISTS (SELECT 1 FROM [qc].[activator_bath_log] WHERE id = @activator_bath_log_id)
        THROW 50002, N'activator_bath_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[activator_bath_log] WHERE id = @activator_bath_log_id);
    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50004, N'Only rows created today or yesterday can be edited.', 1;

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
    IF NOT EXISTS (SELECT 1 FROM [qc].[activator_bath_log] WHERE id = @activator_bath_log_id)
        THROW 50002, N'activator_bath_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[activator_bath_log] WHERE id = @activator_bath_log_id);
    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50003, N'Only rows created today or yesterday can be deleted.', 1;

    BEGIN TRAN;
    DELETE FROM [qc].[activator_bath_measurement] WHERE activator_bath_log_id = @activator_bath_log_id;
    DELETE FROM [qc].[activator_bath_log]         WHERE id = @activator_bath_log_id;
    COMMIT TRAN;
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
    IF NOT EXISTS (SELECT 1 FROM [qc].[strike_bath_log] WHERE id = @strike_bath_log_id)
        THROW 50002, N'strike_bath_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[strike_bath_log] WHERE id = @strike_bath_log_id);
    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50004, N'Only rows created today or yesterday can be edited.', 1;

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
    IF NOT EXISTS (SELECT 1 FROM [qc].[strike_bath_log] WHERE id = @strike_bath_log_id)
        THROW 50002, N'strike_bath_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[strike_bath_log] WHERE id = @strike_bath_log_id);
    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50003, N'Only rows created today or yesterday can be deleted.', 1;

    BEGIN TRAN;
    DELETE FROM [qc].[strike_bath_measurement] WHERE strike_bath_log_id = @strike_bath_log_id;
    DELETE FROM [qc].[strike_bath_log]         WHERE id = @strike_bath_log_id;
    COMMIT TRAN;
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
    IF NOT EXISTS (SELECT 1 FROM [qc].[plate_bath_log] WHERE id = @plate_bath_log_id)
        THROW 50002, N'plate_bath_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[plate_bath_log] WHERE id = @plate_bath_log_id);
    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50003, N'Only rows created today or yesterday can be deleted.', 1;

    BEGIN TRAN;
    DELETE FROM [qc].[plate_bath_measurement] WHERE plate_bath_log_id = @plate_bath_log_id;
    DELETE FROM [qc].[plate_bath_log]         WHERE id = @plate_bath_log_id;
    COMMIT TRAN;
END
GO

/* ---- grants: re-assert EXECUTE on every altered proc (idempotent) --- */
GRANT EXECUTE ON OBJECT::[qc].[usp_ph_control_update]        TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_ph_control_delete]        TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_adding_chemicals_update]  TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_adding_chemicals_delete]  TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_conductivity_update]      TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_conductivity_delete]      TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_cleaner_bath_update]      TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_cleaner_bath_delete]      TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_activator_bath_update]    TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_activator_bath_delete]    TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_strike_bath_update]       TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_strike_bath_delete]       TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_plate_bath_update]        TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_plate_bath_delete]        TO [qc_data_manager_role];
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'018_edit_guard_on_created_at.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'018_edit_guard_on_created_at.sql');
GO

SET NOEXEC OFF;
GO
