/* =====================================================================
 * measure_view_runtimes.sql   --   read-only. Any qc database.
 *
 * Times each of the 10 qc.vw_* views by materializing its full result set
 * server-side (SELECT * INTO #discard) and measuring elapsed microseconds.
 * Creates only temp tables; changes no data. Load data first, or you're just
 * timing empty scans.
 *
 * Reads warm-cache runtimes (Azure SQL DB can't DROPCLEANBUFFERS): each view is
 * run @iterations times; MIN is the best-case warm number, the first run pays
 * compile + cold pages. Increase @iterations for steadier averages.
 * ===================================================================== */
SET NOCOUNT ON;

DECLARE @iterations INT = 5;   -- runs per view

IF OBJECT_ID('tempdb..#results') IS NOT NULL DROP TABLE #results;
CREATE TABLE #results (
    view_name  SYSNAME,
    iteration  INT,
    row_count  INT,
    elapsed_ms DECIMAL(12,3)
);

DECLARE @views TABLE (id INT IDENTITY(1,1), name SYSNAME);
INSERT INTO @views (name) VALUES
    (N'vw_ph_control'),
    (N'vw_adding_chemicals'),
    (N'vw_production_tracking'),
    (N'vw_conductivity'),
    (N'vw_cleaner_bath'),
    (N'vw_activator_bath'),
    (N'vw_strike_bath'),
    (N'vw_plate_bath_28'),
    (N'vw_plate_bath_29'),
    (N'vw_plate_bath_30');

DECLARE @i INT = 1, @maxv INT = (SELECT MAX(id) FROM @views);
DECLARE @vname SYSNAME, @sql NVARCHAR(MAX);
DECLARE @it INT, @t0 DATETIME2(7), @t1 DATETIME2(7), @rows INT;

WHILE @i <= @maxv
BEGIN
    SET @vname = (SELECT name FROM @views WHERE id = @i);
    SET @it = 1;
    WHILE @it <= @iterations
    BEGIN
        -- Materialize the whole view into tempdb, capture its row count, drop it.
        SET @sql = N'SELECT * INTO #discard FROM [qc].[' + @vname + N'];'
                 + N'SET @rows_out = @@ROWCOUNT;'
                 + N'DROP TABLE #discard;';

        SET @t0 = SYSUTCDATETIME();
        EXEC sp_executesql @sql, N'@rows_out INT OUTPUT', @rows_out = @rows OUTPUT;
        SET @t1 = SYSUTCDATETIME();

        INSERT INTO #results (view_name, iteration, row_count, elapsed_ms)
        VALUES (@vname, @it, @rows, DATEDIFF_BIG(MICROSECOND, @t0, @t1) / 1000.0);

        SET @it += 1;
    END
    SET @i += 1;
END

/* ---- summary (slowest first) ---------------------------------------- */
SELECT
    view_name,
    MIN(row_count)                          AS [rows],
    COUNT(*)                                 AS runs,
    CAST(MIN(elapsed_ms) AS DECIMAL(12,3))   AS min_ms,   -- best-case warm
    CAST(AVG(elapsed_ms) AS DECIMAL(12,3))   AS avg_ms,
    CAST(MAX(elapsed_ms) AS DECIMAL(12,3))   AS max_ms    -- usually the 1st (cold) run
FROM #results
GROUP BY view_name
ORDER BY avg_ms DESC;

/* ---- per-run detail (uncomment if you want every iteration) ---------- */
-- SELECT view_name, iteration, row_count, elapsed_ms
-- FROM #results ORDER BY view_name, iteration;

DROP TABLE #results;
