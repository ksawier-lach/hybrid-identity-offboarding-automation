# User Offboarding – AD and Microsoft 365

Two PowerShell scripts for offboarding an employee:

| Script | Scope |
|---|---|
| `Offboard-ADUser.ps1` | On-premises Active Directory |
| `Offboard-M365User.ps1` | Microsoft 365 (Entra ID, Exchange Online) |

Before making any changes, each script backs up the data it is about to modify and records every action in a log. Both scripts save their output to a single shared user folder.

---

## Requirements

**Offboard-ADUser.ps1**
- `ActiveDirectory` module (RSAT)
- Permissions to modify accounts and groups in AD

**Offboard-M365User.ps1**
- `Microsoft.Graph` modules (Users, Groups, Identity.SignIns) and `ExchangeOnlineManagement`
- Consent for the Graph scopes: `User.ReadWrite.All`, `Directory.ReadWrite.All`, `Group.ReadWrite.All`, `UserAuthenticationMethod.ReadWrite.All`
- Exchange administrator role to convert the mailbox

Installing the modules:

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
Install-Module ExchangeOnlineManagement -Scope CurrentUser
```

---

## Running the scripts

```powershell
.\Offboard-ADUser.ps1      # enter the login (sAMAccountName)
.\Offboard-M365User.ps1    # enter the UPN, e.g. john.smith@company.com
```

The order in which the scripts are run does not matter. The recommended order is AD first, then M365, because changes made in AD (e.g. disabling the account) reach the cloud at the next synchronization.

---

## Folder structure

```
C:\Temp\Offboarding\
└── Smith, John (jsmith)\
    ├── AD\
    └── M365\
```

The folder name has the format `DisplayName (login)`. The scripts identify the user by login rather than by display name, because the name in AD and in Entra ID may differ.

- The AD script uses `sAMAccountName`.
- The M365 script uses `OnPremisesSamAccountName` (for accounts synchronized from AD, this is the same login). For cloud-only accounts, it uses the part of the UPN before `@`.

Each script first looks in `C:\Temp\Offboarding` for a folder whose name ends with `(login)`. If it finds one, it adds its own subfolder to it. If not, it creates a new user folder.

---

## Offboard-ADUser.ps1 – step by step

1. **Get the user** – asks for the login and retrieves the account from AD. If the account does not exist, the script exits.
2. **Prepare the folder** – finds or creates the user folder and the `AD` subfolder.
3. **Back up account data** – saves to CSV the first name, last name, UPN, email, department, job title, manager, Employee ID, DN and more.
4. **Back up groups** – saves the list of groups the user belongs to.
5. **Disable the account** – `Disable-ADAccount`.
6. **Remove the manager** – clears the `manager` attribute on the user's account.
7. **Detach direct reports** – clears the `manager` field for everyone who had this user as their manager.
8. **Clear contact details** – phone numbers, address, office, department, job title, notes.
9. **Hide from the GAL** – sets `msExchHideFromAddressLists = $true`.
10. **Remove from groups** – removes the user from all groups except `Domain Users` (the primary group, which cannot be removed).
11. **Summary** – saves `Summary.txt` and displays the paths to the generated files.

### Files in the `AD` folder

| File | Contents |
|---|---|
| `UserData_<date>.csv` | Account data before the changes |
| `Groups_<date>.csv` | Group list before the changes |
| `Offboarding_<date>.log` | Log of all actions |
| `Summary.txt` | Summary |

---

## Offboard-M365User.ps1 – step by step

1. **Connect** – signs in to Microsoft Graph and Exchange Online.
2. **Get the user** – asks for the UPN and retrieves the account from Entra ID. If the account does not exist, the script exits.
3. **Prepare the folder** – finds or creates the user folder and the `M365` subfolder.
4. **Back up groups** – saves the name and ID of each group, along with whether the group is synchronized from AD.
5. **Back up licenses** – saves the assigned licenses (`SkuPartNumber`, `SkuId`).
6. **Back up MFA** – saves the registered authentication methods.
7. **Block sign-in** – sets `AccountEnabled = $false`.
8. **Revoke sessions** – signs the user out of all devices and applications.
9. **Convert the mailbox to shared** – mail is preserved and access can be granted to another person. A shared mailbox up to 50 GB does not require a license.
10. **Remove MFA methods** – phone, Microsoft Authenticator, email, OATH apps.
11. **Remove from cloud groups** – groups synchronized from AD are skipped, because the AD script handles them.
12. **Summary** – saves `Summary.txt` and displays the paths to the generated files.

### Files in the `M365` folder

| File | Contents |
|---|---|
| `GroupsBackup.csv` | Group list before the changes |
| `LicensesBackup.csv` | License list before the changes |
| `MFAMethodsBackup.csv` | MFA methods before the changes |
| `Offboarding_<date>.log` | Log of all actions |
| `Summary.txt` | Summary |

---

## Restoring groups

If the offboarding needs to be reversed, AD and M365 groups can be restored from the backup using `..\UserTools\Restore-groups.ps1`. The script finds the backups in `C:\Temp\Offboarding` on its own and lets you choose whether to restore cloud groups as well. See `..\UserTools\README.md` for details.

Restoring groups does not reverse the other steps. The account must be re-enabled manually, and the mailbox must be converted back to a regular one (`Set-Mailbox -Type Regular`) and assigned a license.

---

## Error handling

Each step is in its own `try/catch` block. An error in one step, e.g. when removing a single group, does not stop the script. It is written to the log with the `[ERROR]` marker, and the script moves on to the next step. After the script finishes, review the log and manually perform any steps that failed.

Log markers:

| Marker | Meaning |
|---|---|
| `[OK]` | Step completed |
| `[ERROR]` | Step failed, details on the next line |
| `[SKIP AD SYNC]` | Group skipped because it is synchronized from AD |

---

## Known limitations

- **Distribution lists and mail-enabled security groups** cannot be modified through Graph. They must be handled in Exchange Online, e.g. with `Remove-DistributionGroupMember`.
- **Dynamic groups** do not allow members to be removed manually. The user will drop out of them automatically once their attributes change.
- **Licenses** are only saved in the backup. The M365 script does not remove them, even though `Summary.txt` lists "Remove Licenses".
- For accounts synchronized from AD, some attributes (e.g. account status) are overwritten by synchronization, so changes to those attributes must be made in AD.
