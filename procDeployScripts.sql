USE DBA_Data
GO

CREATE TYPE DeployTableType AS TABLE
	  (ScriptName VARCHAR(50)
	   , JiraTicket VARCHAR(50)
	   , ServerName VARCHAR(50)
	   , DatabaseName VARCHAR(50)
	   , HasRollback BIT
	   , RollbackScriptName VARCHAR(65)
	   , IsMultiple BIT
	   , DeployOrder TINYINT)
	    
GO

CREATE PROC dbo.Deployscripts 
		  (@deployTable DeployTableType READONLY)
AS 
BEGIN

/***********************************************************************************************************************************************

-- Author: William Bratz
--
-- Create Date: 9-26-2017
--
-- Description: Handles deployment scripts and rollbacks once the deployment table is populated and the proc is called.
--			 A master proc calls this, it should not be run independently of the master.
--
-- Original Requester/Owner: 
--
-- Changelog: 

***********************************************************************************************************************************************/

/* 
-- USE FOR DEBUGGING
DECLARE @deployTable TABLE
	  (ScriptName VARCHAR(50)
	   , JiraTicket VARCHAR(50)
	   , ServerName VARCHAR(50)
	   , DatabaseName VARCHAR(50)
	   , HasRollback BIT
	   , RollbackScriptName VARCHAR(65)
	   , IsMultiple BIT
	   , DeployOrder TINYINT
	   , Deployed BIT)
*/

--=====================================================================
-- Declare the varibles needed to do work
--=====================================================================

    DECLARE @scriptName VARCHAR(512)
		  , @jiraTicket VARCHAR(128)
		  , @serverName VARCHAR(128)
		  , @databaseName VARCHAR(128)
		  , @isMultiple bit
		  , @deployOrder TINYINT    
		  , @sql VARCHAR(8000)
		  , @runTime DATETIME = GETDATE()
  		  , @sourcePath VARCHAR(1000) = (SELECT SourcePath FROM secure.DeploymentValues WHERE ID = (SELECT MAX(ID) FROM secure.deploymentValues))
		  , @hasRollback BIT
		  , @rollbackScriptName VARCHAR(512)

    DECLARE @CommandShellOutputTable TABLE (Line NVARCHAR(MAX)) 

    DECLARE @deploylist TABLE
	  (ScriptName VARCHAR(512)
	   , JiraTicket VARCHAR(128)
	   , ServerName VARCHAR(512)
	   , DatabaseName VARCHAR(128) DEFAULT 'master'
	   , HasRollback BIT
	   , RollbackScriptName VARCHAR(512)
	   , IsMultiple BIT
	   , DeployOrder TINYINT)

INSERT INTO @deploylist (ScriptName
                       , JiraTicket
                       , ServerName
                       , DatabaseName
                       , HasRollback
                       , RollbackScriptName
                       , IsMultiple
                       , DeployOrder)
SELECT ScriptName
     , JiraTicket
     , ServerName
     , DatabaseName
     , HasRollback
     , RollbackScriptName
     , IsMultiple
     , DeployOrder 
FROM @deployTable
--=====================================================================
-- Create Results table
--=====================================================================

    CREATE TABLE #results (ScriptName NVARCHAR(512)
					  , ExecutionCode NVARCHAR(512)
					  , ResultOutput NVARCHAR(MAX)
					  , serverName VARCHAR(250)
					  , DatabaseName VARCHAR(256)
					  , jiraTicket NVARCHAR(128)
					  , ErrorMsg VARCHAR(1000)
					  , isMultiple BIT
					  , DeployOrder TINYINT
					  , HasRollback BIT
					  , RollbackScriptName VARCHAR(512)
					  , Rolledback BIT DEFAULT 0
					  , Runtime DATETIME)

--=====================================================================
-- Loop through table and execute each script
--=====================================================================

    WHILE (SELECT COUNT(*) FROM @deploylist) > 0
    BEGIN
	   
