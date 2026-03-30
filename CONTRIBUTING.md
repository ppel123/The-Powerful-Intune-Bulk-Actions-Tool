# Contributing to The Powerful Intune Bulk Actions Tool

Thank you for taking the time to contribute! The Powerful Intune Bulk Actions Tool exists to save Intune administrators hours of overhead, and every improvement — big or small — benefits the whole community.

Please take a moment to read this guide before submitting Issues or Pull Requests.

---

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Ways to Contribute](#ways-to-contribute)
- [Reporting Bugs](#reporting-bugs)
- [Requesting Features](#requesting-features)
- [Development Setup](#development-setup)
- [Branch Strategy](#branch-strategy)
- [Making Changes](#making-changes)
- [Pull Request Guidelines](#pull-request-guidelines)
- [Code Style](#code-style)
- [Security Issues](#security-issues)

---

## Code of Conduct

Be respectful and constructive. This is a community tool — everyone is welcome regardless of experience level.

---

## Ways to Contribute

- 🐛 **Report a bug** — open an Issue with reproduction steps
- 💡 **Request a feature** — open an Issue describing the use case
- 🔧 **Submit a fix or improvement** — fork → branch → PR
- 📖 **Improve documentation** — corrections and clarifications to `readme.md` or `code documentation.md`
- 🧪 **Test on your environment** — feedback on compatibility (PS version, OS, SDK version) is valuable

---

## Reporting Bugs

Before opening a new Issue, please search existing Issues to avoid duplicates.

When opening a bug report, include:

- **PowerShell version** — `$PSVersionTable.PSVersion`
- **Microsoft Graph SDK version** — `(Get-Module Microsoft.Graph -ListAvailable | Select -First 1).Version`
- **Operating system** — Windows version
- **How you ran the script** — did you use `-STA` mode? (`powershell.exe -STA -File ".\script.ps1"`)
- **Steps to reproduce** — what exactly did you click / input?
- **Error message** — the full text, or a screenshot of the Activity Log panel
- **Log file contents** (if available) — found in `C:\Temp\YYYYMMDD\` (where YYYYMMDD is today's date, e.g. `C:\Temp\20260315\`). Remove any sensitive data (device names, serial numbers, tenant IDs) before pasting.

---

## Requesting Features

Open an Issue with the label `enhancement`. Please describe:

- **The problem you're trying to solve** — what task are you doing today that the tool doesn't support?
- **The proposed solution** — what would the feature look like? (UI behaviour, input/output)
- **Alternatives considered** — is there a workaround currently?

---

## Development Setup

### Requirements

- Windows OS (WPF requires Windows)
- **PowerShell 5.1 or 7+** — run with `-STA` mode for WPF
- **Microsoft Graph PowerShell SDK** — the tool installs this automatically on first run, or manually:
  ```powershell
  Install-Module -Name Microsoft.Graph -Scope CurrentUser -Force
  ```
- A **test Microsoft Entra ID / Intune tenant** — use a dev/sandbox tenant, **never test destructive actions against a production environment**

### Running the Tool

```powershell
# Navigate to the project folder
cd "path\to\The-Powerful-Intune-Bulk-Actions-Tool\"

# Launch with STA mode (required for WPF)
powershell.exe -STA -File ".\script.ps1"
```

### Key Files

| File | Purpose |
|------|---------|
| `script.ps1` | Entry point — UI event handlers, async engine, WPF bootstrap |
| `graphFunctions.psm1` | All Microsoft Graph API calls, device resolution, bulk logic |
| `otherFunctions.psm1` | Logging, WPF UI helpers, CSV export |
| `MainWindow.xaml` | WPF window layout definition |
| `code documentation.md` | Full architecture reference, function signatures, data flow |

---

## Branch Strategy

| Branch | Purpose |
|--------|---------|
| `main` | Stable, release-ready code. Direct commits not accepted — PRs only. |
| `dev` | Active development. All PRs should target this branch. |
| `feature/your-feature-name` | Your feature branch, created from `dev`. |
| `fix/issue-number-description` | Bug fix branches, created from `dev`. |

**Always branch from `dev`, not `main`.**

---

## Making Changes

1. **Fork** the repository and clone your fork locally.

2. **Create a branch** from `dev`:
   ```powershell
   git checkout dev
   git pull origin dev
   git checkout -b feature/my-new-feature
   ```

3. **Make your changes.** See [Code Style](#code-style) below.

4. **Test thoroughly** — at minimum:
   - The tool launches correctly with `-STA` mode
   - Your changed function works for both single-device and bulk-device modes (if applicable)
   - No UI freezes — long-running operations must go through `Invoke-AsyncOperation`
   - The Activity Log panel shows relevant progress messages
   - Existing functionality you didn't touch still works

5. **Commit** with a clear message:
   ```
   feat: add BitLocker recovery key export to CSV
   fix: correct serial number resolution for devices with spaces
   docs: update function reference for Get-IntuneDeviceInfo
   ```

6. **Push** and open a Pull Request targeting `dev`.

---

## Pull Request Guidelines

- **One feature or fix per PR** — keep scope focused
- **Reference the related Issue** in your PR description (e.g. `Closes #42`)
- **Describe what you changed and why** — don't just repeat the commit message
- **Screenshots** are appreciated for any UI changes
- **Do not include test data** — no real device names, serial numbers, tenant IDs, or UUIDs in code or comments

PRs will be reviewed and may receive change requests. Please respond to feedback within a reasonable time.

---

## Code Style

The Powerful Intune Bulk Actions Tool follows these conventions — please match the existing style:

### PowerShell

- **PascalCase** for all function names: `Get-IntuneDeviceInfo`, `Write-AppLog`
- **PascalCase** for parameters: `-DeviceIdentifier`, `-IsSingleDevice`  
- `$script:` prefix for all module-level shared variables
- Functions must have a comment block (`.SYNOPSIS`, `.PARAMETER`, `.EXAMPLE`) following the existing pattern
- All error handling via `try/catch` — never silently swallow exceptions without at least a `Write-AppLog` call
- **No direct UI manipulation inside `graphFunctions.psm1` or `otherFunctions.psm1`** — these modules must remain UI-agnostic. All UI work stays in `script.ps1`.
- Long-running operations (any Graph API call) **must** run inside `Invoke-AsyncOperation` — never block the UI thread

### Logging

Use `Write-AppLog` for all application-level messages. Do **not** use bare `Write-Host` in new code within `script.ps1` — use `Write-AppLog` which handles both the Activity Log and console output.

In `graphFunctions.psm1`, `Write-Host` and `Write-Warning` are acceptable for progress/status messages — they are automatically captured and forwarded to the Activity Log via the async stream monitoring.

### XAML

- Control names use the `WPFX` prefix followed by PascalCase: `WPFBtnGenerateReport`, `WPFLvActivityLog`
- Keep layout logic in XAML; keep behaviour logic in `script.ps1`

---

## Security Issues

Please **do not open a public Issue** for security vulnerabilities. See [SECURITY.md](SECURITY.md) for the responsible disclosure process.
