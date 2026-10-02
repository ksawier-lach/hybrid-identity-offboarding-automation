Import-Module Microsoft.Graph.Users
Import-Module Microsoft.Graph.Groups
Import-Module Microsoft.Graph.Identity.SignIns
Import-Module ExchangeOnlineManagement
 
# ==========================================
# CONNECTIONS
# ==========================================
 
Connect-MgGraph -Scopes `
User.ReadWrite.All, `
Directory.ReadWrite.All, `
Group.ReadWrite.All, `
UserAuthenticationMethod.ReadWrite.All
 
Connect-ExchangeOnline
 
# ==========================================
# GET USER
# ==========================================
 
$UPN = Read-Host "Enter user UPN"
 
try {
    $User = Get-MgUser `
        -UserId $UPN `
        -Property Id,DisplayName,UserPrincipalName,OnPremisesSamAccountName `
        -ErrorAction Stop
}
catch {
    Write-Host "User not found." -ForegroundColor Red
    exit
}

# ==========================================
# FOLDER STRUCTURE
# ==========================================

$RootFolder = "C:\Temp\Offboarding"

New-Item -ItemType Directory -Path $RootFolder -Force | Out-Null

# AD account -> sAMAccountName, cloud-only account -> UPN prefix
if (![string]::IsNullOrWhiteSpace($User.OnPremisesSamAccountName)) {
    $Identity = $User.OnPremisesSamAccountName
}
else {
    $Identity = $User.UserPrincipalName.Split("@")[0]
}

# Look for an existing folder ending with "(login)" - the AD script may have already created it
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

$BackupPath = Join-Path $MainUserFolder "M365"

New-Item `
    -ItemType Directory `
    -Path $BackupPath `
    -Force | Out-Null
 
# ==========================================
# FILES
# ==========================================
 
$TimeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
 
$LogFile = Join-Path `
$BackupPath `
"Offboarding_$TimeStamp.log"
 
$GroupsBackupFile = Join-Path `
$BackupPath `
"GroupsBackup.csv"
 
$LicensesBackupFile = Join-Path `
$BackupPath `
"LicensesBackup.csv"
 
$MFABackupFile = Join-Path `
$BackupPath `
"MFAMethodsBackup.csv"
 
$SummaryFile = Join-Path `
$BackupPath `
"Summary.txt"
 
# ==========================================
# LOGGING
# ==========================================
 
function Write-Log {
 
param(
[string]$Message
)
 
$Line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
 
Add-Content `
-Path $LogFile `
-Value $Line
 
Write-Host $Message
}
 
Write-Log "===== START OFFBOARDING ====="
Write-Log "User: $($User.UserPrincipalName)"
Write-Log "Display Name: $($User.DisplayName)"
Write-Log "Object ID: $($User.Id)"
 
# ==========================================
# 1. GROUPS BACKUP
# ==========================================
 
try {
 
$Groups = Get-MgUserMemberOf `
-UserId $UPN `
-All
 
$GroupBackup = foreach ($Group in $Groups) {
 
try {
 
$G = Get-MgGroup `
-GroupId $Group.Id `
-ErrorAction Stop
 
[PSCustomObject]@{
DisplayName = $G.DisplayName
GroupId = $G.Id
OnPremisesSyncEnabled = $G.OnPremisesSyncEnabled
}
 
}
catch {}
}
 
$GroupBackup |
Export-Csv `
$GroupsBackupFile `
-NoTypeInformation `
-Encoding UTF8
 
Write-Log "[OK] Groups backup"
 
}
catch {
 
Write-Log "[ERROR] Groups backup"
Write-Log $_.Exception.Message
 
}
 
# ==========================================
# 2. LICENSES BACKUP
# ==========================================
 
try {
 
$Licenses = Get-MgUserLicenseDetail `
-UserId $UPN
 
$Licenses |
Select-Object SkuPartNumber, SkuId |
Export-Csv `
$LicensesBackupFile `
-NoTypeInformation `
-Encoding UTF8
 
Write-Log "[OK] Licenses backup"
 
}
catch {
 
Write-Log "[ERROR] Licenses backup"
Write-Log $_.Exception.Message
 
}
 
# ==========================================
# 3. BACKUP MFA
# ==========================================
 
try {
 
$Methods = Get-MgUserAuthenticationMethod `
-UserId $UPN
 
$Methods |
Select-Object Id,
@{Name="Type";Expression={$_.AdditionalProperties.'@odata.type'}} |
Export-Csv `
$MFABackupFile `
-NoTypeInformation `
-Encoding UTF8
 
Write-Log "[OK] Backup MFA"
 
}
catch {
 
Write-Log "[ERROR] Backup MFA"
Write-Log $_.Exception.Message
 
}
 
# ==========================================
# 4. DISABLE SIGN-IN
# ==========================================
 
try {
 
Update-MgUser `
-UserId $UPN `
-AccountEnabled:$false `
-ErrorAction Stop
 
Write-Log "[OK] Disable Sign-In"
 
}
catch {
 
Write-Log "[ERROR] Disable Sign-In"
Write-Log $_.Exception.Message
 
}
 
# ==========================================
# 5. REVOKE SESSIONS
# ==========================================
 
try {
 
Revoke-MgUserSignInSession `
-UserId $UPN `
-ErrorAction Stop
 
Write-Log "[OK] Revoke Sessions"
 
}
catch {
 
Write-Log "[ERROR] Revoke Sessions"
Write-Log $_.Exception.Message
 
}
 
# ==========================================
# 6. CONVERT TO SHARED MAILBOX
# ==========================================
 
try {
 
Set-Mailbox `
-Identity $UPN `
-Type Shared `
-ErrorAction Stop
 
Write-Log "[OK] Shared Mailbox"
 
}
catch {
 
Write-Log "[ERROR] Shared Mailbox"
Write-Log $_.Exception.Message
 
}
 
# ==========================================
# 7. REMOVE MFA METHODS
# ==========================================
 
try {
 
foreach ($Method in $Methods) {
 
try {
 
$Type = $Method.AdditionalProperties.'@odata.type'
 
switch ($Type) {
 
"#microsoft.graph.phoneAuthenticationMethod" {
 
Remove-MgUserAuthenticationPhoneMethod `
-UserId $UPN `
-PhoneAuthenticationMethodId $Method.Id `
-ErrorAction Stop
}
 
"#microsoft.graph.microsoftAuthenticatorAuthenticationMethod" {
 
Remove-MgUserAuthenticationMicrosoftAuthenticatorMethod `
-UserId $UPN `
-MicrosoftAuthenticatorAuthenticationMethodId $Method.Id `
-ErrorAction Stop
}
 
"#microsoft.graph.emailAuthenticationMethod" {
 
Remove-MgUserAuthenticationEmailMethod `
-UserId $UPN `
-EmailAuthenticationMethodId $Method.Id `
-ErrorAction Stop
}
 
"#microsoft.graph.softwareOathAuthenticationMethod" {
 
Remove-MgUserAuthenticationSoftwareOathMethod `
-UserId $UPN `
-SoftwareOathAuthenticationMethodId $Method.Id `
-ErrorAction Stop
}
}
 
Write-Log "[OK] MFA removed: $Type"
 
}
catch {
 
Write-Log "[ERROR] MFA removal"
Write-Log $_.Exception.Message
 
}
}
 
}
catch {
 
Write-Log "[ERROR] MFA methods"
Write-Log $_.Exception.Message
 
}
 
# ==========================================
# 8. REMOVE CLOUD GROUPS
# ==========================================
 
try {
 
foreach ($Group in $Groups) {
 
try {
 
$G = Get-MgGroup `
-GroupId $Group.Id `
-ErrorAction Stop
 
if ($G.OnPremisesSyncEnabled -eq $true) {
 
Write-Log "[SKIP AD SYNC] $($G.DisplayName)"
continue
 
}
 
Remove-MgGroupMemberDirectoryObjectByRef `
-GroupId $G.Id `
-DirectoryObjectId $User.Id `
-ErrorAction Stop
 
Write-Log "[OK] Removed group: $($G.DisplayName)"

}
catch {

Write-Log "[ERROR] Group removal: $($Group.Id)"
Write-Log $_.Exception.Message

}
}

}
catch {

Write-Log "[ERROR] Remove groups"
Write-Log $_.Exception.Message

}

