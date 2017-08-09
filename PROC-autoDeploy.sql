USE [DBA_Data]
GO
/****** Object:  StoredProcedure [dbo].[DatabaseDeployments]    Script Date: 8/8/2017 12:59:15 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


ALTER PROC [dbo].[DatabaseDeployments]
AS
BEGIN

/***********************************************************************************************************************************************

-- Author: William Bratz
--
-- Create Date: 07-11-2017
--
-- Description: Uses folders in \\fs04\public\dba\deployments to handle upcoming deployments and moved into appropriate folder based on 
-- result of execution
--
-- Original Requester/Owner: 
--
-- Changelog: Billy - 07/18/2017 : Changed script to sp_configure turns off at the end, and only turns on if there is something to execute.
--		    Billy - 07/19/2017 : Fixed issue with jira ticket not being pulled correctly from script name. 
--		    Billy - 07/24/2017 : Added .exe file to check database deployments for ddl commands and apply the deployment key, then remove it from deployed scripts.
--		    Billy - 07/25/2017 : Added args to exe file for database deployments off newly created table.
--		    Billy - 07-31-2017 : Added where clause to end of select statement puplating filepath variables, this pulls most recent values allowing the table to be added to later on.
--
***********************************************************************************************************************************************/

--=====================================================================
-- Declare things this needs
--=====================================================================

DECLARE  @jiraTicketLoc NVARCHAR(250) = N'\\fs04\public\DBA\Deployments\UpdateJiraTicket'
	   , @jiraTicket NVARCHAR(250)
	   , @thursDayDeployment NVARCHAR(250) = ''
	   , @SingleLineOutput NVARCHAR(max)
	   , @sourceID INT
        , @move NVARCHAR(1000)
	   , @sourceSqlFilename nvarchar(512)
	   , @sourceDepth int
	   , @sourceIsFile BIT
	   , @sql VARCHAR(8000)
	   , @sqlRollback VARCHAR(8000)
	   , @serverName NVARCHAR(100)
	   , @executionResults NVARCHAR(MAX)
	   , @subfolder NVARCHAR(250)
	   , @dtMinusTen DATETIME = DATEADD(MINUTE, -10, GETDATE())
	   , @errorLine VARCHAR(1000)
	   , @startCmd VARCHAR(8000)
	   , @executable VARCHAR(1000) = (SELECT xecutable FROM secure.DeploymentValues WHERE ID = (SELECT MAX(ID) FROM secure.deploymentValues)) 
	   , @resultsPath VARCHAR(1000) = (SELECT resultsPath FROM secure.DeploymentValues WHERE ID = (SELECT MAX(ID) FROM secure.deploymentValues))
	   , @sourcePath VARCHAR(1000) = (SELECT SourcePath FROM secure.DeploymentValues WHERE ID = (SELECT MAX(ID) FROM secure.deploymentValues))
	   , @approvedPath VARCHAR(1000) = (SELECT ApprovedPath FROM secure.DeploymentValues WHERE ID = (SELECT MAX(ID) FROM secure.deploymentValues))
	   , @failedPath VARCHAR(1000) = (SELECT FailedPath FROM secure.DeploymentValues WHERE ID = (SELECT MAX(ID) FROM secure.deploymentValues))
	   , @hKey VARCHAR(5000) = (SELECT hkey FROM secure.DeploymentValues WHERE ID = (SELECT MAX(ID) FROM secure.deploymentValues))
	   , @ddlCommands VARCHAR(5000) = (SELECT ddlCommands FROM secure.DeploymentValues WHERE ID = (SELECT MAX(ID) FROM secure.deploymentValues))
	   , @pKey VARCHAR(1000) = (SELECT pkey FROM secure.DeploymentValues WHERE ID = (SELECT MAX(ID) FROM secure.deploymentValues))


DECLARE @CommandShellOutputTable TABLE (Line NVARCHAR(MAX)) 

--=====================================================================
-- Build some temp tables to hold list of files and results.
--=====================================================================

IF OBJECT_ID('tempdb..#dir', 'U') IS NOT NULL 
  DROP TABLE #dir; 

CREATE TABLE #dir (ID INT IDENTITY(1,1)
				, Subdir NVARCHAR(512)
				, depth INT
				, IsFile BIT
				, serverName NVARCHAR(250)
				, JiraTicket NVARCHAR(128))

IF OBJECT_ID('tempdb..#subdir', 'U') IS NOT NULL 
  DROP TABLE #subdir; 

