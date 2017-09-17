using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;


// =====================================================================================================================
// AUTHOR: Billy
//
// CREATE DATE: 7/27/2017
//
// PURPOSE: Parses SQL files for automated deployments
//
// SPECIAL NOTES: 
//
// =====================================================================================================================
// Change History: 
//                  07-31-2017 - Billy - Altered CheckDdl to use command line args for ddlcommands, removed hardcoded values.
//                  07-31-2017 - Billy - Altered deployment key to remove first two lines, fixed sql execution issue.
//                  08-08-2017 - Billy - Added call to Jira app, removing it from sql script. Fixes issue with proc hanging due to jira being unresponsive, currently disabled.
//                  08-17-2017 - Billy - Added archiving file ability based on YearMonth of deployment.
//                  08-17-2017 - Billy - Adds CheckKey to ensure deployment key removal even if it exists in NON DDL script.
//                  09-16-2017 - Billy - Fixed bug where the deployment scripts would move before key was removed.
//                                       Fixed bug where archive folder would not be created if it didn't exist.
//                                       Fixed bug where exception was thrown if it was a DDL script.
//======================================================================================================================

namespace DeploymentCheck
{
    class Program
    {
        static void Main(string[] args)
        {

            string resultsPath = args[0];
            string resultsFile = Path.Combine(resultsPath, DateTime.Now.ToString("yyyy-MM-dd") + ".txt");
            string sourcePath = args[1];
            string approvedPath = args[2];
            string failedPath = args[3];
            string hashKey = args[4];
            List<string> cmdsDDL = args[5].Split(',').ToList();
            string pKey = args[6];

            string dehash = DeploymentCheck.AddDeploymentKey.Decrypt(hashKey, pKey);

            //add deployment key
            foreach (string scriptFile in Directory.GetFiles(sourcePath, "*.sql"))
                AddDeploymentKey(resultsFile, scriptFile, dehash + "\r\n", cmdsDDL);

            //remove deployment key from succeeded deployments
            foreach (string scriptFile in Directory.GetFiles(approvedPath, "*.sql"))
                RemoveDeploymentKeySucceeded(resultsFile, scriptFile, dehash, approvedPath, cmdsDDL);

            //remove deployment key from failed deployments
            foreach (string scriptFile in Directory.GetFiles(failedPath, "*.sql"))
                RemoveDeploymentKeyFailed(resultsFile, scriptFile, dehash, failedPath, cmdsDDL);

            //Send info to JIRA moved from SQL script to keep proc from hanging if JIRA is unresponsive
            //Failed scripts
            //AddFailedCommentToJira(failedPath);

            //Succeeded scripts
            //AddSucceededCommentToJira(approvedPath);

            //Messing with checking for headers
            //CheckScript(resultsPath, resultsFile);

        }

        private static void AddFailedCommentToJira(string failedPath)
        {
            foreach (string scriptFile in Directory.GetFiles(failedPath, "*.sql"))
            {

                string deploymentArchive = Path.Combine(failedPath, DateTime.Now.ToString("yyyyMM"));
                string jiraTicket = Path.GetFileNameWithoutExtension(scriptFile.Substring(scriptFile.LastIndexOf(' ') + 1));
                string server = Path.GetFileName(scriptFile.Substring(0, scriptFile.IndexOf(" ")));
                string msg = " Deployment of " + Path.GetFileName(scriptFile) + " to " + server + " failed, the database team has been notified.";

                Directory.CreateDirectory(deploymentArchive);

                ProcessStartInfo startInfo = new ProcessStartInfo();
                startInfo.FileName = @"\\fs04\public\DBA\Deployments\UpdateJiraTicket\JiraTicketAddComment.exe";
                startInfo.Arguments = jiraTicket + " " + msg;
                Process.Start(startInfo);

                //File.Move(scriptFile, deploymentArchive + @"\" + Path.GetFileName(scriptFile));

            }
        }

