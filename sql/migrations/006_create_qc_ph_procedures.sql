/* =====================================================================
 * 006_create_qc_ph_procedures.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: CRUD procedures for the pH Control wide row (vw_ph_control),
 *         fanning one wide row out to ph_log -> ph_log_vat -> ph_measurement,
 *         and a GRANT EXECUTE on each to qc_data_manager_role.
 *         Idempotent via CREATE OR ALTER. Run 001 + 002 first.
 *
 * VARIABLE CHILDREN: vats and their readings are passed as ONE JSON parameter
 * (@vats), parsed with OPENJSON -- so adding a vat or a measurement number is a
 * data change, NOT a signature change. Each vat carries an optional pH-adjust
 * chemical (one per vat) and a list of readings:
 *   [ { "vat": "Vat. 28", "chemical_id": 1, "amount": 2.0,
 *       "readings": [ {"measurement_number": 1, "ph_value": 4.47},
 *                     {"measurement_number": 2, "ph_value": 4.45} ] },
 *     { "vat": "Vat. 31", "readings": [ {"measurement_number": 1, "ph_value": -0.19} ] } ]
 * (The view stays fixed-column -- adding a vat/measurement means adding a column
 * to vw_ph_control, a read-side change; these procs are unaffected.)
 *
 * WRITE INPUTS != READ VIEW: the chemical is passed structured (chemical_id +
 * amount), not as the "2 L NaOH" display label the view builds.
 *
 * UPDATE = REPLACE CHILDREN (ph_log updated in place; its log_vat + measurement
 * rows deleted and rebuilt). UPDATE + DELETE enforce the today/yesterday date
 * guard (DELETION_HANDOFF.md), keyed on ph_log.date.
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
CREATE OR ALTER PROCEDURE [qc].[usp_ph_control_insert]
    @date                DATE,
    @initials            NVARCHAR(255) = NULL,
    @time_of_measurement TIME          = NULL,
    @sample_taken_time   TIME          = NULL,
    @time_when_added     TIME          = NULL,
    @notes               NVARCHAR(255) = NULL,
    @vats                NVARCHAR(MAX) = NULL    -- JSON (see header)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @date IS NULL THROW 50001, N'Date is required.', 1;
    IF @vats IS NOT NULL AND ISJSON(@vats) = 0 THROW 50006, N'@vats is not valid JSON.', 1;

    DECLARE @ph_log_id INT, @lv_id INT, @i INT = 1, @n INT,
            @vat_name NVARCHAR(255), @vat_id INT,
            @chem_id INT, @amount DECIMAL(8,2), @readings NVARCHAR(MAX), @msg NVARCHAR(300);
    DECLARE @vt TABLE (idx INT IDENTITY(1,1) PRIMARY KEY, vat_name NVARCHAR(255),
                       chemical_id INT, amount DECIMAL(8,2), readings NVARCHAR(MAX));

    BEGIN TRAN;

    INSERT INTO [qc].[ph_log] (date, sample_taken_time, time_of_measurement, measured_by, notes)
    VALUES (@date, @sample_taken_time, @time_of_measurement, @initials, @notes);
    SET @ph_log_id = SCOPE_IDENTITY();

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

    SELECT @ph_log_id AS ph_log_id;   -- new row id for the caller
END
GO

/* ---- update (replace children) ------------------------------------- */
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

    -- Edit date guard (DELETION_HANDOFF.md): editable only if the row's CURRENT
    -- date is today or yesterday (Norwegian local; Azure runs UTC).
    DECLARE @today    DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    DECLARE @row_date DATE = (SELECT [date] FROM [qc].[ph_log] WHERE id = @ph_log_id);

    IF @row_date IS NULL
        THROW 50002, N'ph_log id not found.', 1;
    IF @row_date < DATEADD(DAY, -1, @today) OR @row_date > @today
        THROW 50004, N'Only entries from today or yesterday can be edited.', 1;

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

    -- wipe the children, then rebuild from @vats
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

/* ---- delete -------------------------------------------------------- */
CREATE OR ALTER PROCEDURE [qc].[usp_ph_control_delete]
    @ph_log_id INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Deletion date guard (DELETION_HANDOFF.md): a row is deletable only if its
    -- date is today or yesterday; older/future/blank dates are locked. "Today"
    -- is Norwegian local date -- Azure SQL runs in UTC, so derive it via AT TIME
    -- ZONE so the window doesn't drift by a day around midnight.
    DECLARE @today    DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    DECLARE @row_date DATE = (SELECT [date] FROM [qc].[ph_log] WHERE id = @ph_log_id);

    IF @row_date IS NULL
        THROW 50002, N'ph_log id not found.', 1;
    IF @row_date < DATEADD(DAY, -1, @today) OR @row_date > @today
        THROW 50003, N'Only entries from today or yesterday can be deleted.', 1;

    BEGIN TRAN;
    DELETE FROM [qc].[ph_measurement]
     WHERE ph_log_vat_id IN (SELECT id FROM [qc].[ph_log_vat] WHERE ph_log_id = @ph_log_id);
    DELETE FROM [qc].[ph_log_vat] WHERE ph_log_id = @ph_log_id;
    DELETE FROM [qc].[ph_log]     WHERE id = @ph_log_id;
    COMMIT TRAN;
END
GO

/* ---- grants: ONLY these three procedures, to the data-manager role -- */
GRANT EXECUTE ON OBJECT::[qc].[usp_ph_control_insert] TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_ph_control_update] TO [qc_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_ph_control_delete] TO [qc_data_manager_role];
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'006_create_qc_ph_procedures.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'006_create_qc_ph_procedures.sql');
GO

SET NOEXEC OFF;
GO
