/* =====================================================================
 * 003_create_user_db_qc_data_manager.sql
 * Scope : per-database (run against EACH of dataloggingDev / dataloggingTest)
 * Effect: create the contained user [db_qc_data_manager_user] (its own password,
 *         no server login) and add it to [qc_data_manager_role].
 * Safe to re-run (idempotent). Records itself in the ledger. Run 001 first.
 *
 * PASSWORD HANDLING -- IMPORTANT
 * -----------------------------
 * Type the real password into the @pw line below, RUN the file, then CLOSE IT
 * WITHOUT SAVING. The committed file keeps the placeholder, so no secret ever
 * lands in git. If you forget to set it, the guard throws instead of creating a
 * user with a junk password.
 *
 * Single batch on purpose (see 001 for why) -- @pw must be used in the same
 * batch it is declared in.
 * ===================================================================== */

IF DB_NAME() NOT IN (N'dataloggingDev', N'dataloggingTest')
    THROW 50000, N'Refusing to run: not a datalogging database.', 1;
IF OBJECT_ID(N'[qc].[schema_migrations]', N'U') IS NULL
    THROW 50000, N'Run 001 first (creates the qc schema + ledger).', 1;

DECLARE @pw NVARCHAR(128) = N'<<SET_PASSWORD_HERE_THEN_DO_NOT_SAVE>>';

IF @pw LIKE N'%<<%' OR @pw LIKE N'%>>%' OR LEN(@pw) < 8
    THROW 50000, N'Set a real password (>= 8 chars) in @pw before running 003.', 1;

-- WITH PASSWORD needs a literal, so build the statement in a variable first.
-- (EXEC() cannot contain function calls like REPLACE -- only string literals
-- and variables -- so the escaping must happen here, not inside EXEC.)
DECLARE @sql NVARCHAR(MAX) =
    N'CREATE USER [db_qc_data_manager_user] WITH PASSWORD = N'''
    + REPLACE(@pw, N'''', N'''''') + N'''';

IF NOT EXISTS (SELECT 1 FROM sys.database_principals
               WHERE name = N'db_qc_data_manager_user')
    EXEC (@sql);

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members rm
    JOIN sys.database_principals r ON rm.role_principal_id   = r.principal_id
    JOIN sys.database_principals m ON rm.member_principal_id = m.principal_id
    WHERE r.name = N'qc_data_manager_role'
      AND m.name = N'db_qc_data_manager_user')
    ALTER ROLE [qc_data_manager_role] ADD MEMBER [db_qc_data_manager_user];

IF NOT EXISTS (SELECT 1 FROM [qc].[schema_migrations]
               WHERE filename = N'003_create_user_db_qc_data_manager.sql')
    INSERT INTO [qc].[schema_migrations] (filename)
    VALUES (N'003_create_user_db_qc_data_manager.sql');
GO
