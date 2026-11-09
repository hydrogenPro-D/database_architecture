/* =====================================================================
 * 023_add_contamination_notes.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: add a free-text [notes] column to the Contamination Log tab (022),
 *   matching the Notes column every other tab already has.
 *     1. ALTER qc.contamination_log ADD notes NVARCHAR(255) NULL (COL_LENGTH guard).
 *     2. qc.vw_contamination re-created to expose it AS [Notes] (before [Row added]).
 *     3. usp_contamination_insert / _update re-created to accept @notes.
 *   Delete proc unchanged. Idempotent (COL_LENGTH guard + CREATE OR ALTER).
 *   Run 001-022 first.
 *
 * NOTE ON "Row added": contamination already has it -- 022 shipped created_at +
 * vw_contamination's [Row added] from the start, so no change is needed for that.
 * This migration is only the Notes column.
 *
 * Separate migration (not an edit to 022) because 022 is already applied: its
 * CREATE TABLE is OBJECT_ID-guarded and would skip on re-run, so the column has
 * to be added with ALTER here. 022 stays as-applied history.
 *
 * TYPE: NVARCHAR(255) to match the original tabs' notes columns (and DB_HANDOFF
 * "names/notes fit NVARCHAR(255)"). The Water Quality tab (021) used MAX by
 * request -- say the word if you want parity with that instead.
 *
 * CREATE OR ALTER preserves the EXECUTE grants from 022; re-asserted below
 * (belt-and-suspenders, as in 018). Run UTF-8.
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
IF OBJECT_ID(N'[qc].[contamination_log]', N'U') IS NULL
BEGIN
    RAISERROR(N'Run 022 first (creates contamination_log).', 16, 1);
    SET NOEXEC ON;
END;
GO

/* ---- 1. add the column (idempotent) --------------------------------- */
IF COL_LENGTH(N'[qc].[contamination_log]', N'notes') IS NULL
    ALTER TABLE [qc].[contamination_log] ADD [notes] NVARCHAR(255) NULL;
GO

/* ---- 2. view: expose [Notes] (before [Row added]) ------------------- */
CREATE OR ALTER VIEW [qc].[vw_contamination] AS
SELECT
    l.id              AS id,                        -- MUST stay column 1
    l.sampling_date   AS [Sampling date],           -- real DATE
    l.sample_taken_by AS [Sample taken by],
    MAX(CASE WHEN m.vat='Pos.28' AND m.metal='Cr' THEN m.value END) AS [Pos.28 Cr],
    MAX(CASE WHEN m.vat='Pos.28' AND m.metal='Cu' THEN m.value END) AS [Pos.28 Cu],
    MAX(CASE WHEN m.vat='Pos.28' AND m.metal='Fe' THEN m.value END) AS [Pos.28 Fe],
    MAX(CASE WHEN m.vat='Pos.28' AND m.metal='Zn' THEN m.value END) AS [Pos.28 Zn],
    MAX(CASE WHEN m.vat='Pos.28' AND m.metal='Pb' THEN m.value END) AS [Pos.28 Pb],
    MAX(CASE WHEN m.vat='Pos.29' AND m.metal='Cr' THEN m.value END) AS [Pos.29 Cr],
    MAX(CASE WHEN m.vat='Pos.29' AND m.metal='Cu' THEN m.value END) AS [Pos.29 Cu],
    MAX(CASE WHEN m.vat='Pos.29' AND m.metal='Fe' THEN m.value END) AS [Pos.29 Fe],
    MAX(CASE WHEN m.vat='Pos.29' AND m.metal='Zn' THEN m.value END) AS [Pos.29 Zn],
    MAX(CASE WHEN m.vat='Pos.29' AND m.metal='Pb' THEN m.value END) AS [Pos.29 Pb],
    MAX(CASE WHEN m.vat='Pos.30' AND m.metal='Cr' THEN m.value END) AS [Pos.30 Cr],
    MAX(CASE WHEN m.vat='Pos.30' AND m.metal='Cu' THEN m.value END) AS [Pos.30 Cu],
    MAX(CASE WHEN m.vat='Pos.30' AND m.metal='Fe' THEN m.value END) AS [Pos.30 Fe],
    MAX(CASE WHEN m.vat='Pos.30' AND m.metal='Zn' THEN m.value END) AS [Pos.30 Zn],
    MAX(CASE WHEN m.vat='Pos.30' AND m.metal='Pb' THEN m.value END) AS [Pos.30 Pb],
    MAX(CASE WHEN m.vat='Pos.31' AND m.metal='Cr' THEN m.value END) AS [Pos.31 Cr],
    MAX(CASE WHEN m.vat='Pos.31' AND m.metal='Cu' THEN m.value END) AS [Pos.31 Cu],
    MAX(CASE WHEN m.vat='Pos.31' AND m.metal='Fe' THEN m.value END) AS [Pos.31 Fe],
    MAX(CASE WHEN m.vat='Pos.31' AND m.metal='Zn' THEN m.value END) AS [Pos.31 Zn],
    MAX(CASE WHEN m.vat='Pos.31' AND m.metal='Pb' THEN m.value END) AS [Pos.31 Pb],
    l.notes           AS [Notes],
    l.created_at      AS [Row added]
