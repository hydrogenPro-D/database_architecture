/* =====================================================================
 * 029_measurement_limits_add_remove.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: MEASUREMENT_LIMITS_ADD_REMOVE_SPEC.md -- let the app CREATE a limit
 *   that has no row yet, and REMOVE one, on top of 028's update-only procedure.
 *     1. measurement_threshold + is_deleted BIT NOT NULL DEFAULT 0
 *     2. the shape CHECK is replaced so a tombstone (all values NULL) is legal
 *     3. vw_measurement_thresholds hides a threshold whose newest row is a tombstone
 *     4. qc.usp_measurement_threshold_create
 *     5. qc.usp_measurement_threshold_delete
 *   Idempotent (COL_LENGTH / constraint-name guards + CREATE OR ALTER).
 *   Run 001-028 first. Nothing in 028 is modified; 028 stays as applied.
 *
 * HOW REMOVAL IS REPRESENTED -- THE DECISION THE SPEC ASKED FOR
 * ------------------------------------------------------------
 * A TOMBSTONE ROW, marked by a new is_deleted BIT column. The spec offered
 * "a tombstone, or an is_deleted / deleted_at column"; in an append-only table it
 * has to be both, because a tombstone is only distinguishable from a value row by
 * a flag. Nothing is ever updated or deleted, exactly as in 028:
 *     - removing a limit APPENDS a row with is_deleted = 1 and all three values
 *       NULL, stamped with @updated_by / updated_at.
 *     - the current value of a threshold is still "highest id wins"; it simply
 *       counts as absent when that newest row is a tombstone.
 *     - re-creating a removed limit appends a normal row again, so a threshold
 *       can go set -> removed -> set and the whole trail survives.
 * No deleted_at column: updated_at on the tombstone row already IS the removal
 * time, and a second timestamp could disagree with it.
 *
 * WHAT THE APP MUST READ (this is the part that changed)
 * -----------------------------------------------------
 *     - vw_measurement_thresholds: unchanged shape, but a removed threshold no
 *       longer appears at all. That is how the app sees "not set".
 *     - history (qc.measurement_threshold read directly, ORDER BY id DESC): the
 *       removal appears as a row with is_deleted = 1 and NULL values, carrying the
 *       updated_by / updated_at of whoever removed it. Render those as "removed".
 *
 * WHY THE SHAPE CONSTRAINT IS REPLACED
 * ------------------------------------
 * 028's CK_measurement_threshold_shape demands a middle_value (nominal) or a
 * lower/upper (band). A tombstone has none of them, so it could not be inserted.
 * The replacement keeps that rule for live rows and requires a tombstone to carry
 * no values at all -- so the shape stays honest in both directions. It is added
 * under a new name so re-running this migration is a no-op rather than a
 * drop-and-recreate.
 *
 * ERROR CODES (as the spec's mapping table requires)
 *   50002 no such vat / section_key / threshold_type, or nothing to remove
 *   50009 already exists (create) or changed by someone else (delete)
 *   50010 blank @updated_by
 *   50011 invalid shape
 *   CK_measurement_threshold_order propagates raw for lower > upper, which is what
 *   the app already maps; neither procedure pre-checks it, matching 028's update.
 *
 * Multi-batch (CREATE VIEW/PROCEDURE must lead its batch; a CHECK cannot
 * reference a column added in the same batch) -> RAISERROR + SET NOEXEC.
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
IF OBJECT_ID(N'[qc].[measurement_threshold]', N'U') IS NULL
BEGIN
    RAISERROR(N'Run 028 first (creates the measurement limit tables).', 16, 1);
    SET NOEXEC ON;
END;
GO

/* ---- 1. the tombstone marker ---------------------------------------- */
/* Existing rows are all live, so DEFAULT 0 backfills them correctly. */
IF COL_LENGTH(N'[qc].[measurement_threshold]', N'is_deleted') IS NULL
    ALTER TABLE [qc].[measurement_threshold] ADD [is_deleted] BIT NOT NULL
        CONSTRAINT [DF_measurement_threshold_is_deleted] DEFAULT (0);
