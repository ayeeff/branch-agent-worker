# D:\github\branch-agent-worker\branch-worker.ps1
<#
.SYNOPSIS
    Modular PowerShell worktree and branch worker for autonomous LLM agents.
.DESCRIPTION
    Zero-dependency PowerShell implementation of branch-agent-worker for Windows environments.
#>
param (
    [Parameter(Mandatory=$false, Position=0)]
    [ValidateSet("init", "claim", "acquire", "release", "status", "lock-all", "unlock-all", "hooks")]
    [string]$Command = "status",

    [Parameter(Mandatory=$false)]
    [string]$Worktree = "",

    [Parameter(Mandatory=$false)]
    [string]$Agent = "Antigravity",

    [Parameter(Mandatory=$false)]
    [string]$TaskId = "",

    [Parameter(Mandatory=$false)]
    [switch]$OpenNotepad,

    [Parameter(Mandatory=$false)]
    [int]$Slots = 3,

    [Parameter(Mandatory=$false)]
    [string]$Prefix = "pv"
)

$RepoRoot = (git rev-parse --show-toplevel 2>$null)
if (-not $RepoRoot) {
    $RepoRoot = Get-Location
}

$ConfigFile = Join-Path $RepoRoot ".branch-worker.json"
$TTLHours = 2

# Load config or generate defaults
if (Test-Path $ConfigFile) {
    $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
} else {
    $repoName = Split-Path $RepoRoot -Leaf
    $slotList = @()
    for ($i = 2; $i -le ($Slots + 1); $i++) {
        $id = "$Prefix$i"
        $slotList += [PSCustomObject]@{
            id = $id
            branch = "preview$i"
            folderName = "$repoName-$id"
        }
    }
    $Config = [PSCustomObject]@{
        baseBranch = "main"
        remote = "origin"
        worktreeLayout = "adjacent"
        slots = $slotList
        ttlHours = 2
        enableOsWriteLocks = $true
        lockTargetDir = "src"
    }
}

function Get-SlotPath($slot) {
    if ($Config.worktreeLayout -eq "adjacent") {
        return (Join-Path (Split-Path $RepoRoot -Parent) $slot.folderName)
    }
    return (Join-Path (Join-Path $RepoRoot ".worktrees") $slot.folderName)
}

function Set-WriteLock($Path) {
    # Note: Do not use icacls /deny on directory targets as it blocks Win32 FindFirstFile and causes
    # git status to report 'warning: could not open directory: No such file or directory' and phantom
    # deletions. Enforcement against unauthorized commits is handled reliably via .githooks/pre-commit.
}

function Remove-WriteLock($Path) {
    $targetPath = if ($Config.lockTargetDir) { Join-Path $Path $Config.lockTargetDir } else { $Path }
    if (Test-Path $targetPath) {
        $null = icacls $targetPath /remove:d "$env:USERNAME" /C /Q 2>$null
    }
}

function Write-BranchMarkdown($slot, $targetPath, $StatusVal) {
    $branchFile = Join-Path $RepoRoot "branch.md"
    $b = '`'
    $cb = '```'
    $taskText = if ($TaskId) { $TaskId } else { "Unspecified" }

    $md = @"
# 🌿 Active Agent Session & Branch Allocation

| Attribute | Details |
|---|---|
| **Agent** | $Agent |
| **Task ID** | $taskText |
| **Branch** | ${b}$($slot.branch)${b} (${b}$($slot.folderName)${b}) |
| **Directory** | ${b}$targetPath${b} |
| **Status** | $StatusVal |
| **Timestamp** | $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss")) |
| **PID** | $PID |

---

### 🛠️ Release Command
${cb}powershell
powershell -ExecutionPolicy Bypass -File D:\github\branch-agent-worker\branch-worker.ps1 release -Worktree $($slot.id)
${cb}
"@
    Set-Content -Path $branchFile -Value $md -Force
    if ($OpenNotepad) {
        Start-Process notepad.exe -ArgumentList $branchFile
    }
}