CREATE TABLE #subdir (ID INT IDENTITY(1,1)
				, Subdir NVARCHAR(512)
				, depth INT
				, IsFile BIT
				, serverName NVARCHAR(250))

IF OBJECT_ID('tempdb..#results', 'U') IS NOT NULL 
  DROP TABLE #results; 

CREATE TABLE #results (SqlFileName NVARCHAR(512)
				   , ExecutionCode NVARCHAR(512)
				   , ResultOutput NVARCHAR(MAX)
				   , serverName VARCHAR(250)
				   , jiraTicket NVARCHAR(128)
				   , ErrorMsg VARCHAR(1000)
				   , Runtime DATETIME DEFAULT GETDATE());

--=====================================================================
-- Insert files into table and pull out server name from file name
--=====================================================================

INSERT #dir (Subdir, depth, IsFile)
EXEC master.sys.xp_dirtree @sourcePath, 1, 1;

--=====================================================================
-- Enable use of xp_cmdshell if there are files to pull out
--=====================================================================
IF (SELECT COUNT(*) FROM #dir) > 0

BEGIN

    EXEC sp_configure 'show advanced options', 1
    
    RECONFIGURE
    
    EXEC sp_configure 'xp_cmdshell', 1
    
    RECONFIGURE

    SELECT @startCmd = @executable + ' "' + @resultsPath + '" "' + @sourcePath + '" "' + @approvedPath + '" "' + @failedPath + '" "' + @hKey + '" "' + @ddlCommands + '" "' + @pKey +'"'

END
--===============================================================================================================================
-- Handles Thursday deployments
--===============================================================================================================================

IF (SELECT DATEPART(dw, GETDATE())) = 5 AND (SELECT CAST(GETDATE() AS TIME)) >= '6:50:00' --Date is thursday and time is after 6:50PM (will pick up files on next run @ 7)
BEGIN

    WHILE (SELECT COUNT(*) FROM #dir WHERE IsFile = 0 AND Subdir = 'Thursday Deployments' ) > 0
    BEGIN
	  SELECT TOP 1 @subfolder = @sourcePath+'\'+subdir
	  FROM #dir
	  WHERE IsFile = 0 AND Subdir = 'Thursday Deployments'

	  INSERT #subdir (Subdir, depth, IsFile)
	  EXEC master.sys.xp_dirtree @subfolder, 1, 1;

    --=====================================================================
    -- Pulls files out of scheduled deployment directory
    --=====================================================================

	  WHILE (SELECT COUNT(*) FROM #subdir) > 0

	  BEGIN

		 SELECT TOP 1 @sourceSqlFilename = subdir
		 FROM #subdir

		 DELETE FROM #subdir WHERE Subdir = @sourceSqlFilename

		 SET @move =  'MOVE "' +@subfolder+ '\'+ @sourceSqlFilename + '" ' + '"'+@sourcePath+'"'
		 EXEC master.dbo.xp_cmdshell @move

	  END

      DELETE FROM #dir WHERE @sourcePath+'\'+Subdir = @subfolder AND IsFile = 0 AND Subdir = 'Thursday Deployments'

    END
    
END
--===============================================================================
-- Set subfolder back to nothing at the end so the deployment dir isnt' removed
--===============================================================================

SET @subfolder = ''

--===============================================================================================================================
-- If there are subdirectories (scheduled deployments, pull out all files and move to main deployments folder
-- this happens 10 minutes prior to deployment time, but they don't get executed until the following run (10 minutes)
--===============================================================================================================================

WHILE (SELECT COUNT(*) FROM #dir WHERE IsFile = 0 AND @dtMinusTen >= CAST(REPLACE(Subdir, '_',':')AS DATETIME) AND Subdir <> 'Thursday Deployments'  ) > 0
BEGIN
   SELECT TOP 1 @subfolder = @sourcePath+'\'+subdir
   FROM #dir
   WHERE IsFile = 0 AND @dtMinusTen >= CAST(REPLACE(Subdir, '_',':')AS DATETIME) AND Subdir <> 'Thursday Deployments' 

   INSERT #subdir (Subdir, depth, IsFile)
   EXEC master.sys.xp_dirtree @subfolder, 1, 1;

--=====================================================================
-- Pulls files out of scheduled deployment directory
--=====================================================================

   WHILE (SELECT COUNT(*) FROM #subdir) > 0

   BEGIN

	  SELECT TOP 1 @sourceSqlFilename = subdir
	  FROM #subdir

	  DELETE FROM #subdir WHERE Subdir = @sourceSqlFilename

	  SET @move =  'MOVE "' +@subfolder+ '\'+ @sourceSqlFilename + '" ' + '"'+@sourcePath+'"'
	  EXEC master.dbo.xp_cmdshell @move

   END

--=====================================================================
-- Remove scheduled deployment directory after all files were extracted
--=====================================================================

   DELETE FROM #dir WHERE @sourcePath+'\'+Subdir = @subfolder AND IsFile = 0

   SET @subfolder = 'RMDIR "' + @subfolder + '"'
   EXEC master.dbo.xp_cmdshell @subfolder

END

--==============================================================================================================
-- Check Upcoming deployments for scripts making DDL changes and apply deployment key
--==============================================================================================================

EXEC master.dbo.xp_cmdshell @startCmd , no_output

--=====================================================================
-- Pull out server name from beginning of script
--=====================================================================

UPDATE #dir 
SET serverName = SUBSTRING(Subdir, 0, CHARINDEX(' - ', Subdir))
WHERE RIGHT(Subdir, 4) = '.sql'

--========================================================================================================
-- Pull out name of the script without server name or extension and disregard rollback scripts
-- This is done assuming that most if not all scripts will be named after a JIRA ticket
--========================================================================================================

UPDATE #dir 
SET  JiraTicket = Substring(subdir, CHARINDEX(' - ', subdir)+3, CHARINDEX('.sql',Subdir) - CHARINDEX(' - ', subdir)-3 ) 
WHERE RIGHT(Subdir, 4) = '.sql' AND RIGHT(subdir, 12) <> 'rollback.sql' AND IsFile = 1

--=====================================================================
-- Cursor to iterate through the files and write to results table
--=====================================================================

DECLARE deployScriptCursor CURSOR FOR
    SELECT ID
         , Subdir
         , depth
         , IsFile
         , serverName
	    , JiraTicket 
    FROM #dir
    WHERE IsFile = 1 AND RIGHT(Subdir, 4) = '.sql'
		AND RIGHT(Subdir, 12) <> 'ROLLBACK.sql'

OPEN deployScriptCursor
FETCH NEXT FROM deployScriptCursor
INTO @sourceID, @sourceSqlFilename, @sourceDepth, @sourceIsFile, @serverName, @jiraTicket

WHILE @@FETCH_STATUS = 0
    BEGIN
--=====================================================================
-- Make sure output table is clear
--=====================================================================
	   
	   DELETE from @CommandShellOutputTable

--=====================================================================
-- Build and excute command, then dump into results table
--=====================================================================

	   SET @sql = 'sqlcmd -S '+ @serverName + ' -d master -i ' + '"' + @sourcePath +'\'+ @sourceSqlFilename + '"'

	   INSERT INTO @CommandShellOutputTable (Line)
	   EXEC sys.xp_cmdshell @sql

	   INSERT INTO #results (SqlFileName
	                       , ExecutionCode
	                       , serverName
					   , jiraTicket)
	   SELECT @sourceSqlFilename
			, @sql
			, @serverName
			, @jiraTicket

--========================================================================================
-- Search output line(s) for indications of errors
-- If there is a failure try to find the rollback script and execute it
--========================================================================================

	   IF EXISTS (SELECT TOP(1) 1 FROM @CommandShellOutputTable WHERE Line LIKE '%Msg%')
		  BEGIN

			 SET @sourceSqlFilename = LEFT(@sourceSqlFilename, CHARINDEX('.sql', @sourceSqlFilename)-1)

			 IF EXISTS (SELECT TOP(1) 1 FROM #dir WHERE Subdir = @sourceSqlFilename+'-ROLLBACK.sql')
				BEGIN

				    SET @sql = 'sqlcmd -S '+ @serverName + ' -d master -i ' + '"' + @sourcePath +'\'+ @sourceSqlFilename+'-ROLLBACK.sql' + '"'
				    
				    SELECT @errorLine = LINE
				    FROM @CommandShellOutputTable
				    WHERE Line LIKE '%msg%'

				    DELETE from @CommandShellOutputTable

				    INSERT INTO @CommandShellOutputTable (Line)
				    EXEC sys.xp_cmdshell @sql
				END
--=======================================================================================
-- Try to Rollback failures, and log original error
-- If rollback fails, the logged error will be the error in the rollback script
--=======================================================================================

			 IF NOT EXISTS (SELECT TOP(1) 1 FROM @CommandShellOutputTable WHERE Line LIKE '%Msg%') 
				BEGIN
				    UPDATE #results
				    SET ResultOutput = 'FAILED - ROLLEDBACK', ErrorMsg = @errorLine
				    FROM @CommandShellOutputTable
				    WHERE (SqlFileName = @sourceSqlFilename+'.sql')
				END
			 ELSE
				BEGIN
				    UPDATE #results
				    SET ResultOutput = 'FAILED - NOT ROLLED BACK', ErrorMsg = Line
				    FROM @CommandShellOutputTable
				    WHERE SqlFileName = @sourceSqlFilename+'.sql' AND LINE LIKE '%msg%'
				END
		  END

--=====================================================================
-- Set different status for deployments wrapped in IF
--=====================================================================
		
	   IF EXISTS (SELECT TOP(1) 1 FROM @CommandShellOutputTable WHERE Line = 'Deployment not scheduled')
		  BEGIN
			 UPDATE #results
			 SET ResultOutput = 'WAIT'
			 WHERE SqlFileName = @sourceSqlFilename
		  END

--=====================================================================
-- Log Successful Deployments
--=====================================================================

	   IF NOT EXISTS (SELECT TOP(1) 1 FROM @CommandShellOutputTable WHERE line LIKE '%Msg%')
		  BEGIN 
			 UPDATE #results
			 SET ResultOutput = 'SUCCESSFUL'
			 WHERE SqlFileName = @sourceSqlFilename
		  END
		 		  
	   FETCH NEXT FROM deployScriptCursor
	   INTO @sourceID, @sourceSqlFilename, @sourceDepth, @sourceIsFile, @serverName, @jiraTicket
   END;

CLOSE deployScriptCursor
DEALLOCATE deployScriptCursor

--========================================================================
-- Write to Results table, and move files to success or failure folders
--========================================================================
INSERT INTO DBA_Data.dbo.DeploymentResults
SELECT SqlFileName
    , ExecutionCode
    , ResultOutput
    , serverName
    , jiraTicket
    , ErrorMsg
    , Runtime
FROM #results

WHILE (SELECT COUNT(*) FROM #results) > 0
BEGIN

    SELECT TOP 1 @sourceSqlFilename = SqlFileName, @executionResults = ISNULL(ResultOutput, 'UNKNOWN'), @jiraTicket = jiraTicket, @serverName = serverName
    FROM #results

    IF @executionResults = 'SUCCESSFUL'
    BEGIN
	   SET @move = 'MOVE "' +@sourcePath+ '\'+ @sourceSqlFilename + '" ' + '"'+@approvedPath+'"'
	   EXEC master.dbo.xp_cmdshell @move , no_output
    END
    IF @executionResults = 'WAIT'
	  BEGIN
	  SELECT @sourceSqlFilename + ' Not Moved'
	  END
    IF @executionResults LIKE 'FAILED%'
    BEGIN
	   SET @move =  'MOVE "' +@sourcePath+ '\'+ @sourceSqlFilename + '" ' + '"'+@failedPath+'"'
	   EXEC master.dbo.xp_cmdshell @move , no_output
	   SET @move =  'MOVE "' +@sourcePath+ '\'+ LEFT(@sourceSqlFilename, CHARINDEX('.sql', @sourceSqlFilename)-1)+'-Rollback.sql' + '" ' + '"'+@failedPath+'"'
	   EXEC master.dbo.xp_cmdshell @move , no_output
    END

--=============================================================================================
-- Call .EXE to add a comment to JIRA ticket and populate with results of script execution
--=============================================================================================
    
    SET @jiraTicketLoc = '\\fs04\public\DBA\Deployments\UpdateJiraTicket\JiraTicketAddComment.exe '
					   + @jiraTicket +' "Deployment of _'+ @sourceSqlFilename +'_ to ' + @serverName + ' has been executed. Result: ' + @executionResults+'"'


    EXEC xp_cmdshell @jiraTicketLoc , no_output

    DELETE FROM #results
    WHERE SqlFileName = @sourceSqlFilename AND ResultOutput = @executionResults AND jiraTicket = @jiraTicket AND serverName = @serverName

END

--========================================================================
-- Remove the deployment key from any failed or successful deployments.
--========================================================================

EXEC master.dbo.xp_cmdshell @startCmd , no_output

--=====================================================================
-- Make sure use of xp_cmdshell is turned back off
--=====================================================================
IF (SELECT COUNT(*) FROM #dir) > 0

BEGIN

    EXEC sp_configure 'xp_cmdshell', 0
    
    RECONFIGURE

    EXEC sp_configure 'show advanced options', 0
    
    RECONFIGURE
    
END

END




