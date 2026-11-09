/* =====================================================================
 * 016_conductivity_strike_stage.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: split Vat. 25 / pos.25 into a Strike stage (CONDUCTIVITY_STRIKE_DB_SPEC.md):
 *   1. conductivity_vat_log + [stage] NVARCHAR(20); backfill historical rows by
 *      vat (all existing pos.25 rows are the old plating rinse -> 'Plating').
 *   2. usp_conductivity_insert / _update read a per-reading "stage" from @vats and
 *      persist it.
 *   3. vw_conductivity: rename the four plating aliases (pos.24/23/22/21 ->
 *      Plating Rinse 1..4), add [Strike Rinse 1 - pos.25 (µS/cm)] = Vat. 25 rows
 *      with stage='Strike'. Legacy pos.25 plating rows stay in the TABLE but are
 *      dropped from the app-facing view (app no longer reads them).
 *   Idempotent (COL_LENGTH guard, NULL-only backfill, CREATE OR ALTER). Run 001-015 first.
 *
 * Pivot is BY VAT (plus stage for Vat. 25): historical pos.24-21 rows keep their
 * old rinse_number (2..5) while new rows use (1..4), so keying on rinse_number
 * would split a tank across columns -- vat keeps each one continuous.
 *
 * Run this file UTF-8: the view aliases contain the micro sign 'µ'.
 * Multi-batch (ALTER-then-use, CREATE VIEW/PROCEDURE) -> RAISERROR + SET NOEXEC.
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

/* ---- 1a. add the stage column (own batch: later batches reference it) - */
IF COL_LENGTH(N'[qc].[conductivity_vat_log]', N'stage') IS NULL
    ALTER TABLE [qc].[conductivity_vat_log] ADD [stage] NVARCHAR(20) NULL;
GO

/* ---- 1b. backfill ONLY the rows the column-add left NULL ------------- */
/* The WHERE stage IS NULL guard makes this idempotent AND safe: re-running never
 * clobbers a stage the app has since written (e.g. new Vat. 25 stage='Strike'). */
UPDATE cvl
   SET [stage] = CASE v.[name]
        WHEN 'Vat. 14' THEN 'Cathodic'
        WHEN 'Vat. 13' THEN 'Cathodic'
        WHEN 'Vat. 12' THEN 'Cathodic'
        WHEN 'Vat. 19' THEN 'Activation'
        WHEN 'Vat. 20' THEN 'Activation'
        WHEN 'Vat. 25' THEN 'Plating'   -- historical pos.25 = plating rinse 1
        WHEN 'Vat. 24' THEN 'Plating'
        WHEN 'Vat. 23' THEN 'Plating'
        WHEN 'Vat. 22' THEN 'Plating'
        WHEN 'Vat. 21' THEN 'Plating'
   END
FROM [qc].[conductivity_vat_log] cvl
JOIN [qc].[vat] v ON v.[id] = cvl.[vat_id]
WHERE cvl.[stage] IS NULL;
GO

/* ---- 2. procs: carry a per-reading stage from @vats ----------------- */
CREATE OR ALTER PROCEDURE [qc].[usp_conductivity_insert]
    @date        DATE,
    @logged_by   NVARCHAR(255) = NULL,   -- "Name" in the UI
    @observation NVARCHAR(255) = NULL,   -- "Additional observations"
    @vats        NVARCHAR(MAX) = NULL     -- JSON: [{vat, stage, rinse_number, conductivity}, ...]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @date IS NULL THROW 50001, N'Date is required.', 1;
    IF @vats IS NOT NULL AND ISJSON(@vats) = 0 THROW 50006, N'@vats is not valid JSON.', 1;

    DECLARE @log_id INT, @i INT = 1, @n INT,
            @vat_name NVARCHAR(255), @vat_id INT, @stage NVARCHAR(20),
            @rinse_number INT, @conductivity DECIMAL(11,1), @msg NVARCHAR(300);
    DECLARE @vt TABLE (idx INT IDENTITY(1,1) PRIMARY KEY, vat_name NVARCHAR(255),
                       stage NVARCHAR(20), rinse_number INT, conductivity DECIMAL(11,1));

    BEGIN TRAN;

    INSERT INTO [qc].[conductivity_log] (date, logged_by, observation)
    VALUES (@date, @logged_by, @observation);
    SET @log_id = SCOPE_IDENTITY();

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
            VALUES (@log_id, @vat_id, @stage, @rinse_number, @conductivity);

            SET @i += 1;
        END
    END

    COMMIT TRAN;

    SELECT @log_id AS conductivity_log_id;   -- new row id for the caller
END
GO

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

/* ---- 3. view: rename plating aliases + add Strike pos.25 ------------- */
/* Keyed by vat (plus stage for Vat. 25). Legacy Vat. 25 stage='Plating' rows are
 * retained in the table but intentionally NOT surfaced here. */
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
    MAX(CASE WHEN v.name = 'Vat. 25' AND cvl.stage = 'Strike' THEN cvl.conductivity END) AS [Strike Rinse 1 - pos.25 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 24' THEN cvl.conductivity END) AS [Plating Rinse 1 - pos.24 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 23' THEN cvl.conductivity END) AS [Plating Rinse 2 - pos.23 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 22' THEN cvl.conductivity END) AS [Plating Rinse 3 - pos.22 (µS/cm)],
    MAX(CASE WHEN v.name = 'Vat. 21' THEN cvl.conductivity END) AS [Plating Rinse 4 - pos.21 (µS/cm)],
    l.observation AS [Additional observations]
FROM [qc].[conductivity_log] l
LEFT JOIN [qc].[conductivity_vat_log] cvl ON cvl.conductivity_log_id = l.id
LEFT JOIN [qc].[vat] v                    ON v.id = cvl.vat_id
GROUP BY l.id, l.date, l.logged_by, l.observation;
GO

/* ---- grants: re-assert EXECUTE on the two altered procs (idempotent) - */
GRANT EXECUTE ON OBJECT::[qc].[usp_conductivity_insert] TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_conductivity_update] TO [qc_data_manager_role];
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'016_conductivity_strike_stage.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'016_conductivity_strike_stage.sql');
GO

SET NOEXEC OFF;
GO
