USE [DBA_Data]
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
--		    Billy - 08-09-2017 : Added two second wait to not flood JiraAddComment app when there are multiple deployments.
--		    Billy - 08-14-2017 : Fixed issue where rollback script wasn't moved with successful deployments, 
--    						 also no longer sends to JiraAddComment if script name doesn't fit the correct format for a jira ticket.
--		    Billy - 09-06-2017 : Added functionality to handle multiple deployments related to a single jira ticket, multiple deployments are denoted by,
--							adding _ followed by the numerical order of that script, index starts at 1.
--							EX: Jira ticket DBA-111 has two deployment scripts: First script should be named US-HEN-SQL - DBA-111 the second should be named US-HEN-SQL - DBA-111_2.
--		    Billy - 09-26-2017 : Changed the way deployments and Rollbacks are handled. Now all scripts are deployed, as long as they are not a multi script deployment
--							then the table is worked through backwards looking for failed deployments and a rollback is applied.
--		    Billy - 10-03-2017 : Altered of proc, added additional calls to additional procs each with a specific purpose.
--		    Billy - 10-10-2017 : Added in utilization of vwDeploymentPhase that tracks successful deployments through their lifecycle
							this prevents deployments going out to UAT/Production without first being applied to lower environments.
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
	   , @fileName VARCHAR(1000)
	   , @isMultipleFiles BIT
	   , @deployOrder TINYINT

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
				, JiraTicket NVARCHAR(128)
				, IsMultipleFiles BIT NOT NULL DEFAULT 0
				, DeployOrder TINYINT
				, HasRollback BIT
				, RollbackScriptName VARCHAR(512)
				, IsRollback BiT)

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
    -- Pulls files out of deployment directory
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
-- Handles QA deployments
--===============================================================================================================================


