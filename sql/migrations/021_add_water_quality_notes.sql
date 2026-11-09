/* =====================================================================
 * 021_add_water_quality_notes.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: add a free-text [notes] column to the Water Quality tab (020).
 *     1. ALTER qc.water_quality_log ADD notes NVARCHAR(MAX) NULL (COL_LENGTH guard).
 *     2. qc.vw_water_quality re-created to expose it AS [Notes] (before [Row added]).
 *     3. usp_water_quality_insert / _update re-created to accept @notes.
 *   Delete proc unchanged. Idempotent (COL_LENGTH guard + CREATE OR ALTER).
 *   Run 001-020 first.
 *
 * This is a SEPARATE migration (not an edit to 020) because 020 is already
 * applied: its CREATE TABLE is OBJECT_ID-guarded and would skip on re-run, so the
 * column has to be added with ALTER here. 020 stays as-applied history.
 *
 * NOTE: notes is NVARCHAR(MAX) per request. Every other log table uses
 * NVARCHAR(255) for notes -- kept MAX here as asked; change to (255) for parity
 * if desired.
 *
 * CREATE OR ALTER preserves the EXECUTE grants from 020, but we re-assert them
 * below (belt-and-suspenders, as in 018). Run UTF-8 (view alias contains 'µ').
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
IF OBJECT_ID(N'[qc].[water_quality_log]', N'U') IS NULL
BEGIN
    RAISERROR(N'Run 020 first (creates water_quality_log).', 16, 1);
    SET NOEXEC ON;
END;
GO

/* ---- 1. add the column (idempotent) --------------------------------- */
IF COL_LENGTH(N'[qc].[water_quality_log]', N'notes') IS NULL
    ALTER TABLE [qc].[water_quality_log] ADD [notes] NVARCHAR(MAX) NULL;
GO

/* ---- 2. view: expose [Notes] (before [Row added]) ------------------- */
CREATE OR ALTER VIEW [qc].[vw_water_quality] AS
SELECT
    l.id                  AS id,                        -- MUST stay column 1
    l.date                AS [Date],                    -- real DATE
    l.time_of_measurement AS [Time of measurement],     -- real TIME
    l.operator            AS [Operator],
    l.conductivity        AS [Conductivity (µS/cm)],
    l.ph                  AS [pH],
    l.notes               AS [Notes],
    l.created_at          AS [Row added]
FROM [qc].[water_quality_log] AS l;
GO

/* ---- 3. insert (returns new id) now accepts @notes ------------------ */
CREATE OR ALTER PROCEDURE [qc].[usp_water_quality_insert]
    @date                DATE,
    @time_of_measurement TIME          = NULL,
    @operator            NVARCHAR(255) = NULL,
    @conductivity        DECIMAL(12,2) = NULL,
    @ph                  DECIMAL(4,2)  = NULL,
    @notes               NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @date IS NULL THROW 50001, N'Date is required.', 1;

    -- created_at is stamped by the column DEFAULT (Norway local) -- do not set it here.
    INSERT INTO [qc].[water_quality_log] (date, time_of_measurement, operator, conductivity, ph, notes)
    VALUES (@date, @time_of_measurement, @operator, @conductivity, @ph, @notes);

    SELECT CAST(SCOPE_IDENTITY() AS INT) AS id;   -- app reads fetchone()[0]
END
GO

/* ---- 4. update now sets notes (created_at untouched; guard preserved) - */
CREATE OR ALTER PROCEDURE [qc].[usp_water_quality_update]
    @water_quality_log_id INT,
    @date                 DATE,
    @time_of_measurement  TIME          = NULL,
    @operator             NVARCHAR(255) = NULL,
    @conductivity         DECIMAL(12,2) = NULL,
    @ph                   DECIMAL(4,2)  = NULL,
    @notes                NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @date IS NULL THROW 50001, N'Date is required.', 1;

    -- Edit guard (018 pattern): editable only if CREATED today or yesterday
    -- (created_at, Norway local). NULL created_at (pre-feature history) is locked.
    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    IF NOT EXISTS (SELECT 1 FROM [qc].[water_quality_log] WHERE id = @water_quality_log_id)
        THROW 50002, N'water_quality_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[water_quality_log] WHERE id = @water_quality_log_id);
    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50004, N'Only rows created today or yesterday can be edited.', 1;

    UPDATE [qc].[water_quality_log]
       SET date                = @date,
           time_of_measurement = @time_of_measurement,
           operator            = @operator,
           conductivity        = @conductivity,
           ph                  = @ph,
           notes               = @notes
     WHERE id = @water_quality_log_id;   -- created_at intentionally untouched
END
GO

/* ---- 5. re-assert grants (preserved by CREATE OR ALTER, re-stated) --- */
GRANT EXECUTE ON OBJECT::[qc].[usp_water_quality_insert] TO [production_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_water_quality_update] TO [production_data_manager_role];
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'021_add_water_quality_notes.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'021_add_water_quality_notes.sql');
GO

SET NOEXEC OFF;
GO
