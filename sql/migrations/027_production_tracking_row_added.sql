/* =====================================================================
 * 027_production_tracking_row_added.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: PRODUCTION_TRACKING_ROW_ADDED_SPEC.md -- give the Production Tracking
 *   tab the "Row added" timestamp every other tab already has. This is the
 *   017 + 018 treatment for the one log table they deliberately skipped.
 *     1. electrode_production_tracking + created_at DATETIME2(0) NULL, with a
 *        Norway-local DEFAULT so inserts auto-stamp it. Existing rows stay NULL
 *        (the app treats a blank "Row added" as not editable).
 *     2. vw_production_tracking exposes it AS [Row added], immediately after
 *        electrode_production_tracking_id, matching the other views.
 *     3. usp_production_tracking_update / _delete gate editability on created_at
 *        instead of the entered date.
 *   Idempotent (COL_LENGTH guard + CREATE OR ALTER). Run 001-026 first.
 *
 * WHY THE DELETE PROC IS INCLUDED (the spec only names _update)
 * ------------------------------------------------------------
 * usp_production_tracking_delete carries the IDENTICAL date-based guard
 * (THROW 50003, judged on the entered date). The spec's own argument applies to
 * it word for word: a row entered today but dated earlier would be offered for
 * deletion by the application and refused by the procedure. Migration 018 switched
 * update AND delete together for the other seven entities, so both are switched
 * here. Leaving _delete on the old rule would recreate the exact mismatch this
 * migration exists to remove.
 *
 * NOT CHANGED
 * -----------
 *   - usp_production_tracking_insert: the column DEFAULT stamps created_at, so the
 *     insert proc needs no new parameter and is left exactly as 011 left it.
 *   - The view's column ORDER and row ordering are otherwise untouched: the app
 *     maps table rows back to ids by position.
 *   - No backfill. Existing rows keep created_at NULL = locked, which is the same
 *     convention 017 used for pre-feature history.
 *
 * ONE APP-VISIBLE DETAIL: the guard messages now say "rows created today or
 * yesterday" rather than "entries from today or yesterday", matching the wording
 * 018 uses everywhere else. The error CODES are unchanged (50004 edit, 50003
 * delete, 50002 not found), so anything keying on the code is unaffected.
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
IF OBJECT_ID(N'[qc].[electrode_production_tracking]', N'U') IS NULL
BEGIN
    RAISERROR(N'Run 004 first (creates the production tracking tables).', 16, 1);
    SET NOEXEC ON;
END;
GO

/* ---- 1. created_at on the tracking table ---------------------------- */
/* Nullable + Norway-local DEFAULT: new rows auto-stamp, existing rows stay NULL.
 * Norway local (not raw SYSDATETIME, which is UTC on Azure) so the created-
 * today/yesterday window below does not drift a day around midnight -- same
 * convention as migration 017. */
IF COL_LENGTH(N'[qc].[electrode_production_tracking]', N'created_at') IS NULL
    ALTER TABLE [qc].[electrode_production_tracking] ADD [created_at] DATETIME2(0) NULL
        CONSTRAINT [DF_electrode_production_tracking_created_at]
        DEFAULT (CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATETIME2(0)));
GO

/* ---- 2. view exposes [Row added] right after the id ----------------- */
/* Reproduced from 011 (cobalt dosing) with ONLY the new column added. */
CREATE OR ALTER VIEW [qc].[vw_production_tracking] AS
SELECT
    t.id         AS electrode_production_tracking_id,
    t.created_at AS [Row added],
    t.shift      AS [Shift],
    t.date       AS [Date],
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
GROUP BY t.id, t.created_at, t.shift, t.date,
         t.tu_dose_g_per_electrode, t.ba_dose_g_per_electrode, t.co_dose_g_per_electrode;
GO

/* ---- 3. update: gate on created_at, not the entered date ------------ */
/* Body reproduced from 011 with ONLY the guard block changed. */
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

    -- Edit guard (018 pattern): editable only if the row was CREATED today or
    -- yesterday (created_at, Norway local). NULL created_at (pre-feature history)
    -- is locked. Existence is checked separately so a missing id is 50002.
    IF NOT EXISTS (SELECT 1 FROM [qc].[electrode_production_tracking] WHERE id = @electrode_production_tracking_id)
        THROW 50002, N'electrode_production_tracking id not found.', 1;

    DECLARE @today   DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[electrode_production_tracking] WHERE id = @electrode_production_tracking_id);

    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50004, N'Only rows created today or yesterday can be edited.', 1;

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
     WHERE id = @electrode_production_tracking_id;   -- created_at intentionally untouched

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

/* ---- 4. delete: same switch, for the same reason -------------------- */
/* Body reproduced from 008 with ONLY the guard block changed. */
CREATE OR ALTER PROCEDURE [qc].[usp_production_tracking_delete]
    @electrode_production_tracking_id INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM [qc].[electrode_production_tracking] WHERE id = @electrode_production_tracking_id)
        THROW 50002, N'electrode_production_tracking id not found.', 1;

    DECLARE @today   DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[electrode_production_tracking] WHERE id = @electrode_production_tracking_id);

    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50003, N'Only rows created today or yesterday can be deleted.', 1;

    BEGIN TRAN;
    DELETE FROM [qc].[electrode_production_vat]
     WHERE electrode_production_tracking_id = @electrode_production_tracking_id;
    DELETE FROM [qc].[electrode_production_tracking]
     WHERE id = @electrode_production_tracking_id;
    COMMIT TRAN;
END
GO

/* ---- grants: re-assert on the altered procs (role renamed in 019) --- */
GRANT EXECUTE ON OBJECT::[qc].[usp_production_tracking_update] TO [production_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_production_tracking_delete] TO [production_data_manager_role];
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'027_production_tracking_row_added.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'027_production_tracking_row_added.sql');
GO

SET NOEXEC OFF;
GO
