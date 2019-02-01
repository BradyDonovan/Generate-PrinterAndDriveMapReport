<#
.SYNOPSIS
Printer & Drive Mapping Report

.DESCRIPTION
Gather information about the drives mapped and printers used by all users on the endpoint, then put a report in the C:\Users\$USER directory of whoever is running the script. Needs to be run as Administrator otherwise it will only report your own printers and drives.

.EXAMPLE
.\Generate-PrinteAndDriveMapReport.ps1

.NOTES
Contact information:
https://github.com/BradyDonovan/
#>
 
Function Get-AllLoggedInUsers {
    $users = ((Get-CimInstance -Query "select Antecedent from Win32_LoggedOnUser") | Select-Object Antecedent -Unique).Antecedent.Name
    $users = foreach ($user in $users) {
        [PSCustomObject]@{
            PSTypeName = 'loggedInUser'
            User       = $User
        }
    }
    Return $users
}
function Get-UserProfilesPaths {
    $profilePaths = (Get-CimInstance -Query "select LocalPath,SID from Win32_UserProfile where (not SID = 'S-1-5-18' and not SID = 'S-1-5-19' and not SID = 'S-1-5-20')")
    Return $profilePaths
}
function Mount-NTUserDat {
    param (
        [string]$ntUserDatLocation
    )
    process {
        IF (Test-Path "$ntUserDatLocation\NTUSER.DAT") {
            $regex = "C:\\Users\\"
            $User = $ntUserDatLocation -replace $regex, ''
            try {
                $proc = Start-Process "C:\Windows\System32\reg.exe" -ArgumentList "load HKU\$User $ntUserDatLocation\NTUSER.DAT" -PassThru -WindowStyle Hidden
                Clear-Host
                $proc.WaitForExit()
                IF ($proc.ExitCode -ne 0) {
                    throw
                }
                ELSE {
                    Return [PSCustomObject]@{
                        PSTypeName = 'offlineUser'
                        User       = $User
                    }
                }
            }
            catch {
                throw "Error mounting $ntUserDatLocation\NTUSER.DAT. Continuing."
            }
        }
        ELSE {
            Return "Cannot access NTUSER.DAT @ $ntUserDatLocation. Continuing."
        }
    }
}
function Get-Printers {
    param (
        [System.Management.Automation.PSTypeName('offlineUser')]$offlineUser,
        [String]$loggedInUser
    )
    begin {
        If ($offlineUser) {
            $User = $offlineUser.user
        }
        IF ($loggedInUser) {
            $User = $loggedInUser
        }
    }
    process {
        IF (Test-Path Registry::HKEY_USERS\$User\Printers\) {
            $printers = Get-ChildItem Registry::HKEY_USERS\$User\Printers\Connections -ErrorAction SilentlyContinue
            IF ($null -eq $printers) {
                Return "No printers found."
            }
            ELSE {
                $printerList = foreach ($printer in $printers) {
                    [PSCustomObject]@{ 
                        PrinterName = $printer.PSChildName -replace ",", "\"
                        PrintServer = $printer.GetValue('Server')
                    }
                }
                Return $printerList 
            }
        }
        ELSE {
            Return "No printers found."
        }
    }
}
function Get-Drives {
    param (
        [System.Management.Automation.PSTypeName('offlineUser')]$offlineUser,
        [String]$loggedInUser
    )
    begin {
        If ($offlineUser) {
            $User = $offlineUser.user
        }
        IF ($loggedInUser) {
            $User = $loggedInUser
        }
    }
    process {
        IF (Test-Path Registry::HKEY_USERS\$User\Network) {
            $drives = Get-ChildItem Registry::HKEY_USERS\$User\Network
            $driveList = foreach ($drive in $drives) {
                [PSCustomObject]@{
                    DriveLetter = $drive.PSChildName
                    RemotePath  = $drive.GetValue('RemotePath')
                    UserName    = $drive.GetValue('UserName') #if null it means no alternate credentials were specified when drive was mapped
                }
            }
            Return $driveList
        }
        ELSE {
            Return "No mapped drives found."
        }
    }
}
function New-Report {
    $loggedInUsers = Get-AllLoggedInUsers
    $userProfiles = Get-UserProfilesPaths
    $regex = "C:\\Users\\"
    $totalUserList = foreach ($user in $userProfiles) {
        [PSCustomObject] @{
            Username = $user.LocalPath -replace $regex, ''
            SID      = $user.SID
        }
    }
    $loggedOutUsers = $totalUserList | Where-Object {$loggedInUsers.User -notcontains $_.UserName} # excluse logged in users. Cannot mount ntuser.dat if user is logged in.
    $loggedInUsers = $totalUserList | Where-Object {$loggedInUsers.User -contains $_.UserName}

    # dig into HKU\$SID registry space for logged in users and run report
    $loggedInUsersReport = foreach ($user in $loggedInUsers) {
        [PSCustomObject]@{
            User     = $User.Username
            Drives   = Get-Drives -loggedInUser $User.SID
            Printers = Get-Printers -loggedInUser $User.SID
        }
    }

    # mount NTUSER.DAT for offline users and run report
    $loggedOutUsersReport = foreach ($user in $loggedOutUsers) {
        Remove-Variable mountError -Force -ErrorAction SilentlyContinue # clear errvar on mounting attempts for each userprofile
        $User = $user.UserName
        $userProfilePath = "C:\Users\$User"
        Try {
            $offlineUser = Mount-NTUserDat -ntUserDatLocation $userProfilePath
        }
        Catch {
            $mountError = $_.Exception.Message
        }
        [PSCustomObject]@{
            User     = $User
            Drives   = IF ($mountError) { 
                "Couldn't mount userspace registry to generate report." 
            }
            ELSE {
                Get-Drives -offlineUser $offlineUser
            }
            Printers = IF ($mountError) {
                "Couldn't mount userspace registry to generate report." 
            }
            ELSE {
                Get-Printers -offlineUser $offlineUser
            }
        }
    }
    $finalReport = $loggedOutUsersReport + $loggedInUsersReport
    Return $finalReport
}

$report = New-Report
Foreach($user in $report) {
   $reportText = "
--------------------------------------------------

User: 
    $(foreach ($UserName in $User.User) {$UserName | Out-String})

Drives: 
    $(foreach ($drive in $User.Drives) {$drive | Out-String})

Printers:
    $(foreach ($printer in $User.Printers) {$printer | Out-String})

--------------------------------------------------
"
    Add-Content -Path "$($User.User)_PrinterAndMappedDriveReport.txt" -Value $reportText -Force
}
