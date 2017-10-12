USE DBA_Data
GO

CREATE VIEW vwDeploymentPhase
AS

/***********************************************************************************************************************************************

-- Author: William Bratz
--
-- Create Date: 
--
-- Description:
--
-- Original Requester/Owner: 
--
-- Changelog: 

***********************************************************************************************************************************************/

WITH QAdeployed AS (
    SELECT d.ID
         , d.SqlFileName
         , d.ExecutionCode
         , d.ResultOutput
         , d.serverName
         , d.DatabaseName
         , d.JiraTicket
         , d.ErrorMsg
         , d.IsMultiple
         , d.DeployOrder
         , d.HasRollBack
         , d.RollbackScriptName
         , d.RolledBack
         , d.Runtime
         , d.CommentAdded
    FROM dbo.DeploymentResults d
    OUTER APPLY (SELECT MAX(Runtime) maxruntime FROM dbo.DeploymentResults de WHERE d.JiraTicket = de.JiraTicket) maxrun
    WHERE (serverName = 'US-HEN-SQLQA' OR serverName = 'US-HEN-QASQL') 
		AND ResultOutput = 'SUCCEEDED' -- Result MUST be succeeded
		AND ISNULL(d.RolledBack, 0) = 0 -- MUST NOT be rolled back
		AND d.Runtime = maxrun.maxruntime -- MUST be most recent runtime
		)
--Commented out until UAT is implemented

--, UATDeployed AS (
--    SELECT d.ID
--         , d.SqlFileName
--         , d.ExecutionCode
--         , d.ResultOutput
--         , d.serverName
--         , d.DatabaseName
--         , d.JiraTicket
--         , d.ErrorMsg
--         , d.IsMultiple
--         , d.DeployOrder
--         , d.HasRollBack
--         , d.RollbackScriptName
--         , d.RolledBack
--         , d.Runtime
--         , d.CommentAdded
--    FROM dbo.DeploymentResults d
--    OUTER APPLY (SELECT MAX(Runtime) maxruntime FROM dbo.DeploymentResults de WHERE d.JiraTicket = de.JiraTicket) maxrun
--    WHERE (serverName = 'US-HEN-SQLUAT' OR serverName = 'US-HEN-UATSQL') 
--		AND ResultOutput = 'SUCCEEDED' -- Result MUST be succeeded
--		AND ISNULL(d.RolledBack, 0) = 0 -- MUST NOT be rolled back
--		AND d.Runtime = maxrun.maxruntime -- MUST be most recent runtime

 SELECT * FROM QAdeployed
