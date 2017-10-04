USE DBA_Data
GO

ALTER PROC DeploymentAddJiraComment
AS
BEGIN

/***********************************************************************************************************************************************

-- Author: William Bratz
--
-- Create Date: 10-03-2017
--
-- Description: Moves files out of the deployment folder dependant on deployment results. 
--		      This is called by a master proc and is part of the auto deployment proces
--
-- Original Requester/Owner: 
--
-- Changelog: 

***********************************************************************************************************************************************/

    DECLARE  @sourcePath VARCHAR(1000) = (SELECT SourcePath FROM secure.DeploymentValues WHERE ID = (SELECT MAX(ID) FROM secure.deploymentValues))
		  , @approvedPath VARCHAR(1000) = (SELECT ApprovedPath FROM secure.DeploymentValues WHERE ID = (SELECT MAX(ID) FROM secure.deploymentValues))
		  , @failedPath VARCHAR(1000) = (SELECT FailedPath FROM secure.DeploymentValues WHERE ID = (SELECT MAX(ID) FROM secure.deploymentValues))
		  , @jiraTicketLoc VARCHAR(8000)
		  , @scriptName VARCHAR(512)
		  , @scriptResult VARCHAR(50)
		  , @rolledBack BIT
            , @serverName VARCHAR(128)
		  , @jiraTicket VARCHAR(64)
		  , @id INT

    DECLARE @LatestDeployments TABLE (ScriptName VARCHAR(512), Result VARCHAR(30), ServerName VARCHAR(128), JiraTicket VARCHAR(64), RolledBack BIT, ID INT)

--=====================================================================
-- Find most recent deployment
--=====================================================================

    ;WITH CTE AS (SELECT MAX(RunTime) LastRun FROM dbo.DeploymentResults)

    INSERT INTO @LatestDeployments (ScriptName
						    , Result
						    , ServerName
						    , JiraTicket
						    , RolledBack
						    , ID)
    SELECT dr.SqlFileName
		 , dr.ResultOutput
		 , dr.serverName
		 , dr.JiraTicket
		 , dr.RolledBack
		 , dr.ID
    FROM dbo.DeploymentResults dr
    WHERE EXISTS (SELECT 1 FROM CTE WHERE LastRun = dr.Runtime)
	     AND dr.ResultOutput NOT LIKE 'ROLLBACK%'
		AND ISNULL(dr.CommentAdded, 0) = 0

--==========================================================================
-- Loop through results list and Comment on the files according the result
--==========================================================================

    WHILE (SELECT COUNT(*) FROM @LatestDeployments) > 0
    BEGIN
    
	   SELECT TOP 1
			  @scriptName = ScriptName
			, @scriptResult = Result
			, @serverName = ServerName
			, @jiraTicket = JiraTicket
			, @rolledBack = RolledBack
			, @id = ID
	   FROM @LatestDeployments

	   DELETE FROM @LatestDeployments
	   WHERE ScriptName = @scriptName
		    AND Result = @scriptResult
		    AND ServerName = @serverName
		    AND JiraTicket = @jiraTicket
		    AND RolledBack = @rolledBack
		    AND ID = @id
--===================================================================================
-- If the deployment was successful and not rolled back move to successful folder
--===================================================================================

	   IF (@scriptResult = 'SUCCEEDED') AND (@rolledBack = 0)
	   BEGIN

	      SET @jiraTicketLoc = '\\fs04\public\DBA\Deployments\UpdateJiraTicket\JiraTicketAddComment.exe '
	   					  + @jiraTicket +' "Deployment of '+ @scriptName +' to ' + @serverName + ' has been executed Successfully."'
	      
	      EXEC xp_cmdshell @jiraTicketLoc , no_output

	   END
--=====================================================================
-- Everything gets a failure message
--=====================================================================

	   ELSE
	   BEGIN
	   	  
	      SET @jiraTicketLoc = '\\fs04\public\DBA\Deployments\UpdateJiraTicket\JiraTicketAddComment.exe '
	   						 + @jiraTicket +' "Deployment of '+ @scriptName +' to ' + @serverName + ' has failed, or was Rolled Back"'
	      
	      EXEC xp_cmdshell @jiraTicketLoc , no_output

	   END

--=====================================================================
-- Ensure we're not commenting on the same thing a bunch of times
--=====================================================================

	   UPDATE dbo.DeploymentResults
	   SET CommentAdded = 1
	   WHERE ID = @id

    END
 END