Write-Log "===== END OFFBOARDING ====="

# ==========================================
# SUMMARY
# ==========================================

@"
Display Name : $($User.DisplayName)
UPN          : $($User.UserPrincipalName)
Object ID    : $($User.Id)

Offboarding Date : $(Get-Date)

Generated Files:
- $(Split-Path $GroupsBackupFile -Leaf)
- $(Split-Path $LicensesBackupFile -Leaf)
- $(Split-Path $MFABackupFile -Leaf)
- $(Split-Path $LogFile -Leaf)

Actions:
- Backup Groups
- Backup Licenses
- Backup MFA
- Disable Sign-In
- Revoke Sessions
- Convert to Shared Mailbox
- Remove MFA Methods
- Remove Cloud Groups
- Remove Licenses
"@ | Out-File `
    -FilePath $SummaryFile `
    -Encoding UTF8

# ==========================================
# COMPLETION
# ==========================================

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "M365 OFFBOARDING COMPLETED" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Cyan

Write-Host ""
Write-Host "User folder:" -ForegroundColor Cyan
Write-Host $MainUserFolder -ForegroundColor Yellow

Write-Host ""
Write-Host "M365 folder:" -ForegroundColor Cyan
Write-Host $BackupPath -ForegroundColor Yellow

Write-Host ""
Write-Host "Groups backup:" -ForegroundColor Cyan
Write-Host $GroupsBackupFile -ForegroundColor Yellow

Write-Host ""
Write-Host "Licenses backup:" -ForegroundColor Cyan
Write-Host $LicensesBackupFile -ForegroundColor Yellow

Write-Host ""
Write-Host "Backup MFA:" -ForegroundColor Cyan
Write-Host $MFABackupFile -ForegroundColor Yellow

Write-Host ""
Write-Host "Log:" -ForegroundColor Cyan
Write-Host $LogFile -ForegroundColor Yellow

Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host $SummaryFile -ForegroundColor Yellow