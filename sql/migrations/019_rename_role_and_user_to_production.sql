/* =====================================================================
 * 019_rename_role_and_user_to_production.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: RENAME the role and user created in 002/003 -- a pure name change.
 *           qc_data_manager_role     -> production_data_manager_role
 *           db_qc_data_manager_user  -> db_production_data_manager_user
 *         ALTER ROLE/USER ... WITH NAME keeps the same principal_id, so every
 *         grant (SELECT on schema::qc, EXECUTE on the procs from 018), the role
 *         membership, and the user's password are ALL preserved. Nothing is
 *         reassigned.
 * Safe to re-run (idempotent): each rename only fires while the OLD name still
 *         exists, so a second run is a no-op. Records itself in the ledger.
 *         Run 001-003 first.
 *
 * FOLLOW-UPS (outside this DB migration -- the rename does not touch them):
 *   - The QC app connects AS db_qc_data_manager_user; update its connection
 *     string to the new user name or it will fail to log in.
 *   - Any FUTURE migration that references the role/user by name must use the
 *     new names. Do NOT edit 002/003/018 -- they are already-applied history.
 *
 * Single batch on purpose (see 001 for why).
 * ===================================================================== */

IF DB_NAME() NOT IN (N'dataloggingDev', N'dataloggingTest')
    THROW 50000, N'Refusing to run: not a datalogging database.', 1;
IF OBJECT_ID(N'[qc].[schema_migrations]', N'U') IS NULL
    THROW 50000, N'Run 001 first (creates the qc schema + ledger).', 1;

-- Rename the role (fires only while the old name is still present).
IF EXISTS (SELECT 1 FROM sys.database_principals
           WHERE name = N'qc_data_manager_role' AND type = 'R')
    ALTER ROLE [qc_data_manager_role] WITH NAME = [production_data_manager_role];

-- Rename the user (password + role membership survive the rename).
IF EXISTS (SELECT 1 FROM sys.database_principals
           WHERE name = N'db_qc_data_manager_user')
    ALTER USER [db_qc_data_manager_user] WITH NAME = [db_production_data_manager_user];

IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'019_rename_role_and_user_to_production.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'019_rename_role_and_user_to_production.sql');
GO
