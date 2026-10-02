Import-Module ActiveDirectory

# ==========================================
# CONFIGURATION
# ==========================================

$RootFolder = "C:\Temp\Offboarding"

New-Item -ItemType Directory -Path $RootFolder -Force | Out-Null

# ==========================================
# GET USER
# ==========================================

$UserName = Read-Host "Enter user login"

try {
    $User = Get-ADUser $UserName -Properties * -ErrorAction Stop
}
catch {
    Write-Host "User not found." -ForegroundColor Red
    exit
}

# ==========================================
# USER FOLDER
# ==========================================

$Identity = $User.SamAccountName

# Look for an existing folder ending with "(login)" - the M365 script may have already created it
$ExistingFolder = Get-ChildItem -Path $RootFolder -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name.EndsWith("($Identity)", [StringComparison]::OrdinalIgnoreCase) } |
    Select-Object -First 1

if ($ExistingFolder) {
    $MainUserFolder = $ExistingFolder.FullName
}
else {
    $UserFolderName = "$($User.DisplayName) ($Identity)"
    $UserFolderName = $UserFolderName -replace '[\\/:*?"<>|]', '_'
    $MainUserFolder = Join-Path $RootFolder $UserFolderName
}

$ADFolder = Join-Path $MainUserFolder "AD"

New-Item -ItemType Directory -Path $ADFolder -Force | Out-Null

# ==========================================
# WORKING FILES
# ==========================================

$TimeStamp = Get-Date -Format "yyyyMMdd_HHmmss"

$LogFile = Join-Path $ADFolder "Offboarding_$TimeStamp.log"
$UserBackupFile = Join-Path $ADFolder "UserData_$TimeStamp.csv"
$GroupsBackupFile = Join-Path $ADFolder "Groups_$TimeStamp.csv"
$SummaryFile = Join-Path $ADFolder "Summary.txt"

# ==========================================
# LOG START
# ==========================================

Add-Content $LogFile "===== OFFBOARDING START ====="
Add-Content $LogFile "User: $($User.SamAccountName)"
Add-Content $LogFile "DisplayName: $($User.DisplayName)"
Add-Content $LogFile "Time: $(Get-Date)"

# ==========================================
# ACCOUNT DATA BACKUP
# ==========================================

try {

    [PSCustomObject]@{
        SamAccountName    = $User.SamAccountName
        DisplayName       = $User.DisplayName
        GivenName         = $User.GivenName
        Surname           = $User.Surname
        UserPrincipalName = $User.UserPrincipalName
        Mail              = $User.Mail
        Department        = $User.Department
        Title             = $User.Title
        Company           = $User.Company
        Manager           = $User.Manager
        EmployeeID        = $User.EmployeeID
        Enabled           = $User.Enabled
        LastLogonDate     = $User.LastLogonDate
        DistinguishedName = $User.DistinguishedName
    } |
    Export-Csv $UserBackupFile -NoTypeInformation -Encoding UTF8

    Write-Host "[OK] Account data backup" -ForegroundColor Green
    Add-Content $LogFile "[OK] Account data backup"

}
catch {

    Write-Host "[ERROR] Account data backup" -ForegroundColor Red
    Add-Content $LogFile "[ERROR] Account data backup $_"

}

# ==========================================
# GROUPS BACKUP
# ==========================================

try {

    Get-ADPrincipalGroupMembership $User |
        Select-Object Name, DistinguishedName |
        Export-Csv $GroupsBackupFile -NoTypeInformation -Encoding UTF8

    Write-Host "[OK] Groups backup" -ForegroundColor Green
    Add-Content $LogFile "[OK] Groups backup"

}
catch {

    Write-Host "[ERROR] Groups backup" -ForegroundColor Red
    Add-Content $LogFile "[ERROR] Groups backup $_"

}

# ==========================================
# DISABLE ACCOUNT
# ==========================================

try {

    Disable-ADAccount -Identity $User

    Write-Host "[OK] Account disabled" -ForegroundColor Green
    Add-Content $LogFile "[OK] Account disabled"

}
catch {

    Write-Host "[ERROR] Disabling account" -ForegroundColor Red
    Add-Content $LogFile "[ERROR] Disable Account $_"

}

# ==========================================
# REMOVE MANAGER FROM ACCOUNT
# ==========================================

