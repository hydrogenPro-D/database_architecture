/* =====================================================================
 * 015_fix_adding_chemicals_concentration.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: BUGFIX for usp_adding_chemicals_insert / _update -- the per-chemical
 *         concentration (HCl %, e.g. 30) was silently stored as NULL.
 *
 * Root cause: the app sends "concentration": 30.0 (a JSON number WITH a decimal),
 * so JSON_VALUE returns the string '30.0', and TRY_CAST('30.0' AS INT) yields NULL
 * (T-SQL can't cast a decimal-looking string straight to INT). The fix casts via
 * DECIMAL(5,2), which parses '30.0' and then stores into the existing INT column
 * as 30. Everything else in these two procs is unchanged from 007.
 *
 * Only rows saved through the app were affected; ETL-loaded rows kept their %.
 * (The column stays INT -- fine for whole-percent values like 30. If fractional
 * percentages are ever needed, that's a separate column-type ALTER migration.)
 *
 * Idempotent via CREATE OR ALTER. Run 001-014 (in particular 007) first.
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

/* ---- insert (identical to 007 except the concentration cast) -------- */
CREATE OR ALTER PROCEDURE [qc].[usp_adding_chemicals_insert]
    @date            DATE,
    @added_by        NVARCHAR(255) = NULL,   -- "Initials" in the UI
    @time_when_added TIME          = NULL,
    @notes           NVARCHAR(255) = NULL,
    @vats            NVARCHAR(MAX) = NULL     -- JSON (see 007 header)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @date IS NULL THROW 50001, N'Date is required.', 1;
    IF @vats IS NOT NULL AND ISJSON(@vats) = 0 THROW 50006, N'@vats is not valid JSON.', 1;

    DECLARE @log_id INT, @lv_id INT, @i INT = 1, @n INT,
            @vat_name NVARCHAR(255), @vat_id INT, @water INT,
            @chems NVARCHAR(MAX), @msg NVARCHAR(300);
    DECLARE @vt TABLE (idx INT IDENTITY(1,1) PRIMARY KEY,
                       vat_name NVARCHAR(255), water_level INT, chemicals NVARCHAR(MAX));

    BEGIN TRAN;

    INSERT INTO [qc].[chemical_addition_log] (date, time_when_added, added_by, notes)
    VALUES (@date, @time_when_added, @added_by, @notes);
    SET @log_id = SCOPE_IDENTITY();

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
            VALUES (@vat_id, @log_id, @water);
            SET @lv_id = SCOPE_IDENTITY();

            IF @chems IS NOT NULL
                INSERT INTO [qc].[chemical_addition] (chemical_addition_log_vat_id, chemical_id, chemical_amount, concentration)
                SELECT @lv_id,
                       TRY_CAST(JSON_VALUE(c.value, '$.chemical_id')   AS INT),
                       TRY_CAST(JSON_VALUE(c.value, '$.amount')        AS DECIMAL(10,3)),
                       TRY_CAST(JSON_VALUE(c.value, '$.concentration') AS DECIMAL(5,2))   -- was AS INT (dropped '30.0')
                FROM OPENJSON(@chems) c;

            SET @i += 1;
        END
    END

    COMMIT TRAN;

    SELECT @log_id AS chemical_addition_log_id;   -- new row id for the caller
END
GO

/* ---- update (identical to 007 except the concentration cast) -------- */
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

    -- Edit date guard (DELETION_HANDOFF.md): editable only if the row's CURRENT
    -- date is today or yesterday (Norwegian local; Azure runs UTC).
    DECLARE @today    DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    DECLARE @row_date DATE = (SELECT [date] FROM [qc].[chemical_addition_log] WHERE id = @chemical_addition_log_id);

    IF @row_date IS NULL
        THROW 50002, N'chemical_addition_log id not found.', 1;
    IF @row_date < DATEADD(DAY, -1, @today) OR @row_date > @today
        THROW 50004, N'Only entries from today or yesterday can be edited.', 1;

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

    -- wipe grandchildren + children, then rebuild from @vats
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
                       TRY_CAST(JSON_VALUE(c.value, '$.concentration') AS DECIMAL(5,2))   -- was AS INT (dropped '30.0')
                FROM OPENJSON(@chems) c;

            SET @i += 1;
        END
    END

    COMMIT TRAN;
END
GO

/* ---- grants: re-assert EXECUTE on the two altered procs (idempotent) - */
GRANT EXECUTE ON OBJECT::[qc].[usp_adding_chemicals_insert] TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_adding_chemicals_update] TO [qc_data_manager_role];
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'015_fix_adding_chemicals_concentration.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'015_fix_adding_chemicals_concentration.sql');
GO

SET NOEXEC OFF;
GO