GO

/* ---- 2. shape rule, now aware of tombstones ------------------------- */
IF EXISTS (SELECT 1 FROM sys.check_constraints
           WHERE name = N'CK_measurement_threshold_shape'
             AND parent_object_id = OBJECT_ID(N'[qc].[measurement_threshold]'))
    ALTER TABLE [qc].[measurement_threshold] DROP CONSTRAINT [CK_measurement_threshold_shape];
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE name = N'CK_measurement_threshold_shape_or_tombstone'
                 AND parent_object_id = OBJECT_ID(N'[qc].[measurement_threshold]'))
    ALTER TABLE [qc].[measurement_threshold] ADD
        CONSTRAINT [CK_measurement_threshold_shape_or_tombstone] CHECK (
            -- a tombstone records only that the limit was removed
            ([is_deleted] = 1
                 AND [middle_value] IS NULL
                 AND [lower_value]  IS NULL
                 AND [upper_value]  IS NULL)
            OR
            -- a live row keeps 028's rule: a nominal is a point, a band an interval
            ([is_deleted] = 0
                 AND (([threshold_type] =  N'nominal'
                           AND [middle_value] IS NOT NULL
                           AND [lower_value] IS NULL AND [upper_value] IS NULL)
                   OR ([threshold_type] <> N'nominal'
                           AND [middle_value] IS NULL
                           AND ([lower_value] IS NOT NULL OR [upper_value] IS NOT NULL))))
        );
GO

/* ---- 3. read path: current, and not removed ------------------------- */
/* Same columns as 028. The only change is the is_deleted = 0 filter, so a removed
 * threshold disappears from the view -- which is how the app sees "not set". */
CREATE OR ALTER VIEW [qc].[vw_measurement_thresholds] AS
WITH latest AS (
    SELECT mt.*,
           ROW_NUMBER() OVER (PARTITION BY mt.[measurement_section_id], mt.[threshold_type]
                              ORDER BY mt.[id] DESC) AS rn
    FROM [qc].[measurement_threshold] mt
)
SELECT
    v.id   AS vat_id,
    v.name AS vat_name,
    ms.section_key,
    ms.unit,
    l.threshold_type,
    l.middle_value,
    l.lower_value,
    l.upper_value,
    l.updated_at,
    l.updated_by,
    l.row_version
FROM latest l
JOIN [qc].[measurement_section] ms ON ms.id = l.measurement_section_id
JOIN [qc].[vat] v                  ON v.id = ms.vat_id
WHERE l.rn = 1
  AND l.is_deleted = 0;
GO

/* ---- 4. create ------------------------------------------------------ */
/* Creates the measurement_section row too when the measurement has none, which is
 * how the seven sections the app offers but the database lacks come into being.
 * No @expected_row_version: there is no row yet to guard against. */