WHILE (SELECT COUNT(*) FROM #dir WHERE IsFile = 0 AND Subdir = 'QA Deployments' ) > 0
    BEGIN

	  SELECT TOP 1 @subfolder = @sourcePath+'\'+subdir
	  FROM #dir
	  WHERE IsFile = 0 AND Subdir = 'QA Deployments'

	  INSERT #subdir (Subdir, depth, IsFile)
	  EXEC master.sys.xp_dirtree @subfolder, 1, 1

    --=====================================================================
    -- Pulls files out of deployment directory
    --=====================================================================

	  WHILE (SELECT COUNT(*) FROM #subdir) > 0

	  BEGIN

		 SELECT TOP 1 @sourceSqlFilename = subdir
		 FROM #subdir

		 DELETE FROM #subdir WHERE Subdir = @sourceSqlFilename

		 SET @move =  'MOVE "' +@subfolder+ '\'+ @sourceSqlFilename + '" ' + '"'+@sourcePath+'"'
		 EXEC master.dbo.xp_cmdshell @move

	  END

      DELETE FROM #dir WHERE @sourcePath+'\'+Subdir = @subfolder AND IsFile = 0 AND Subdir = 'QA Deployments'

END
    
--===============================================================================
-- Set subfolder back to nothing at the end so the deployment dir isnt' removed
--===============================================================================

SET @subfolder = ''

--===============================================================================================================================
-- If there are subdirectories (scheduled deployments, pull out all files and move to main deployments folder
-- this happens 10 minutes prior to deployment time, but they don't get executed until the following run (10 minutes)
--===============================================================================================================================

WHILE (SELECT COUNT(*) FROM #dir WHERE IsFile = 0 AND @dtMinusTen >= CAST(REPLACE(Subdir, '_',':')AS DATETIME) AND Subdir <> 'Thursday Deployments' AND Subdir <> 'QA Deployments' ) > 0
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
-- Check Upcoming deployments
--==============================================================================================================
SELECT @startCmd = @executable + ' "' + @resultsPath + '" "' + @sourcePath + '" "' + @approvedPath + '" "' + @failedPath + '" "' + @hKey + '" "' + @ddlCommands + '" "' + @pKey +'" "' + '1' +'"'

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
WHERE RIGHT(Subdir, 4) = '.sql' AND IsFile = 1

UPDATE #dir
SET JiraTicket = LEFT(JiraTicket, CHARINDEX('-ROLLBACK', JiraTicket)-1)
WHERE RIGHT(JiraTicket, 8) = 'ROLLBACK'

--=====================================================================================
-- Look for deployments containing more than 1 file, and set the multiple file flag
--=====================================================================================

UPDATE #dir
SET IsMultipleFiles = 1
WHERE CHARINDEX('_', JiraTicket) <> 0 AND IsFile = 1

--=====================================================================
-- Set the deploy order
--=====================================================================

UPDATE #dir
SET DeployOrder = RIGHT(JiraTicket, LEN(JiraTicket) - CHARINDEX('_', JiraTicket)) 
WHERE IsMultipleFiles = 1 AND IsFile = 1

--===========================================================================================================
-- Look for an instance where there is a deployment order >= 2 and a deployment order of 1 does not exist
-- this resolves scenarios where someone numbers the 1st deployment _1
--===========================================================================================================

IF EXISTS (SELECT 1 FROM #dir WHERE DeployOrder >= 2) AND NOT EXISTS (SELECT 1 FROM #dir WHERE DeployOrder = 1) 
BEGIN
    UPDATE d1
    SET DeployOrder = 1, IsMultipleFiles = 1
    FROM #dir d1
    JOIN #dir d2
        ON d1.JiraTicket+'_2' = d2.JiraTicket
END

--============================================================================
-- Update JiraTicket for multiple deployment scripts to the same jira ticket
--============================================================================

UPDATE #dir
SET JiraTicket = LEFT(JiraTicket, CHARINDEX('_', JiraTicket)-1)
WHERE IsMultipleFiles = 1
	 AND DeployOrder > 1

--=====================================================================
-- Check if a ticket has a rollback
--=====================================================================

UPDATE d1
SET HasRollback = 1
    , RollbackScriptName = d2.subdir
FROM #dir d1
JOIN #dir d2
    ON d1.JiraTicket  = d2.JiraTicket
    AND d1.serverName = d2.serverName
    AND d2.DeployOrder = d1.DeployOrder
    AND d2.Subdir <> d1.Subdir
    AND RIGHT(d1.Subdir, 12) <> 'rollback.sql'

--=====================================================================
-- Anything going to prod must be deployed to QA (and UAT) first
--=====================================================================
SELECT * FROM #dir

DELETE FROM #dir
WHERE serverName IN ('US-HEN-SQL', 'US-HEN-SQLOLAP', 'US-HEN-SQLWEB', 'US-HEN-SQL012', 'US-HEN-OLAP01')
	 AND NOT EXISTS (SELECT 1 FROM vwDeploymentPhase WHERE #dir.JiraTicket = vwDeploymentPhase.JiraTicket)

DELETE FROM #dir
WHERE NOT EXISTS (SELECT 1 FROM #dir d2 WHERE JiraTicket = d2.JiraTicket AND DeployOrder = 1 AND RIGHT(d2.Subdir, 12) <> 'rollback.sql')
	 AND IsMultipleFiles = 1

--=============================================================================================
-- Build table and pass into Proc as Table Valued Parameter if there is something to deploy
--=============================================================================================

IF (SELECT COUNT(*) FROM #dir WHERE IsFile = 1) > 0

BEGIN

    DECLARE @deploymentTable AS DeployTableType
    INSERT INTO @deploymentTable (ScriptName
						   , JiraTicket
						   , ServerName
						   , DatabaseName
						   , HasRollback
						   , RollbackScriptName
						   , IsMultiple
						   , DeployOrder)
    SELECT subdir
		 , JiraTicket
		 , ServerName
		 , NULL
		 , HasRollback
		 , RollbackScriptName
		 , IsMultipleFiles
		 , DeployOrder
    FROM #dir
    WHERE IsFile = 1

    EXEC dbo.Deployscripts @deploymentTable


    WAITFOR DELAY '00:00:05' -- Wait for 5 seconds to ensure all files are finished running before going further

--=====================================================================
-- Move deployment files to correct folder
--=====================================================================

    EXEC dbo.DeploymentFileMoves

    WAITFOR DELAY '00:00:05' -- Wait for 5 seconds to ensure all files are finished running before going further
--=====================================================================
-- Remove key
--=====================================================================

    SELECT @startCmd = @executable + ' "' + @resultsPath + '" "' + @sourcePath + '" "' + @approvedPath + '" "' + @failedPath + '" "' + @hKey + '" "' + @ddlCommands + '" "' + @pKey +'" "'

    EXEC master.dbo.xp_cmdshell @startCmd , no_output

    WAITFOR DELAY '00:00:05' -- Wait for 5 seconds to ensure all files are finished running before going further

--=====================================================================
-- Send comment to JIRA
--=====================================================================

    EXEC dbo.DeploymentAddJiraComment

END
--=====================================================================
-- Make sure xp_cmdshell is turned off
--=====================================================================

EXEC sp_configure 'xp_cmdshell', 0

RECONFIGURE

EXEC sp_configure 'show advanced options', 0

RECONFIGURE



END

/*

DECLARE deployScriptCursor CURSOR FOR
    SELECT ID
         , Subdir
         , depth
         , IsFile
         , serverName
	    , JiraTicket
	    , IsMultipleFiles
	    , DeployOrder 
    FROM #dir
    WHERE IsFile = 1 AND RIGHT(Subdir, 4) = '.sql'
		AND RIGHT(Subdir, 12) <> 'ROLLBACK.sql'
    ORDER BY IsMultipleFiles DESC, JiraTicket, DeployOrder

OPEN deployScriptCursor
FETCH NEXT FROM deployScriptCursor
INTO @sourceID, @sourceSqlFilename, @sourceDepth, @sourceIsFile, @serverName, @jiraTicket, @isMultipleFiles, @deployOrder




/*

NOTE!!!!

Pass rollbacks in WITH the deployments

*/




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

			 --Takes off the .sql at the end of the script so we can look for rollbacks
			 SET @sourceSqlFilename = LEFT(@sourceSqlFilename, CHARINDEX('.sql', @sourceSqlFilename)-1)

			 --SELECT @fileName

--===============================================================================================================================
-- If a deployment is a multiple file deployment rollback the failed script and all previously deployed scripts
-- Removes all next deployment scripts tied to the failed deployment from the deployment queue
-- **THIS ASSUMES ALL MULTIPLE DEPLOYMENTS HAVE ROLLBACK SCRIPTS ALL SO ALL MULTIPLE DEPLOYMENTS MUST HAVE ROLLBACK SCRIPTS**
--===============================================================================================================================
			 IF EXISTS(SELECT TOP(1) 1 FROM #dir WHERE Subdir = @sourceSqlFilename+'-ROLLBACK.sql' AND IsMultipleFiles = 1)
				BEGIN
				    SET @fileName = LEFT(@sourceSqlFilename, CHARINDEX('.sql', @sourceSqlFilename)-1)

				    IF ISNUMERIC(RIGHT(@fileName, LEN(@fileName) - CHARINDEX('-', @fileName, CHARINDEX(' - ', @fileName)+2))) = 1
					   BEGIN
						  SET @jiraTicketLoc = '\\fs04\public\DBA\Deployments\UpdateJiraTicket\JiraTicketAddComment.exe '
							 + @jiraTicket +' "Deployment of '+ @sourceSqlFilename +' to ' + @serverName + ' has failed execution, all preceeding deployments have been rolled back and all following deployments have been cancelled''"'
	   
						  EXEC xp_cmdshell @jiraTicketLoc , no_output
					   END

				    WHILE @deployOrder > 0
					   BEGIN
						  
					   IF @deployOrder > 1
						  BEGIN
							 SET @sql = 'sqlcmd -S '+ @serverName + ' -d master -i ' + '"' + @approvedPath +'\'+@serverName+ ' - ' + @jiraTicket + '_' + @deployOrder + '-ROLLBACK.sql' + '"'
						  END
                            ELSE
						  BEGIN
							 SET @sql = 'sqlcmd -S '+ @serverName + ' -d master -i ' + '"' + @approvedPath +'\'+@serverName+ ' - ' + @jiraTicket +'-ROLLBACK.sql' + '"'
						  END
						   
					   SELECT @errorLine = LINE
					   FROM @CommandShellOutputTable
					   WHERE Line LIKE '%msg%'

					   DELETE from @CommandShellOutputTable

					   INSERT INTO @CommandShellOutputTable (Line)
					   EXEC sys.xp_cmdshell @sql

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

					   SET @deployOrder = @deployOrder-1

					   END

					   WHILE @deployOrder < (SELECT MAX(DeployOrder) FROM #dir WHERE JiraTicket = @jiraTicket)
						  BEGIN
						  	 
							 SET @deployOrder = @deployOrder + 1

							 IF @deployOrder > 1
								BEGIN
								    SET @move =  'MOVE "' +@sourcePath+ '\'+ +@serverName+ ' - ' + @jiraTicket + '_' + @deployOrder + '.sql'+ '" ' + '"'+@failedPath+'"'
								    EXEC master.dbo.xp_cmdshell @move , no_output

								    SET @move =  'MOVE "' +@sourcePath+ '\'+ +@serverName+ ' - ' + @jiraTicket + '_' + @deployOrder + '-Rollback.sql' + '" ' + '"'+@failedPath+'"'
								    EXEC master.dbo.xp_cmdshell @move , no_output
								END
							 ELSE
								BEGIN
								    SET @move =  'MOVE "' +@sourcePath+ '\'+ +@serverName+ ' - ' + @jiraTicket + '.sql' + '" ' + '"'+@failedPath+'"'
								    EXEC master.dbo.xp_cmdshell @move , no_output

								    SET @move =  'MOVE "' +@sourcePath+ '\'+ +@serverName+ ' - ' + @jiraTicket + '-Rollback.sql' + '" ' + '"'+@failedPath+'"'
								    EXEC master.dbo.xp_cmdshell @move , no_output
								END

							 DELETE 
							 FROM #dir
							 WHERE JiraTicket = @jiraTicket AND DeployOrder = @deployOrder

						  END

				    END
				    

			 IF EXISTS (SELECT TOP(1) 1 FROM #dir WHERE Subdir = @sourceSqlFilename+'-ROLLBACK.sql' AND IsMultipleFiles = 0)
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

			 IF NOT EXISTS (SELECT TOP(1) 1 FROM @CommandShellOutputTable WHERE Line LIKE '%Msg%' AND @isMultipleFiles = 0) 
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
	   INTO @sourceID, @sourceSqlFilename, @sourceDepth, @sourceIsFile, @serverName, @jiraTicket, @isMultipleFiles, @deployOrder
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

--=================================================================================================
-- If a rollback script exists for a successful deployment move it to the successful folder
--=================================================================================================

	   IF EXISTS (SELECT TOP(1) 1 FROM #dir WHERE Subdir = LEFT(@sourceSqlFilename, CHARINDEX('.sql', @sourceSqlFilename)-1)+'-ROLLBACK.sql')
	   BEGIN
		  SET @move = 'MOVE "' +@sourcePath+ '\'+ LEFT(@sourceSqlFilename, CHARINDEX('.sql', @sourceSqlFilename)-1)+'-Rollback.sql' + '" ' + '"'+@approvedPath+'"'
		  EXEC master.dbo.xp_cmdshell @move , no_output
	   END

    END
    IF @executionResults = 'WAIT'
	  BEGIN
		 SELECT @sourceSqlFilename + ' Not Moved'
	  END
    IF @executionResults LIKE 'FAILED%'
    BEGIN
	   SET @move =  'MOVE "' +@sourcePath+ '\'+ @sourceSqlFilename + '" ' + '"'+@failedPath+'"'
	   EXEC master.dbo.xp_cmdshell @move , no_output

--=====================================================================
-- Move the rollback script to the failed folder if it exists
--=====================================================================

	   SET @move =  'MOVE "' +@sourcePath+ '\'+ LEFT(@sourceSqlFilename, CHARINDEX('.sql', @sourceSqlFilename)-1)+'-Rollback.sql' + '" ' + '"'+@failedPath+'"'
	   EXEC master.dbo.xp_cmdshell @move , no_output
    END

--=============================================================================================
-- Call .EXE to add a comment to JIRA ticket and populate with results of script execution
--=============================================================================================
    
--=====================================================================
--Check if the file fits the format of that of the JIRA ticket
--=====================================================================
    SET @fileName = LEFT(@sourceSqlFilename, CHARINDEX('.sql', @sourceSqlFilename)-1)

    IF ISNUMERIC(RIGHT(@fileName, LEN(@fileName) - CHARINDEX('-', @fileName, CHARINDEX(' - ', @fileName)+2))) = 1
    BEGIN
	   SET @jiraTicketLoc = '\\fs04\public\DBA\Deployments\UpdateJiraTicket\JiraTicketAddComment.exe '
						  + @jiraTicket +' "Deployment of '+ @sourceSqlFilename +' to ' + @serverName + ' has been executed. Result: ' + @executionResults+'"'
	   
	   EXEC xp_cmdshell @jiraTicketLoc , no_output
    END

    --Added two second delay to not overwhelm JiraAddComment APP
    WAITFOR DELAY '00:00:02'

    DELETE FROM #results
    WHERE SqlFileName = @sourceSqlFilename AND ResultOutput = @executionResults AND jiraTicket = @jiraTicket AND serverName = @serverName

END

--========================================================================
-- Remove the deployment key from any failed or successful deployments.
--========================================================================

--EXEC master.dbo.xp_cmdshell @startCmd , no_output

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
*/



