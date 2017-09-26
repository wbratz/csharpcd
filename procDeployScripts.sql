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
	   , DeployOrder TINYINT
	   , Deployed BIT)
	    
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

DECLARE @scriptName VARCHAR(50)
	   , @jiraTicket VARCHAR(50)
	   , @serverName VARCHAR(50)
	   , @databaseName VARCHAR(50)
	   , @isMultiple bit
	   , @deployOrder TINYINT    
	   , @sql VARCHAR(8000)
	   , @runTime DATETIME = GETDATE()
  	   , @sourcePath VARCHAR(1000) = (SELECT SourcePath FROM secure.DeploymentValues WHERE ID = (SELECT MAX(ID) FROM secure.deploymentValues))


DECLARE @CommandShellOutputTable TABLE (Line NVARCHAR(MAX)) 
--=====================================================================
-- Create Results table
--=====================================================================

CREATE TABLE #results (SciptName NVARCHAR(512)
				   , ExecutionCode NVARCHAR(512)
				   , ResultOutput NVARCHAR(MAX)
				   , serverName VARCHAR(250)
				   , jiraTicket NVARCHAR(128)
				   , ErrorMsg VARCHAR(1000)
				   , isMultiple BIT
				   , DeployOrder TINYINT
				   , Runtime DATETIME)

--=====================================================================
-- Loop through table and execute each script
--=====================================================================

    WHILE (SELECT COUNT(*) FROM @deployTable) > 0
    BEGIN
	   
--===============================================================================================================================
-- Insert into the results table where a multiple step script fails, and its following scripts are not deployed as a result
--===============================================================================================================================

	   INSERT INTO #results (SciptName
	                       , ExecutionCode
	                       , ResultOutput
	                       , serverName
	                       , jiraTicket
	                       , ErrorMsg
	                       , isMultiple
	                       , DeployOrder
	                       , Runtime)
	   SELECT dt1.ScriptName
			, 'NA'
			, 'Not Deployed'
			, dt1.serverName
			, dt1.jiraTicket
			, 'Previous Script Failed'
			, dt1.isMultiple
			, dt1.DeployOrder
			, @runTime
	   FROM @deployTable dt1
	   JOIN @deployTable dt2
		  ON dt2.JiraTicket = dt1.JiraTicket
		  AND dt1.IsMultiple = 1
		  AND dt1.DeployOrder > dt2.DeployOrder -- Find multiple deployments with a higher deployment number
	   WHERE EXISTS (SELECT * FROM #results WHERE dt2.JiraTicket = #results.jiraTicket AND ResultOutput = 'Failed') -- Where a previous deployment failed
		    AND NOT EXISTS (SELECT * FROM #results WHERE dt1.JiraTicket = #results.jiraTicket) -- That already isn't in the results table

	   DELETE FROM @deployTable WHERE EXISTS (SELECT * FROM #results WHERE [@deployTable].JiraTicket = #results.jiraTicket AND ResultOutput = 'Not Deployed')

	   SELECT TOP 1 @scriptName = scriptname
				, @jiraTicket = JiraTicket
				, @serverName = ServerName
				, @databaseName = DatabaseName
				, @isMultiple = IsMultiple
				, @deployOrder = deployOrder
	   FROM @deployTable
	   ORDER BY IsMultiple, JiraTicket --handles multiple deployments first and orders them by JiraTicket

	   DELETE FROM @deployTable 
	   WHERE ScriptName = @scriptName
		    AND JiraTicket = @jiraTicket
		    AND ServerName = @serverName
		    AND DatabaseName = @databaseName
		    AND IsMultiple = @isMultiple
		    AND DeployOrder = @deployOrder

	   SET @sql = 'sqlcmd -S '+ @serverName + ' -d master -i ' + '"' + @sourcePath +'\'+ @scriptName + '"'

	   DELETE from @CommandShellOutputTable

	   INSERT INTO @CommandShellOutputTable (Line)
	   EXEC sys.xp_cmdshell @sql

	   INSERT INTO #results (SciptName
	                       , ExecutionCode
					   , ResultOutput
	                       , serverName
					   , jiraTicket
					   , ErrorMsg
					   , isMultiple
					   , DeployOrder)
	   SELECT @scriptName
			, @sql
			, IIF(Line LIKE '%msg%', 'FAILED', 'SUCCEEDED') 
			, @serverName
			, @jiraTicket
			, Line
			, @isMultiple
			, @deployOrder
	   FROM @CommandShellOutputTable

    END

END