try {

    Set-ADUser $User -Clear manager

    Write-Host "[OK] Manager removed from account" -ForegroundColor Green
    Add-Content $LogFile "[OK] Manager removed from account"

}
catch {

    Write-Host "[ERROR] Removing manager" -ForegroundColor Red
    Add-Content $LogFile "[ERROR] Removing manager $_"

}

# ==========================================
# DETACH DIRECT REPORTS
# ==========================================

try {

    $DirectReports = Get-ADUser -LDAPFilter "(manager=$($User.DistinguishedName))"

    foreach ($Report in $DirectReports) {

        Set-ADUser $Report -Clear manager

        Write-Host "[OK] Manager detached from $($Report.SamAccountName)" -ForegroundColor Green
        Add-Content $LogFile "[OK] Manager detached from $($Report.SamAccountName)"
    }

}
catch {

    Write-Host "[ERROR] Detaching direct reports" -ForegroundColor Red
    Add-Content $LogFile "[ERROR] Detaching direct reports $_"

}

# ==========================================
# CLEAR CONTACT DETAILS
# ==========================================

try {

    Set-ADUser $User -Clear `
        telephoneNumber,
        mobile,
        facsimileTelephoneNumber,
        ipPhone,
        streetAddress,
        postalCode,
        l,
        st,
        co,
        physicalDeliveryOfficeName,
        info,
        title,
        department

    Write-Host "[OK] Contact details cleared" -ForegroundColor Green
    Add-Content $LogFile "[OK] Contact details cleared"

}
catch {

    Write-Host "[ERROR] Clearing contact details" -ForegroundColor Red
    Add-Content $LogFile "[ERROR] Clearing contact details $_"

}

# ==========================================
# HIDE FROM GAL
# ==========================================

try {

    Set-ADUser $User -Replace @{
        msExchHideFromAddressLists = $true
    }

    Write-Host "[OK] User hidden from GAL" -ForegroundColor Green
    Add-Content $LogFile "[OK] User hidden from GAL"

}
catch {

    Write-Host "[ERROR] Hiding from GAL" -ForegroundColor Red
    Add-Content $LogFile "[ERROR] Hiding from GAL $_"

}

# ==========================================
# REMOVE FROM GROUPS
# ==========================================

Get-ADPrincipalGroupMembership $User |
Where-Object {
    $_.Name -ne "Domain Users"
} |
ForEach-Object {

    try {

        Remove-ADGroupMember `
            -Identity $_ `
            -Members $User `
            -Confirm:$false

        Write-Host "[OK] Removed from group $($_.Name)" -ForegroundColor Green
        Add-Content $LogFile "[OK] Removed from group $($_.Name)"

    }
    catch {

        Write-Host "[ERROR] Not removed from group $($_.Name)" -ForegroundColor Red
        Add-Content $LogFile "[ERROR] Not removed from group $($_.Name) $_"

    }

}

# ==========================================
# SUMMARY
# ==========================================

@"
Display Name: $($User.DisplayName)
SamAccountName: $($User.SamAccountName)
UPN: $($User.UserPrincipalName)
Mail: $($User.Mail)
Offboarding Date: $(Get-Date)

Backup Files:
- $(Split-Path $UserBackupFile -Leaf)
- $(Split-Path $GroupsBackupFile -Leaf)

Log File:
- $(Split-Path $LogFile -Leaf)
"@ | Out-File $SummaryFile -Encoding UTF8

# ==========================================
# COMPLETION
# ==========================================

Add-Content $LogFile "===== OFFBOARDING END ====="
Add-Content $LogFile "End Time: $(Get-Date)"

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "OFFBOARDING COMPLETED" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Cyan

Write-Host ""
Write-Host "User folder:" -ForegroundColor Cyan
Write-Host $MainUserFolder -ForegroundColor Yellow

Write-Host ""
Write-Host "User data backup:" -ForegroundColor Cyan
Write-Host $UserBackupFile -ForegroundColor Yellow

Write-Host ""
Write-Host "Groups backup:" -ForegroundColor Cyan
Write-Host $GroupsBackupFile -ForegroundColor Yellow

Write-Host ""
Write-Host "Log:" -ForegroundColor Cyan
Write-Host $LogFile -ForegroundColor Yellow

Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host $SummaryFile -ForegroundColor Yellow