--===============================================================================================================================
-- Insert into the results table where a multiple step script fails, and its following scripts are not deployed as a result
--===============================================================================================================================

	   INSERT INTO #results (ScriptName
	                       , ExecutionCode
	                       , ResultOutput
	                       , serverName
	                       , jiraTicket
	                       , ErrorMsg
	                       , isMultiple
	                       , DeployOrder
					   , HasRollback
					   , RollbackScriptName
	                       , Runtime)

	   SELECT dt1.ScriptName
			, 'NA'
			, 'Not Deployed'
			, dt1.serverName
			, dt1.jiraTicket
			, 'Previous Script Failed'
			, dt1.isMultiple
			, dt1.DeployOrder
			, dt1.HasRollback
			, dt1.RollbackScriptName
			, @runTime
	   FROM @deploylist dt1
	   JOIN @deploylist dt2
		  ON dt2.JiraTicket = dt1.JiraTicket
		  AND dt1.IsMultiple = 1
		  AND dt1.DeployOrder > dt2.DeployOrder -- Find multiple deployments with a higher deployment number
	   WHERE EXISTS (SELECT * FROM #results WHERE dt2.JiraTicket = #results.jiraTicket AND ResultOutput = 'Failed') -- Where a previous deployment failed
		    AND NOT EXISTS (SELECT * FROM #results WHERE dt1.JiraTicket = #results.jiraTicket) -- That already isn't in the results table

	   DELETE FROM @deploylist WHERE EXISTS (SELECT * FROM #results WHERE [@deploylist].JiraTicket = #results.jiraTicket AND ResultOutput = 'Not Deployed')

	   SELECT TOP 1 @scriptName = scriptname
				, @jiraTicket = JiraTicket
				, @serverName = ServerName
				, @databaseName = ISNULL(DatabaseName, 'master')
				, @isMultiple = IsMultiple
				, @deployOrder = deployOrder
				, @hasRollback = HasRollback
				, @rollbackScriptName = RollbackScriptName
	   FROM @deploylist
	   ORDER BY IsMultiple, JiraTicket, DeployOrder --handles multiple deployments first and orders them by JiraTicket

	   DELETE FROM @deploylist 
	   WHERE ScriptName = @scriptName
		    AND JiraTicket = @jiraTicket
		    AND ServerName = @serverName
		    AND ISNULL(DatabaseName, 'master') = @databaseName
		    AND IsMultiple = @isMultiple
		    AND DeployOrder = @deployOrder
		    AND HasRollback = @hasRollback
		    AND RollbackScriptName = @rollbackScriptName

	   SET @sql = 'sqlcmd -S '+ @serverName + ' -d' + @databaseName + '-i ' + '"' + @sourcePath +'\'+ @scriptName + '"'

	   DELETE from @CommandShellOutputTable

	   INSERT INTO @CommandShellOutputTable (Line)
	   EXEC sys.xp_cmdshell @sql
	   SELECT @sql

	   INSERT INTO #results (SciptName
	                       , ExecutionCode
					   , ResultOutput
	                       , serverName
					   , DatabaseName
					   , jiraTicket
					   , ErrorMsg
					   , isMultiple
					   , DeployOrder
					   , HasRollback
					   , RollbackScriptName)
					 
	   SELECT @scriptName
			, @sql
			, IIF(Line LIKE '%msg%', 'FAILED', 'SUCCEEDED') 
			, @serverName
			, @databaseName
			, @jiraTicket
			, Line
			, @isMultiple
			, @deployOrder
			, @hasRollback
			, @rollbackScriptName
	   FROM @CommandShellOutputTable

    END

    SELECT *
    INTO #rollbacks
    FROM #results
    WHERE HasRollback = 1
		AND ResultOutput = 'FAILED'

--=====================================================================
-- Rollback the failed deployments
--=====================================================================

    WHILE (SELECT COUNT(*) FROM #rollbacks) > 0
    BEGIN

	  SELECT TOP 1 @scriptName = ScriptName
				, @jiraTicket = JiraTicket
				, @serverName = ServerName
				, @databaseName = ISNULL(DatabaseName, 'master')
				, @isMultiple = IsMultiple
				, @deployOrder = deployOrder
				, @hasRollback = HasRollback
				, @rollbackScriptName = RollbackScriptName
	   FROM #rollbacks
	   ORDER BY IsMultiple, JiraTicket, DeployOrder desc

	   DELETE FROM #rollbacks 
	   WHERE ScriptName = @scriptName
		    AND JiraTicket = @jiraTicket
		    AND ServerName = @serverName
		    AND ISNULL(DatabaseName, 'master') = @databaseName
		    AND IsMultiple = @isMultiple
		    AND DeployOrder = @deployOrder
		    AND HasRollback = @hasRollback
		    AND RollbackScriptName = @rollbackScriptName

	   SET @sql = 'sqlcmd -S '+ @serverName + ' -d '+ @databaseName +' -i ' + '"' + @sourcePath +'\'+ @rollbackScriptName + '"'
	   
	   DELETE from @CommandShellOutputTable

	   INSERT INTO @CommandShellOutputTable (Line)
	   EXEC sys.xp_cmdshell @sql

   	   SELECT @sql

	   	   INSERT INTO #results (SciptName
	                       , ExecutionCode
					   , ResultOutput
	                       , serverName
					   , DatabaseName
					   , jiraTicket
					   , ErrorMsg
					   , isMultiple
					   , DeployOrder
					   , HasRollback
					   , RollbackScriptName)
					 
	   SELECT @scriptName
			, @sql
			, IIF(Line LIKE '%msg%', ' ROLLBACK FAILED', 'ROLLBACK SUCCEEDED') 
			, @serverName
			, @databaseName
			, @jiraTicket
			, Line
			, @isMultiple
			, @deployOrder
			, @hasRollback
			, @rollbackScriptName
	   FROM @CommandShellOutputTable

    END

END