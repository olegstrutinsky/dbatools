function Invoke-DbaDbShrink {
    <#
        .SYNOPSIS
            Shrinks all files in a database. This is a command that should rarely be used.

            - Shrinks can cause severe index fragmentation (to the tune of 99%)
            - Shrinks can cause massive growth in the database's transaction log
            - Shrinks can require a lot of time and system resources to perform data movement

        .DESCRIPTION
            Shrinks all files in a database. Databases should be shrunk only when completely necessary.

            Many awesome SQL people have written about why you should not shrink your data files. Paul Randal and Kalen Delaney wrote great posts about this topic:

                http://www.sqlskills.com/blogs/paul/why-you-should-not-shrink-your-data-files
                http://sqlmag.com/sql-server/shrinking-data-files

            However, there are some cases where a database will need to be shrunk. In the event that you must shrink your database:

            1. Ensure you have plenty of space for your T-Log to grow
            2. Understand that shrinks require a lot of CPU and disk resources
            3. Consider running DBCC INDEXDEFRAG or ALTER INDEX ... REORGANIZE after the shrink is complete.

        .PARAMETER SqlInstance
            The target SQL Server instances

        .PARAMETER SqlCredential
            SqlCredential object used to connect to the SQL Server as a different user.

        .PARAMETER Database
            The database(s) to process - this list is auto-populated from the server. If unspecified, all databases will be processed.

        .PARAMETER ExcludeDatabase
            The database(s) to exclude - this list is auto-populated from the server

        .PARAMETER AllUserDatabases
            Run command against all user databases

        .PARAMETER PercentFreeSpace
            Specifies how much to reduce the database in percent, defaults to 0.

        .PARAMETER ShrinkMethod
            Specifies the method that is used to shrink the database
                Default
                    Data in pages located at the end of a file is moved to pages earlier in the file. Files are truncated to reflect allocated space.
                EmptyFile
                    Migrates all of the data from the referenced file to other files in the same filegroup. (DataFile and LogFile objects only).
                NoTruncate
                    Data in pages located at the end of a file is moved to pages earlier in the file.
                TruncateOnly
                    Data distribution is not affected. Files are truncated to reflect allocated space, recovering free space at the end of any file.

        .PARAMETER StatementTimeout
            Timeout in minutes. Defaults to infinity (shrinks can take a while.)

        .PARAMETER LogsOnly
            Deprecated. Use FileType instead

        .PARAMETER FileType
            Specifies the files types that will be shrunk
                All
                    All Data and Log files are shrunk, using database shrink (Default)
                Data
                    Just the Data files are shrunk using file shrink
                Log
                    Just the Log files are shrunk using file shrink

        .PARAMETER ExcludeIndexStats
            Exclude statistics about fragmentation

        .PARAMETER ExcludeUpdateUsage
            Exclude DBCC UPDATE USAGE for database

        .PARAMETER WhatIf
            Shows what would happen if the command were to run

        .PARAMETER Confirm
            Prompts for confirmation of every step. For example:

            Are you sure you want to perform this action?
            Performing the operation "Shrink database" on target "pubs on SQL2016\VNEXT".
            [Y] Yes  [A] Yes to All  [N] No  [L] No to All  [S] Suspend  [?] Help (default is "Y"):

        .PARAMETER EnableException
            By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
            This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
            Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

        .NOTES
            Tags: Shrink, Database

            Website: https://dbatools.io
            Copyright: (C) Chrissy LeMaire, clemaire@gmail.com
            License: MIT https://opensource.org/licenses/MIT

        .LINK
            https://dbatools.io/Invoke-DbaDatabaseShrink

        .EXAMPLE
            Invoke-DbaDatabaseShrink -SqlInstance sql2016 -Database Northwind,pubs,Adventureworks2014

            Shrinks Northwind, pubs and Adventureworks2014 to have as little free space as possible.

        .EXAMPLE
            Invoke-DbaDatabaseShrink -SqlInstance sql2014 -Database AdventureWorks2014 -PercentFreeSpace 50

            Shrinks AdventureWorks2014 to have 50% free space. So let's say AdventureWorks2014 was 1GB and it's using 100MB space. The database free space would be reduced to 50MB.

        .EXAMPLE
            Invoke-DbaDatabaseShrink -SqlInstance sql2012 -AllUserDatabases

            Shrinks all databases on SQL2012 (not ideal for production)
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param (
        [parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [Alias("ServerInstance", "SqlServer")]
        [DbaInstanceParameter[]]$SqlInstance,
        [Alias("Credential")]
        [PSCredential]$SqlCredential,
        [Alias("Databases")]
        [object[]]$Database,
        [object[]]$ExcludeDatabase,
        [switch]$AllUserDatabases,
        [ValidateRange(0, 99)]
        [int]$PercentFreeSpace = 0,
        [ValidateSet('Default', 'EmptyFile', 'NoTruncate', 'TruncateOnly')]
        [string]$ShrinkMethod = "Default",
        [ValidateSet('All', 'Data', 'Log')]
        [string]$FileType = "All",
        [int]$StepSizeMB,
        [int]$StatementTimeout = 0,
        [switch]$LogsOnly,
        [switch]$ExcludeIndexStats,
        [switch]$ExcludeUpdateUsage,
        [Alias('Silent')]
        [switch]$EnableException
    )

    begin {
        if ($LogsOnly) {
            Test-DbaDeprecation -DeprecatedOn "1.0.0" -Parameter "LogsOnly"
            $FileType = 'Log'
        }

        $StatementTimeoutSeconds = $StatementTimeout * 60

        $sql = "SELECT
                  avg(avg_fragmentation_in_percent) as [avg_fragmentation_in_percent]
                , max(avg_fragmentation_in_percent) as [max_fragmentation_in_percent]
                FROM sys.dm_db_index_physical_stats (DB_ID(), NULL, NULL, NULL, NULL) AS indexstats
                WHERE indexstats.avg_fragmentation_in_percent > 0 AND indexstats.page_count > 100
                GROUP BY indexstats.database_id"
    }

    process {
        if (!$Database -and !$ExcludeDatabase -and !$AllUserDatabases) {
            Stop-Function -Message "You must specify databases to execute against using either -Database, -Exclude or -AllUserDatabases" -Continue
        }

        foreach ($instance in $SqlInstance) {
            Write-Message -Level Verbose -Message "Connecting to $instance"
            try {
                $server = Connect-SqlInstance -SqlInstance $instance -SqlCredential $SqlCredential
            }
            catch {
                Stop-Function -Message "Failure" -Category ConnectionError -ErrorRecord $_ -Target $instance -Continue
            }

            # changing statement timeout to $StatementTimeout
            if ($StatementTimeout -eq 0) {
                Write-Message -Level Verbose -Message "Changing statement timeout to infinity"
            }
            else {
                Write-Message -Level Verbose -Message "Changing statement timeout to $StatementTimeout minutes"
            }
            $server.ConnectionContext.StatementTimeout = $StatementTimeoutSeconds

            $dbs = $server.Databases | Where-Object { $_.IsSystemObject -eq $false -and $_.IsAccessible }

            if ($Database) {
                $dbs = $dbs | Where-Object Name -In $Database
            }

            if ($ExcludeDatabase) {
                $dbs = $dbs | Where-Object Name -NotIn $ExcludeDatabase
            }

            foreach ($db in $dbs) {

                Write-Message -Level Verbose -Message "Processing $db on $instance"

                if ($db.IsDatabaseSnapshot) {
                    Write-Message -Level Warning -Message "The database $db on server $instance is a snapshot and cannot be shrunk. Skipping database."
                    continue
                }

                $files = @()
                if ($FileType -in ('Log','All')) {
                    $files += $db.LogFiles
                }
                if ($FileType -in ('Data','All')) {
                    $files += $db.FileGroups.Files
                }

                foreach($file in $files) {
                    try {
                        $startingSize = $file.Size / 1024
                        $spaceUsed = $file.UsedSpace / 1024
                        $spaceAvailableMB = ($file.Size - $file.UsedSpace) / 1024
                        $desiredSpaceAvailable = [math]::ceiling((1+($PercentFreeSpace/100)) * $spaceUsed)
                        $desiredFileSize = $spaceUsed + $desiredSpaceAvailable

                        Write-Message -Level Verbose -Message "File: $($file.Name)"
                        Write-Message -Level Verbose -Message "Starting Size (MB): $([int]$startingSize)"
                        Write-Message -Level Verbose -Message "Space Used (MB): $([int]$spaceUsed)"
                        Write-Message -Level Verbose -Message "Starting Freespace (MB): $([int]$spaceAvailableMB)"
                        Write-Message -Level Verbose -Message "Desired Freespace (MB): $([int]$desiredSpaceAvailable)"
                        Write-Message -Level Verbose -Message "Desired FileSize (MB): $([int]$desiredFileSize)"
                    }
                    catch {
                        $success = $false
                        Stop-Function -message "Shrink Failed: $($_.Exception.InnerException)" -EnableException $EnableException -ErrorRecord $_ -Continue
                        continue
                    }

                    if ($spaceAvailableMB -le $desiredSpaceAvailable) {
                        Write-Message -Level Warning -Message "File size of ($startingSize) is less than or equal to the desired outcome ($desiredFileSize)"
                    }
                    else {
                        if ($Pscmdlet.ShouldProcess("$db on $instance", "Shrinking from $([int]$startingSize)MB to $([int]$desiredFileSize)MB")) {
                            if ($server.VersionMajor -gt 8 -and $ExcludeIndexStats -eq $false) {
                                Write-Message -Level Verbose -Message "Getting starting average fragmentation"
                                $dataRow = $server.Query($sql, $db.name)
                                $startingFrag = $dataRow.avg_fragmentation_in_percent
                                $startingTopFrag = $dataRow.max_fragmentation_in_percent
                            }
                            else {
                                $startingTopFrag = $startingFrag = $null
                            }

                            $start = Get-Date
                            try {
                                Write-Message -Level Verbose -Message "Beginning shrink of files"

                                #if($StepSizeMB -and (($spaceAvailableMB - $desiredSpaceAvailable) -gt $stepSizeMB)) {
                                $shrinkGap = ($startingSize - $desiredFileSize)

                                Write-Message -Level Verbose -Message "ShrinkGap: $([int]$shrinkGap) MB"
                                Write-Message -Level Verbose -Message "Step Size MB: $([int]$StepSizeMB) MB"


                                if($StepSizeMB -and ($shrinkGap -gt $stepSizeMB)) {
                                    for($i=1; $i -le [int](($shrinkGap)/$stepSizeMB); $i++) {
                                        Write-Message -Level Verbose -Message "Step: $i"
                                        $shrinkSize = $startingSize - ($stepSizeMB * $i)
                                        if($shrinkSize -lt $desiredFileSize) {
                                            $shrinkSize = $desiredFileSize
                                        }
                                        #$shrinkSize
                                        Write-Message -Level Verbose -Message ("Shrinking {0} to {1}" -f $file.Name, $shrinkSize)
                                        $file.Shrink($shrinkSize, $ShrinkMethod)
                                        $file.Refresh()
                                        #if not shrinking stop
                                    }
                                } else {
                                    $file.Shrink($desiredFileSize, $ShrinkMethod)
                                    $file.Refresh()
                                }
                                $success = $true
                                $notes = "Database shrinks can cause massive index fragmentation and negatively impact performance. You should now run DBCC INDEXDEFRAG or ALTER INDEX ... REORGANIZE"
                            }
                            catch {
                                $success = $false
                                Stop-Function -message "Shrink Failed:  $($_.Exception.InnerException)"  -EnableException $EnableException -ErrorRecord $_ -Continue
                                continue
                            }
                            $end = Get-Date
                            $finalFileSize = $file.Size / 1024
                            $finalSpaceAvailableMB = ($file.Size - $file.UsedSpace) / 1024
                            Write-Message -Level Verbose -Message "Final file size: $([int]$finalFileSize) MB"
                            Write-Message -Level Verbose -Message "Final file space available: $($finalSpaceAvailableMB) MB"

                            if ($server.VersionMajor -gt 8 -and $ExcludeIndexStats -eq $false -and $success -and $FileType -ne 'Log') {
                                Write-Message -Level Verbose -Message "Getting ending average fragmentation"
                            $dataRow = $server.Query($sql, $db.name)
                            $endingDefrag = $dataRow.avg_fragmentation_in_percent
                            $endingTopDefrag = $dataRow.max_fragmentation_in_percent
                            }
                            else {
                                $endingTopDefrag = $endingDefrag = $null
                            }

                            $timSpan = New-TimeSpan -Start $start -End $end
                            $ts = [TimeSpan]::fromseconds($timSpan.TotalSeconds)
                            $elapsed = "{0:HH:mm:ss}" -f ([datetime]$ts.Ticks)

                            $object = [PSCustomObject]@{
                                ComputerName                  = $server.ComputerName
                                InstanceName                  = $server.ServiceName
                                SqlInstance                   = $server.DomainInstanceName
                                Database                      = $db.name
                                File                          = $file.name
                                Start                         = $start
                                End                           = $end
                                Elapsed                       = $elapsed
                                Success                       = $success
                                StartingTotalSizeMB           = [math]::Round($startingSize, 2)
                                StartingUsedMB                = [math]::Round($spaceUsed, 2)
                                FinalTotalSizeMB              = [math]::Round($finalFileSize, 2)
                                StartingAvailableMB           = [math]::Round($spaceAvailableMB, 2)
                                DesiredAvailableMB            = [math]::Round($desiredSpaceAvailable, 2)
                                FinalAvailableMB              = [math]::Round($finalSpaceAvailableMB, 2)
                                StartingAvgIndexFragmentation = [math]::Round($startingFrag, 1)
                                EndingAvgIndexFragmentation   = [math]::Round($endingDefrag, 1)
                                StartingTopIndexFragmentation = [math]::Round($startingTopFrag, 1)
                                EndingTopIndexFragmentation   = [math]::Round($endingTopDefrag, 1)
                                Notes                         = $notes
                            }
                            if ($ExcludeIndexStats) {
                                Select-DefaultView -InputObject $object -ExcludeProperty StartingAvgIndexFragmentation, EndingAvgIndexFragmentation, StartingTopIndexFragmentation, EndingTopIndexFragmentation
                            }
                            else {
                                $object
                            }
                        }
                    }
                }
            }
        }
    }
    end {
        Test-DbaDeprecation -DeprecatedOn "1.0.0" -Alias Invoke-DbaDatabaseShrink
    }
}