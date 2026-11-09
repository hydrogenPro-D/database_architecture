/* =====================================================================
 * 033_seed_contamination_limits.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: CONTAMINATION_LIMITS_SEED.md -- seed the five critical upper
 *   concentrations of the Contamination Log into qc.app_setting:
 *       contamination.limit.cr  '5'    contamination.limit.zn  '20'
 *       contamination.limit.cu  '20'   contamination.limit.pb  '5'
 *       contamination.limit.fe  '30'
 *   Data only. No tables, views, procedures or grants are touched.
 *   Idempotent: each key is NOT EXISTS-guarded, so a re-run inserts nothing.
 *   Run 001-032 first (032 creates qc.app_setting).
 *
 * RUN THIS ON BOTH DATABASES, INCLUDING TEST WHERE THE ROWS ALREADY EXIST
 * ----------------------------------------------------------------------
 * dataloggingTest already has all five keys -- the app wrote them through
 * qc.usp_app_setting_set while the feature was being tested. Running this there
 * inserts NOTHING (every guard skips) but still records 033 in the ledger, so
 * both databases end up at the same migration with the same data.
 * Skipping it on test is the only thing that would leave the ledger wrong.
 *
 * WHY NOT EXISTS MATTERS HERE MORE THAN USUAL
 * -------------------------------------------
 * qc.app_setting is APPEND-ONLY (see 032): the newest row per key wins and
 * nothing is overwritten. An unguarded re-run would not "do nothing" -- it would
 * append a second initial version of every limit AND, worse, bury a value
 * production had since set underneath the shipped default. The guard is per key,
 * so a key somebody has already changed is left completely alone.
 *
 * VALUES ARE WRITTEN AS '5', NEVER '5.0'
 * --------------------------------------
 * The app formats a limit with %g and compares that text against what is stored
 * to decide whether a save actually changed anything. A seeded '5.0' reads back
 * correctly, but the next save that does not touch Cr would compare '5' against
 * '5.0', conclude it changed, and append a pointless version recording an edit
 * nobody made.
 *
 * NOT REQUIRED FOR THE APP TO WORK: it ships the same five numbers as defaults
 * and uses them whenever a key is absent or unreadable. This makes the values
 * visible in the database and gives the first real edit a baseline to append to.
 *
 * Single batch on purpose (see 001 for why).
 * ===================================================================== */

IF DB_NAME() NOT IN (N'dataloggingDev', N'dataloggingTest')
    THROW 50000, N'Refusing to run: not a datalogging database.', 1;
IF OBJECT_ID(N'[qc].[schema_migrations]', N'U') IS NULL
    THROW 50000, N'Run 001 first (creates the qc schema + ledger).', 1;
IF OBJECT_ID(N'[qc].[app_setting]', N'U') IS NULL
    THROW 50000, N'Run 032 first (creates qc.app_setting).', 1;

/* Direct INSERT with updated_by = '033_seed', the same path 032 used for its own
 * two keys. The app reads the view and does not care which path wrote a row. */
INSERT INTO [qc].[app_setting] ([setting_key], [setting_value], [updated_by])
SELECT x.k, x.v, N'033_seed'
FROM (VALUES
    (N'contamination.limit.cr', N'5'),
    (N'contamination.limit.cu', N'20'),
    (N'contamination.limit.fe', N'30'),
    (N'contamination.limit.zn', N'20'),
    (N'contamination.limit.pb', N'5')
) AS x(k, v)
WHERE NOT EXISTS (SELECT 1 FROM [qc].[app_setting] a
                   WHERE a.[setting_key] = x.k);

DECLARE @inserted INT = @@ROWCOUNT;
DECLARE @present  INT = (SELECT COUNT(DISTINCT [setting_key]) FROM [qc].[app_setting]
                          WHERE [setting_key] LIKE N'contamination.limit.%');
PRINT CONCAT(N'contamination limits inserted: ', @inserted,
             N'  (0 is correct where the app already wrote them)');
PRINT CONCAT(N'contamination limit keys now present: ', @present, N' (expected 5)');

IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'033_seed_contamination_limits.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'033_seed_contamination_limits.sql');
GO
