USE DBA_Data
GO

ALTER PROC dbo.Deployscripts 
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
	   , DeployOrder TINYINT)

INSERT INTO @deployTable
SELECT 'US-HEN-SQLDEV - DBA-941-ROLLBACK.sql',	'DBA-941',	'US-HEN-SQLDEV',	NULL,	NULL,	NULL,	1,	1
INSERT INTO @deployTable
SELECT 'US-HEN-SQLDEV - DBA-941.sql',			'DBA-941',	'US-HEN-SQLDEV',	NULL,	1,		'US-HEN-SQLDEV - DBA-941-ROLLBACK.sql',	1,	1
INSERT INTO @deployTable
SELECT 'US-HEN-SQLDEV - DBA-941_2-ROLLBACK.sql',	'DBA-941',	'US-HEN-SQLDEV',	NULL,	NULL,	NULL,	1,	2
INSERT INTO @deployTable
SELECT 'US-HEN-SQLDEV - DBA-941_2.sql',		     'DBA-941',	'US-HEN-SQLDEV',	NULL,	1,		'US-HEN-SQLDEV - DBA-941_2-ROLLBACK.sql',	1,	2
--*/

SET NOCOUNT ON

--=====================================================================
-- Receive table values from passed in parameter.
--=====================================================================

DECLARE @deploylist TABLE
	  (ScriptName VARCHAR(512)
	   , JiraTicket VARCHAR(128)
	   , ServerName VARCHAR(512)
	   , DatabaseName VARCHAR(128) DEFAULT 'master'
	   , HasRollback BIT DEFAULT 0
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

--=====================================================================
-- Create Results table
--=====================================================================
    IF OBJECT_ID('runningresults', 'U') IS NOT NULL 
	   DROP TABLE runningresults; 

    CREATE TABLE runningresults (ScriptName NVARCHAR(512)
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

    WHILE (SELECT COUNT(*) FROM @deploylist WHERE RIGHT(ScriptName, 12) <> 'Rollback.sql') > 0
    BEGIN
	   
--===============================================================================================================================
-- Insert into the results table where a multiple step script fails, and its following scripts are not deployed as a result
--===============================================================================================================================

	   INSERT INTO runningresults (ScriptName
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
	   WHERE EXISTS (SELECT * FROM runningresults WHERE dt2.JiraTicket = runningresults.jiraTicket AND ResultOutput = 'Failed') -- Where a previous deployment failed
		    AND NOT EXISTS (SELECT * FROM runningresults WHERE dt1.JiraTicket = runningresults.jiraTicket) -- That already isn't in the results table

	   DELETE 
	   FROM @deploylist 
	   WHERE EXISTS (SELECT * FROM runningresults WHERE [@deploylist].JiraTicket = runningresults.jiraTicket AND ResultOutput = 'Not Deployed')

	   SELECT TOP 1 @scriptName = scriptname
				, @jiraTicket = JiraTicket
				, @serverName = ServerName
				, @databaseName = ISNULL(DatabaseName, 'master')
				, @isMultiple = IsMultiple
				, @deployOrder = deployOrder
				, @hasRollback = HasRollback
				, @rollbackScriptName = RollbackScriptName
	   FROM @deploylist
	   WHERE RIGHT(ScriptName, 12) <> 'Rollback.sql'
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
		 
	   SET @sql = 'sqlcmd -S '+ @serverName + ' -d ' + @databaseName + ' -i ' + '"' + @sourcePath +'\'+ @scriptName + '"'

	   DELETE from @CommandShellOutputTable

	   INSERT INTO @CommandShellOutputTable (Line)
	   EXEC sys.xp_cmdshell @sql

	   INSERT INTO runningresults (ScriptName
	                       , ExecutionCode
					   , ResultOutput
	                       , serverName
					   , DatabaseName
					   , jiraTicket
					   , ErrorMsg
					   , isMultiple
					   , DeployOrder
					   , HasRollback
					   , RollbackScriptName
					   , Runtime)
					 
	   SELECT @scriptName
			, @sql
			, IIF(STUFF(( SELECT ', ' + Line
				     FROM @CommandShellOutputTable
					FOR XML PATH ('')
				), 1, 2, '') LIKE '%msg%', 'FAILED', 'SUCCEEDED') 
			, @serverName
			, @databaseName
			, @jiraTicket
			, STUFF(( SELECT ', ' + Line
				     FROM @CommandShellOutputTable
					FOR XML PATH ('')
				), 1, 2, '') AS Line -- Takes all rows from Command line output and sets as a comma delimited string
			, @isMultiple
			, @deployOrder
			, @hasRollback
			, @rollbackScriptName
			, @runTime
    END

--=====================================================================
-- Search Results for rollbacks
--=====================================================================

    IF OBJECT_ID('tempdb..#rollbacks', 'U') IS NOT NULL 
      DROP TABLE #rollbacks; 

    SELECT ScriptName
         , ExecutionCode
         , ResultOutput
         , serverName
         , DatabaseName
         , jiraTicket
         , ErrorMsg
         , isMultiple
         , DeployOrder
         , HasRollback
         , RollbackScriptName
         , Rolledback
         , Runtime
    INTO #rollbacks
    FROM runningresults
    WHERE HasRollback = 1
		AND ResultOutput = 'FAILED'

--====================================================================================================================
-- If there is a multiple step deployment where a step > 1 fails, find the previous steps and roll them back too.
--====================================================================================================================

    IF EXISTS (SELECT * FROM #rollbacks WHERE isMultiple = 1 AND DeployOrder > 1)
    BEGIN 

	   INSERT INTO #rollbacks (ScriptName
	                         , ExecutionCode
	                         , ResultOutput
	                         , serverName
	                         , DatabaseName
	                         , jiraTicket
	                         , ErrorMsg
	                         , isMultiple
	                         , DeployOrder
	                         , HasRollback
	                         , RollbackScriptName
	                         , Rolledback
	                         , Runtime)

	   SELECT runningresults.ScriptName
	   	 , runningresults.ExecutionCode
	   	 , runningresults.ResultOutput
	   	 , runningresults.serverName
	   	 , runningresults.DatabaseName
	   	 , runningresults.jiraTicket
	   	 , runningresults.ErrorMsg
	   	 , runningresults.isMultiple
	   	 , runningresults.DeployOrder
	   	 , runningresults.HasRollback
	   	 , runningresults.RollbackScriptName
	   	 , runningresults.Rolledback
	   	 , runningresults.Runtime
	   FROM runningresults
	   JOIN #rollbacks
	      ON #rollbacks.jiraTicket = runningresults.jiraTicket
	   WHERE #rollbacks.DeployOrder > runningresults.DeployOrder 
		    AND runningresults.HasRollback = 1

    END

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
				, @hasRollback = 0 -- Makes sure rollback script isn't flagged as having a rollback
				, @rollbackScriptName = RollbackScriptName
	   FROM #rollbacks
	   ORDER BY IsMultiple, JiraTicket, DeployOrder DESC -- Deploy in reverse order

	   DELETE FROM #rollbacks 
	   WHERE ScriptName = @scriptName
		    AND JiraTicket = @jiraTicket
		    AND ServerName = @serverName
		    AND ISNULL(DatabaseName, 'master') = @databaseName
		    AND IsMultiple = @isMultiple
		    AND DeployOrder = @deployOrder
		    AND RollbackScriptName = @rollbackScriptName

	   SET @sql = 'sqlcmd -S '+ @serverName + ' -d '+ @databaseName +' -i ' + '"' + @sourcePath +'\'+ @rollbackScriptName + '"'
	   
	   DELETE from @CommandShellOutputTable

	   INSERT INTO @CommandShellOutputTable (Line)
	   EXEC sys.xp_cmdshell @sql

	   	   INSERT INTO runningresults (ScriptName
	                       , ExecutionCode
					   , ResultOutput
	                       , serverName
					   , DatabaseName
					   , jiraTicket
					   , ErrorMsg
					   , isMultiple
					   , DeployOrder
					   , HasRollback
					   , RollbackScriptName
					   , Runtime)
					 
	   SELECT @scriptName
			, @sql
			, IIF(STUFF(( SELECT ', ' + Line
				     FROM @CommandShellOutputTable
					FOR XML PATH ('')
				), 1, 2, '')  LIKE '%msg%', ' ROLLBACK FAILED', 'ROLLBACK SUCCEEDED') 
			, @serverName
			, @databaseName
			, @jiraTicket
			, STUFF(( SELECT ', ' + Line
				     FROM @CommandShellOutputTable
					FOR XML PATH ('')
				), 1, 2, '') 
			, @isMultiple
			, @deployOrder
			, @hasRollback
			, NULL
			, @runTime

    END

    UPDATE runningresults
    SET Rolledback = 1
    FROM runningresults r1
    WHERE EXISTS (SELECT * FROM runningresults r2 WHERE r1.jiraTicket = r2.jiraTicket AND r2.ResultOutput = 'ROLLBACK SUCCEEDED')

    INSERT INTO dbo.DeploymentResults (SqlFileName
                                     , ExecutionCode
                                     , ResultOutput
                                     , serverName
                                     , DatabaseName
                                     , JiraTicket
                                     , ErrorMsg
                                     , IsMultiple
                                     , DeployOrder
                                     , HasRollBack
                                     , RollbackScriptName
                                     , RolledBack
                                     , Runtime)

    SELECT ScriptName
         , ExecutionCode
         , ResultOutput
         , serverName
         , DatabaseName
         , jiraTicket
         , ErrorMsg
         , isMultiple
         , DeployOrder
         , HasRollback
         , RollbackScriptName
         , Rolledback
         , Runtime
    FROM runningresults

    DROP TABLE dbo.runningresults

END