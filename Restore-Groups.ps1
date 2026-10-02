Import-Module ActiveDirectory

# ==========================================
# CONFIGURATION
# ==========================================

$BackupRoot      = "C:\Temp"
$OffboardingRoot = Join-Path $BackupRoot "Offboarding"

# ==========================================
# TARGET USER
# ==========================================

$TargetUser = Read-Host "Enter user login"

try {
    $ADUser = Get-ADUser $TargetUser -ErrorAction Stop
}
catch {
    Write-Host "User not found: $TargetUser" -ForegroundColor Red
    exit
}

# ==========================================
# FIND BACKUPS
# ==========================================

$Backups = @()

# 1. Group exports: C:\Temp\<folder>\groups.csv
Get-ChildItem $BackupRoot -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name |
    ForEach-Object {
        $Csv = Join-Path $_.FullName "groups.csv"
        if (Test-Path $Csv) {
            $Backups += [PSCustomObject]@{
                Label    = "[Export]      $($_.Name)"
                ADFile   = $Csv
                M365File = $null
            }
        }
    }

# 2. Offboarding: C:\Temp\Offboarding\<folder>\AD\Groups_*.csv and M365\GroupsBackup.csv
if (Test-Path $OffboardingRoot) {
    Get-ChildItem $OffboardingRoot -Directory |
        Sort-Object Name |
        ForEach-Object {

            # Most recent AD backup (the script may have been run more than once)
            $ADCsv = Get-ChildItem (Join-Path $_.FullName "AD") -Filter "Groups_*.csv" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1

            $M365Csv = Join-Path $_.FullName "M365\GroupsBackup.csv"
            if (!(Test-Path $M365Csv)) { $M365Csv = $null }

            if ($ADCsv -or $M365Csv) {
                $Backups += [PSCustomObject]@{
                    Label    = "[Offboarding] $($_.Name)"
                    ADFile   = $(if ($ADCsv) { $ADCsv.FullName } else { $null })
                    M365File = $M365Csv
                }
            }
        }
}

if ($Backups.Count -eq 0) {
    Write-Host "No group backups found." -ForegroundColor Red
    exit
}

# ==========================================
# SELECT BACKUP
# ==========================================

Write-Host ""
Write-Host "Available backups:" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Yellow

for ($i = 0; $i -lt $Backups.Count; $i++) {

    $Parts = @()
    if ($Backups[$i].ADFile)   { $Parts += "AD" }
    if ($Backups[$i].M365File) { $Parts += "M365" }

    Write-Host "[$($i+1)] $($Backups[$i].Label)  ($($Parts -join ' + '))"
}

Write-Host ""

$Choice = 0
$Entry  = Read-Host "Select backup number"

if (-not [int]::TryParse($Entry, [ref]$Choice) -or $Choice -lt 1 -or $Choice -gt $Backups.Count) {
    Write-Host "Invalid selection." -ForegroundColor Red
    exit
}

$Selected = $Backups[$Choice - 1]

Write-Host ""
Write-Host "Selected backup: $($Selected.Label)" -ForegroundColor Green

# ==========================================
# RESTORE AD GROUPS
# ==========================================

if ($Selected.ADFile) {

    Write-Host ""
    Write-Host "AD groups" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Yellow

    # User's current groups - used to skip groups they already belong to
    $CurrentGroups = @(Get-ADPrincipalGroupMembership $ADUser | Select-Object -ExpandProperty DistinguishedName)

    $Rows = Import-Csv $Selected.ADFile
    $Ok = 0; $Skipped = 0; $Failed = 0

    foreach ($Row in $Rows) {

        # Exports contain SamAccountName, offboarding backups contain DistinguishedName
        if ($Row.PSObject.Properties.Name -contains "SamAccountName" -and $Row.SamAccountName) {
            $GroupId = $Row.SamAccountName
        }
        else {
            $GroupId = $Row.DistinguishedName
        }

        $GroupLabel = $(if ($Row.Name) { $Row.Name } else { $GroupId })

        try {
            $Group = Get-ADGroup -Identity $GroupId -ErrorAction Stop

            if ($CurrentGroups -contains $Group.DistinguishedName) {
                Write-Host "[SKIPPED] $GroupLabel - user is already a member" -ForegroundColor DarkGray
                $Skipped++
                continue
            }

            Add-ADGroupMember -Identity $Group -Members $ADUser -ErrorAction Stop

            Write-Host "[OK] $GroupLabel" -ForegroundColor Green
            $Ok++
        }
        catch {
            Write-Host "[ERROR] $GroupLabel - $($_.Exception.Message)" -ForegroundColor Red
            $Failed++
        }
    }

    Write-Host ""
    Write-Host "AD: added $Ok, skipped $Skipped, errors $Failed" -ForegroundColor Cyan
}

# ==========================================
# RESTORE M365 GROUPS (optional)
# ==========================================

if ($Selected.M365File) {

    Write-Host ""
    $Answer = Read-Host "The backup also contains M365 cloud groups. Restore them? (Y/N)"

    if ($Answer -match '^[Yy]') {

        Write-Host ""
        Write-Host "M365 groups" -ForegroundColor Cyan
        Write-Host "============================================" -ForegroundColor Yellow

        Import-Module Microsoft.Graph.Users
        Import-Module Microsoft.Graph.Groups

        Connect-MgGraph -Scopes User.Read.All, GroupMember.ReadWrite.All -NoWelcome

        try {
            $MgUser = Get-MgUser -UserId $ADUser.UserPrincipalName -Property Id -ErrorAction Stop
        }
        catch {
            Write-Host "User not found in Entra ID: $($ADUser.UserPrincipalName)" -ForegroundColor Red
            exit
        }

        $CurrentCloud = @(Get-MgUserMemberOf -UserId $MgUser.Id -All | Select-Object -ExpandProperty Id)

        $Rows = Import-Csv $Selected.M365File
        $Ok = 0; $Skipped = 0; $Failed = 0

        foreach ($Row in $Rows) {

            # Groups synchronized from AD are restored in the AD section (via synchronization)
            if ($Row.OnPremisesSyncEnabled -eq "True") {
                Write-Host "[SKIPPED] $($Row.DisplayName) - synchronized from AD" -ForegroundColor DarkGray
                $Skipped++
                continue
            }

            if ($CurrentCloud -contains $Row.GroupId) {
                Write-Host "[SKIPPED] $($Row.DisplayName) - user is already a member" -ForegroundColor DarkGray
                $Skipped++
                continue
            }

            try {
                New-MgGroupMember -GroupId $Row.GroupId -DirectoryObjectId $MgUser.Id -ErrorAction Stop

                Write-Host "[OK] $($Row.DisplayName)" -ForegroundColor Green
                $Ok++
            }
            catch {
                Write-Host "[ERROR] $($Row.DisplayName) - $($_.Exception.Message)" -ForegroundColor Red
                $Failed++
            }
        }

        Write-Host ""
        Write-Host "M365: added $Ok, skipped $Skipped, errors $Failed" -ForegroundColor Cyan
    }
}

Write-Host ""
Write-Host "Restore completed." -ForegroundColor Cyan