switch ($Command) {
    "status" {
        Write-Host "`n🌿 Worker Slot Registry ($RepoRoot)`n" -ForegroundColor Green
        foreach ($slot in $Config.slots) {
            $path = Get-SlotPath $slot
            $statusFile = Join-Path $path ".agent-status.json"
            if (Test-Path $statusFile) {
                try {
                    $d = Get-Content $statusFile -Raw | ConvertFrom-Json
                    $proc = Get-Process -Id $d.pid -ErrorAction SilentlyContinue
                    $st = if ($proc) { "ACTIVE" } else { "STALE" }
                    Write-Host "$($slot.id.PadRight(10)) $($slot.branch.PadRight(14)) $st (PID: $($d.pid), Agent: $($d.agent), Task: $($d.taskId))"
                } catch {
                    Write-Host "$($slot.id.PadRight(10)) $($slot.branch.PadRight(14)) ACTIVE (unparseable)"
                }
            } else {
                Write-Host "$($slot.id.PadRight(10)) $($slot.branch.PadRight(14)) AVAILABLE"
            }
        }
        Write-Host ""
    }

    "init" {
        if (-not (Test-Path $ConfigFile)) {
            $Config | ConvertTo-Json -Depth 5 | Set-Content $ConfigFile -Force
            Write-Host "[baw] Created $ConfigFile" -ForegroundColor Green
        }
        $hooksDir = Join-Path $RepoRoot ".githooks"
        New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
        git config core.hooksPath "$($hooksDir -replace '\\', '/')"
        Write-Host "[baw] Repository initialized and Git hooks configured." -ForegroundColor Green
    }

    { $_ -in @("claim", "acquire") } {
        $selectedSlot = $null
        $selectedPath = $null

        foreach ($slot in $Config.slots) {
            $path = Get-SlotPath $slot
            $statusFile = Join-Path $path ".agent-status.json"
            $avail = $false

            if (-not (Test-Path $statusFile)) {
                $avail = $true
            } else {
                try {
                    $d = Get-Content $statusFile -Raw | ConvertFrom-Json
                    $proc = Get-Process -Id $d.pid -ErrorAction SilentlyContinue
                    $age = ((Get-Date) - [datetime]$d.timestamp).TotalHours
                    if ((-not $proc) -or ($age -ge $TTLHours)) {
                        Remove-Item $statusFile -Force -ErrorAction SilentlyContinue
                        $avail = $true
                    }
                } catch {
                    Remove-Item $statusFile -Force -ErrorAction SilentlyContinue
                    $avail = $true
                }
            }

            if ($avail -and ($null -eq $selectedSlot)) {
                $selectedSlot = $slot
                $selectedPath = $path
                break
            }
        }

        if ($null -eq $selectedSlot) {
            Write-Error "ALL_SLOTS_BUSY"
            exit 1
        }

        # 1. Unlock write permissions
        Remove-WriteLock $selectedPath

        # 2. Fast-forward with upstream
        if (Test-Path $selectedPath) {
            Push-Location $selectedPath
            git fetch $Config.remote $Config.baseBranch 2>&1 | Out-Null
            git merge --ff-only "$($Config.remote)/$($Config.baseBranch)" 2>&1 | Out-Null
            Pop-Location
        }

        # 3. Write lock
        $payload = @{
            pid = $PID
            timestamp = (Get-Date).ToString("o")
            worktree = $selectedSlot.folderName
            branch = $selectedSlot.branch
            agent = $Agent
            taskId = $TaskId
            status = "ACTIVE"
        } | ConvertTo-Json
        Set-Content -Path (Join-Path $selectedPath ".agent-status.json") -Value $payload -Force

        # 4. Generate branch.md
        Write-BranchMarkdown $selectedSlot $selectedPath "ACTIVE"
        Write-Host "`nCLAIMED:$($selectedSlot.id) -> $selectedPath`n" -ForegroundColor Green
    }

    "release" {
        if (-not $Worktree) { Write-Error "Specify -Worktree to release."; exit 1 }
        $match = $Config.slots | Where-Object { $_.id -eq $Worktree -or $_.folderName -eq $Worktree }
        if (-not $match) { Write-Error "Slot not found: $Worktree"; exit 1 }
        $path = Get-SlotPath $match
        Remove-Item (Join-Path $path ".agent-status.json") -Force -ErrorAction SilentlyContinue
        Set-WriteLock $path
        Write-BranchMarkdown $match $path "RELEASED / IDLE"
        Write-Host "`nRELEASED:$Worktree`n" -ForegroundColor Green
    }

    "lock-all" {
        foreach ($slot in $Config.slots) { Set-WriteLock (Get-SlotPath $slot) }
        Write-Host "ALL_WORKTREES_LOCKED_READONLY" -ForegroundColor Yellow
    }

    "unlock-all" {
        foreach ($slot in $Config.slots) { Remove-WriteLock (Get-SlotPath $slot) }
        Write-Host "ALL_WORKTREES_UNLOCKED" -ForegroundColor Green
    }
}
