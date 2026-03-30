# Security Policy

## ⚠️ Important Notice

The Powerful Intune Bulk Actions Tool is a **privileged administrative tool**. It communicates directly with Microsoft Graph and is capable of performing destructive, irreversible operations on managed devices, including:

- Retiring and wiping enrolled devices
- Deleting Intune, Autopilot, and Entra ID device records permanently
- Bulk-modifying Entra ID group memberships
- Updating Autopilot Group Tags across fleets

Vulnerabilities in this tool could allow malicious actors to **compromise an organisation's entire device fleet**. Security issues are taken seriously and will be addressed with high priority.

---

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.x (latest) | ✅ Yes |
| < 1.0 | ❌ No |

Only the latest release on the `main` branch receives security fixes.

---

## Reporting a Vulnerability

**Please do NOT report security vulnerabilities through public GitHub Issues.**

If you discover a security vulnerability, please disclose it responsibly by:

1. **Opening a GitHub Security Advisory** via the [Security tab](../../security/advisories/new) of this repository *(preferred — kept private until patched)*.
2. Alternatively, contact the maintainer directly via the contact information on their GitHub profile.

### What to Include

To help resolve the issue as quickly as possible, please provide:

- A clear description of the vulnerability and its potential impact
- Step-by-step reproduction instructions
- The affected version / branch
- Any proof-of-concept code or screenshots (if applicable)
- Your suggested fix or mitigation, if you have one

### What to Expect

- **Acknowledgement** within 5 business days
- **Status update** (confirmed / not confirmed) within 10 business days
- **Patch and public disclosure** coordinated with the reporter once a fix is available
- Full credit given in the release notes unless you prefer to remain anonymous

---

## Scope

The following are considered **in scope** for security reports:

| Area | Example Issues |
|------|---------------|
| **Input validation** | Malformed device ID files leading to unintended Graph API calls |
| **Authentication handling** | Token exposure, insecure credential storage  |
| **Privilege escalation** | Bypassing the admin-scope check during module install |
| **Dependency vulnerabilities** | Known CVEs in the Microsoft Graph PowerShell SDK |
| **Injection** | Script injection via crafted input files or device identifiers |
| **Destructive operation safeguards** | Confirmation prompts that can be trivially bypassed |

The following are **out of scope**:

- Vulnerabilities in Microsoft Graph itself (report these to [MSRC](https://msrc.microsoft.com/))
- Vulnerabilities in the Microsoft Graph PowerShell SDK (report to the [SDK repo](https://github.com/microsoftgraph/msgraph-sdk-powershell))
- Issues requiring physical access to an already-compromised machine

---

## Security Best Practices for Users

When running The Powerful Intune Bulk Actions Tool in your environment:

- **Use the principle of least privilege** — connect with a Graph account that has only the scopes required for your specific tasks. The required scopes are listed in `graphFunctions.psm1`.
- **Do not share your log files** — the application log (stored in `C:\Temp\YYYYMMDD\`) may contain device names, serial numbers, and Entra IDs.
- **Never run bulk action files from untrusted sources** — `.txt` device ID files are parsed directly into Graph API calls.
- **Run in a monitored context** — all destructive operations generate an audit log entry. Ensure these logs are retained.
- **Keep the Microsoft Graph SDK up to date** — run `Update-Module Microsoft.Graph` periodically.