        private static void AddSucceededCommentToJira(string approvedPath)
        {
            foreach (string scriptFile in Directory.GetFiles(approvedPath, "*.sql"))
            {

                string deploymentArchive = Path.Combine(approvedPath, DateTime.Now.ToString("yyyyMM"));
                string jiraTicket = Path.GetFileNameWithoutExtension(scriptFile.Substring(scriptFile.LastIndexOf(' ') + 1));
                string server = Path.GetFileName(scriptFile.Substring(0, scriptFile.IndexOf(" ")));
                string msg = " Deployment of " + Path.GetFileName(scriptFile) + " to " + server + " was successful.";

                Directory.CreateDirectory(deploymentArchive);

                ProcessStartInfo startInfo = new ProcessStartInfo();
                startInfo.FileName = @"\\fs04\public\DBA\Deployments\UpdateJiraTicket\JiraTicketAddComment.exe";
                startInfo.Arguments = jiraTicket + " " + msg;
                Process.Start(startInfo);

                //File.Move(scriptFile, deploymentArchive + @"\" + Path.GetFileName(scriptFile));

            }
        }

        private static void RemoveDeploymentKeyFailed(string resultsFile, string scriptFile, string dehash, string failedPath, List<string> cmdsDDL)
        {

            string scriptContents = File.ReadAllText(scriptFile);
            string scriptName = Path.GetFileName(scriptFile);
            string deploymentArchive = Path.Combine(failedPath, DateTime.Now.ToString("yyyyMM"));

            //Creates archive directory if it doesn't exist
            Directory.CreateDirectory(deploymentArchive);


            // Changed to no longer check for DDL when removing, looks for deployment key and will remove if found
            // Fixes issue where key log read key removed when it didn't exist
            // Acts as fail safe if key is added to a Non DDL script by accident

            //bool isDDL = CheckDdl(scriptContents, cmdsDDL);
            bool hasKey = CheckContext(scriptContents, dehash);
            //if(isDDL)
            if (hasKey)
            {
                string tempFile = Path.GetTempFileName();

                using (var sr = new StreamReader(scriptFile))
                using (var sw = new StreamWriter(tempFile))
                {
                    string line;

                    string kLine = sr.ReadLine();
                    string goLine = sr.ReadLine();

                    while ((line = sr.ReadLine()) != null)
                    {
                        if (line != dehash)
                            sw.WriteLine(line);
                    }
                }

                File.Delete(scriptFile);
                //File.Move(tempFile, scriptFile);

                //Moves to archived folder 
                File.Move(tempFile, deploymentArchive + @"\" + Path.GetFileName(scriptFile));

                //write to results file
                using (StreamWriter sw = new StreamWriter(resultsFile, true))
                {
                    sw.WriteLine(DateTime.Now.ToString() + " " + scriptName + "\t Deployment key removed");
                }

                // string resultContents = File.ReadAllText(resultsFile); //Keep any existing text in the results file
                // File.WriteAllText(resultsFile, resultContents + DateTime.Now.ToString() + " " + scriptName + "\t Deployment key removed \r\n");
            }
            //Move the file to the archived folder if its not a DDL script
            else
            {
                File.Move(scriptFile, deploymentArchive + @"\" + Path.GetFileName(scriptFile));
            }
        }

        private static void RemoveDeploymentKeySucceeded(string resultsFile, string scriptFile, string dehash, string approvedPath ,List<string> cmdsDDL)
        {
            string scriptContents = File.ReadAllText(scriptFile);
            string scriptName = Path.GetFileName(scriptFile);
            string deploymentArchive = Path.Combine(approvedPath, DateTime.Now.ToString("yyyyMM"));

            // Changed to no longer check for DDL when removing, looks for deployment key and will remove if found
            // Fixes issue where key log read key removed when it didn't exist
            // Acts as fail safe if key is added to a Non DDL script by accident

            //Creates archive directory if it doesn't exist
            Directory.CreateDirectory(deploymentArchive);

            //bool isDDL = CheckDdl(scriptContents, cmdsDDL);
            bool hasKey = CheckContext(scriptContents, dehash);
            //if(isDDL)
            if(hasKey)
            {
                string tempFile = Path.GetTempFileName();

                using (var sr = new StreamReader(scriptFile))
                using (var sw = new StreamWriter(tempFile))
                {
                    string line;

                    string kLine = sr.ReadLine();
                    string goLine = sr.ReadLine();

                    while ((line = sr.ReadLine()) != null)
                    {
                        if (line != dehash)
                            sw.WriteLine(line);
                    }
                }

                File.Delete(scriptFile);
                //File.Move(tempFile, scriptFile);
                Directory.CreateDirectory(deploymentArchive);
                File.Move(tempFile, deploymentArchive + @"\" + Path.GetFileName(scriptFile));


                //write to results file
                using (StreamWriter sw = new StreamWriter(resultsFile, true))
                {
                    sw.WriteLine(DateTime.Now.ToString() + " " + scriptName + "\t Deployment key removed");
                }

                //string resultContents = File.ReadAllText(resultsFile); //Keep any existing text in the results file
                //File.WriteAllText(resultsFile, resultContents + DateTime.Now.ToString() + " " + scriptName + "\t Deployment key removed \r\n");
            }
            //Move the file to the archived folder if its not a DDL script
            else
            {
                File.Move(scriptFile, deploymentArchive + @"\" + Path.GetFileName(scriptFile));
            }

        }

        private static void AddDeploymentKey(string resultsFile, string scriptFile, string dehash, List<string> cmdsDDL)
        {

            string scriptContents = File.ReadAllText(scriptFile);
            string scriptName = Path.GetFileName(scriptFile);
            bool isDDL = CheckDdl(scriptContents, cmdsDDL);

            if(isDDL)
            {
                File.WriteAllText(scriptFile, dehash + scriptContents);
            }

            //write to results file
            using (StreamWriter sw = new StreamWriter(resultsFile, true))
            {
                sw.WriteLine(DateTime.Now.ToString() + " " + scriptName + "\t Deployment key added");
            }

            //string resultContents = File.ReadAllText(resultsFile); //Keep any existing text in the results file
            //File.WriteAllText(resultsFile, resultContents + DateTime.Now.ToString() + " " + scriptName + "\t Deployment key removed \r\n");

        }

        private static bool CheckDdl (string contents, List<string> ddlCommands)
        {
            return ddlCommands.Any(contents.ToUpper().Contains);
        }

        private static bool CheckContext(string contents, string key)
        {
            return contents.Contains(key);
        }
        
        private static void CheckScript(string resultsPath, string resultsFile)
        {
            string sourcePath = @"\\fs04\public\DBA\Deployments\UpcomingDeployments";
            string approvedPath = @"\\fs04\public\DBA\Deployments\SuccessfulDeployments";
            string deniedPath = @"\\fs04\public\DBA\Deployments\FailedDeployments";
            //string resultsPath = @"\\fs04\public\DBA\Deployments\UpcomingDeployments";
            //string resultsFile = Path.Combine(resultsPath, DateTime.Now.ToString("yyyy-MM-dd")+".txt"); //Build Results files

            //Look for SQL files in the source directory, does not look in subfolders
            foreach (string scriptFile in Directory.GetFiles(sourcePath, "*.sql"))

            {

                string scriptContents = File.ReadAllText(scriptFile);
                string scriptName = Path.GetFileName(scriptFile);


                if (!File.Exists(resultsFile)) //If there is something to check, build a results file if it doesn't exist
                {
                    File.CreateText(resultsFile);
                }
                    
                string resultContents = File.ReadAllText(resultsFile); //Keep any existing text in the results file

                //Look for a keyword used in the header
                if (scriptContents.Contains("Author:"))
                {
                    //if the file exists in the path add the current datetime to the end of the filename
                    if (File.Exists(Path.Combine(approvedPath, scriptName)))
                    {
                        scriptName = Path.GetFileNameWithoutExtension(scriptFile) + " " + DateTime.Now.ToString("yyyy-dd-M HH-mm") + ".sql";
                    }

                    //If keyword is found move the file to the approved path and write to the results file
                    File.Copy(scriptFile, Path.Combine(approvedPath, scriptName));
                    File.WriteAllText(resultsFile, resultContents + DateTime.Now.ToString() + " " + scriptName + "\t Header Check: PASSED \r\n");
                }

                else
                {
                    //If its not found move the file to the denied path and write to the results file
                    File.WriteAllText(resultsFile, resultContents + DateTime.Now.ToString() + " " + scriptName + "\t Header Check: FAILED \r\n");

                    //if the file exists in the path add the current datetime to the end of the filename
                    if (File.Exists(Path.Combine(deniedPath, scriptName)))
                    {
                        scriptName = Path.GetFileNameWithoutExtension(scriptFile) + " " + DateTime.Now.ToString("yyyy-dd-M HH-mm") + ".sql";
                    }

                    //If keyword is found move the file to the denied path and write to the results file
                    File.Copy(scriptFile, Path.Combine(deniedPath, scriptName));
                    File.WriteAllText(Path.Combine(deniedPath, scriptName), "NO HEADER FOUND \r\n \r\n" + scriptContents);
                }
            }
        }
    }
}