FROM [qc].[contamination_log] AS l
LEFT JOIN [qc].[contamination_measurement] AS m ON m.contamination_log_id = l.id
WHERE l.line = 'Plating Line 1'
GROUP BY l.id, l.sampling_date, l.sample_taken_by, l.notes, l.created_at;
GO

/* ---- 3. insert (returns new id) now accepts @notes ------------------ */
CREATE OR ALTER PROCEDURE [qc].[usp_contamination_insert]
    @line            NVARCHAR(50),
    @sampling_date   DATE,
    @sample_taken_by NVARCHAR(100) = NULL,
    @measurements    NVARCHAR(MAX) = NULL,   -- JSON: [{"vat":"Pos.28","metal":"Cr","value":"<2"}, ...]
    @notes           NVARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @sampling_date IS NULL THROW 50001, N'Sampling date is required.', 1;
    IF @line IS NULL THROW 50008, N'Line is required.', 1;
    IF @measurements IS NOT NULL AND ISJSON(@measurements) = 0 THROW 50006, N'@measurements is not valid JSON.', 1;

    DECLARE @id INT;

    BEGIN TRAN;
    -- created_at is stamped by the column DEFAULT (Norway local) -- do not set it here.
    INSERT INTO [qc].[contamination_log] (line, sampling_date, sample_taken_by, notes)
    VALUES (@line, @sampling_date, @sample_taken_by, @notes);
    SET @id = CAST(SCOPE_IDENTITY() AS INT);

    IF @measurements IS NOT NULL
        INSERT INTO [qc].[contamination_measurement] (contamination_log_id, vat, metal, value)
        SELECT @id, j.vat, j.metal, j.value
        FROM OPENJSON(@measurements)
             WITH (vat NVARCHAR(20), metal NVARCHAR(4), value NVARCHAR(30)) AS j;
    COMMIT TRAN;

    SELECT @id AS id;   -- app reads fetchone()[0]
END
GO

/* ---- 4. update now sets notes (created_at + line untouched; guard) --- */
CREATE OR ALTER PROCEDURE [qc].[usp_contamination_update]
    @contamination_log_id INT,
    @sampling_date        DATE,
    @sample_taken_by      NVARCHAR(100) = NULL,
    @measurements         NVARCHAR(MAX) = NULL,
    @notes                NVARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @sampling_date IS NULL THROW 50001, N'Sampling date is required.', 1;
    IF @measurements IS NOT NULL AND ISJSON(@measurements) = 0 THROW 50006, N'@measurements is not valid JSON.', 1;

    -- Edit guard (018 pattern): editable only if CREATED today or yesterday
    -- (created_at, Norway local). NULL created_at (pre-feature history) is locked.
    DECLARE @today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE N'W. Europe Standard Time' AS DATE);
    IF NOT EXISTS (SELECT 1 FROM [qc].[contamination_log] WHERE id = @contamination_log_id)
        THROW 50002, N'contamination_log id not found.', 1;
    DECLARE @created DATE = (SELECT CAST([created_at] AS DATE) FROM [qc].[contamination_log] WHERE id = @contamination_log_id);
    IF @created IS NULL OR @created < DATEADD(DAY, -1, @today) OR @created > @today
        THROW 50004, N'Only rows created today or yesterday can be edited.', 1;

    BEGIN TRAN;
    UPDATE [qc].[contamination_log]
       SET sampling_date   = @sampling_date,
           sample_taken_by = @sample_taken_by,
           notes           = @notes
     WHERE id = @contamination_log_id;   -- created_at + line intentionally untouched

    DELETE FROM [qc].[contamination_measurement] WHERE contamination_log_id = @contamination_log_id;

    IF @measurements IS NOT NULL
        INSERT INTO [qc].[contamination_measurement] (contamination_log_id, vat, metal, value)
        SELECT @contamination_log_id, j.vat, j.metal, j.value
        FROM OPENJSON(@measurements)
             WITH (vat NVARCHAR(20), metal NVARCHAR(4), value NVARCHAR(30)) AS j;
    COMMIT TRAN;
END
GO

/* ---- 5. re-assert grants (preserved by CREATE OR ALTER, re-stated) --- */
GRANT EXECUTE ON OBJECT::[qc].[usp_contamination_insert] TO [production_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_contamination_update] TO [production_data_manager_role];
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'023_add_contamination_notes.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'023_add_contamination_notes.sql');
GO

SET NOEXEC OFF;
GO