CREATE OR ALTER PROCEDURE [qc].[usp_measurement_threshold_create]
    @vat_id         INT,
    @section_key    NVARCHAR(40),
    @unit           NVARCHAR(20),
    @threshold_type NVARCHAR(20),
    @middle_value   DECIMAL(12,5) = NULL,
    @lower_value    DECIMAL(12,5) = NULL,
    @upper_value    DECIMAL(12,5) = NULL,
    @updated_by     NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @updated_by IS NULL OR LTRIM(RTRIM(@updated_by)) = N''
        THROW 50010, N'Updated by is required.', 1;

    IF @threshold_type NOT IN (N'nominal', N'control', N'reaction', N'tolerance')
        THROW 50002, N'Unknown threshold_type.', 1;
    IF NOT EXISTS (SELECT 1 FROM [qc].[vat] WHERE [id] = @vat_id)
        THROW 50002, N'Unknown vat_id.', 1;

    -- Backstop for the shape rules; the app checks these first.
    IF (@threshold_type = N'nominal'
            AND (@middle_value IS NULL OR @lower_value IS NOT NULL OR @upper_value IS NOT NULL))
       OR (@threshold_type <> N'nominal'
            AND (@middle_value IS NOT NULL OR (@lower_value IS NULL AND @upper_value IS NULL)))
        THROW 50011, N'A nominal needs middle_value only; a band needs a lower and/or upper value.', 1;

    BEGIN TRAN;

    DECLARE @section_id INT =
        (SELECT [id] FROM [qc].[measurement_section]
          WHERE [vat_id] = @vat_id AND [section_key] = @section_key);

    IF @section_id IS NULL
    BEGIN
        INSERT INTO [qc].[measurement_section] ([vat_id], [section_key], [unit])
        VALUES (@vat_id, @section_key, @unit);
        SET @section_id = SCOPE_IDENTITY();
    END

    -- Refuse if this threshold already has a LIVE current row. A tombstoned one
    -- is absent, so re-creating a removed limit is allowed and lands a new row.
    DECLARE @live BIT = 0;
    SELECT TOP 1 @live = CASE WHEN mt.[is_deleted] = 0 THEN 1 ELSE 0 END
    FROM [qc].[measurement_threshold] mt
    WHERE mt.[measurement_section_id] = @section_id
      AND mt.[threshold_type] = @threshold_type
    ORDER BY mt.[id] DESC;

    IF @live = 1
        THROW 50009, N'That limit already exists -- refresh and try again.', 1;

    INSERT INTO [qc].[measurement_threshold]
        ([measurement_section_id], [threshold_type], [middle_value],
         [lower_value], [upper_value], [updated_by])
    VALUES (@section_id, @threshold_type, @middle_value,
            @lower_value, @upper_value, @updated_by);

    COMMIT TRAN;
END
GO

/* ---- 5. delete (append a tombstone) --------------------------------- */
/* The measurement_section row is deliberately LEFT IN PLACE even when its last
 * threshold goes: the unit is worth keeping and a later create would recreate it. */
CREATE OR ALTER PROCEDURE [qc].[usp_measurement_threshold_delete]
    @vat_id               INT,
    @section_key          NVARCHAR(40),
    @threshold_type       NVARCHAR(20),
    @updated_by           NVARCHAR(100),
    @expected_row_version BINARY(8)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @updated_by IS NULL OR LTRIM(RTRIM(@updated_by)) = N''
        THROW 50010, N'Updated by is required.', 1;

    DECLARE @section_id INT, @current BINARY(8), @deleted BIT;
    SELECT TOP 1 @section_id = ms.[id], @current = mt.[row_version], @deleted = mt.[is_deleted]
    FROM [qc].[measurement_threshold] mt
    JOIN [qc].[measurement_section] ms ON ms.[id] = mt.[measurement_section_id]
    WHERE ms.[vat_id] = @vat_id
      AND ms.[section_key] = @section_key
      AND mt.[threshold_type] = @threshold_type
    ORDER BY mt.[id] DESC;

    -- nothing to remove: never existed, or already removed
    IF @section_id IS NULL OR @deleted = 1
        THROW 50002, N'No threshold to remove for that vat / section_key / threshold_type.', 1;
    IF @expected_row_version IS NULL OR @current <> @expected_row_version
        THROW 50009, N'This threshold was changed by someone else -- refresh and try again.', 1;

    INSERT INTO [qc].[measurement_threshold]
        ([measurement_section_id], [threshold_type], [middle_value],
         [lower_value], [upper_value], [updated_by], [is_deleted])
    VALUES (@section_id, @threshold_type, NULL, NULL, NULL, @updated_by, 1);
END
GO

/* ---- grants --------------------------------------------------------- */
/* The view needs none: 002 granted SELECT ON SCHEMA::qc. Writes stay proc-only. */
GRANT EXECUTE ON OBJECT::[qc].[usp_measurement_threshold_create] TO [production_data_manager_role];
GRANT EXECUTE ON OBJECT::[qc].[usp_measurement_threshold_delete] TO [production_data_manager_role];
GO

/* ---- self-record into the migration ledger -------------------------- */
IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'029_measurement_limits_add_remove.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'029_measurement_limits_add_remove.sql');
GO

SET NOEXEC OFF;
GO
