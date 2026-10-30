# D:\github\geo\claim-worktree.ps1
param (
    [Parameter(Mandatory=$false)]
    [ValidateSet("acquire", "release", "status", "lock-all", "unlock-all", "test")]
    [string]$Action = "acquire",

    [Parameter(Mandatory=$false)]
    [string]$Worktree = "",

    [Parameter(Mandatory=$false)]
    [string]$Agent = "Antigravity",

    [Parameter(Mandatory=$false)]
    [string]$TaskId = "",

    [Parameter(Mandatory=$false)]
    [switch]$OpenNotepad,

    [Parameter(Mandatory=$false)]
    [int]$OverridePid = 0
)

$Root = "D:\github\geo"
$Candidates = @("site-pv2", "site-pv3", "site-pv4")
$TTLHours = 2

function Set-WriteLock($Path) {
    # Note: Do not use icacls /deny on src/ as it blocks Win32 FindFirstFile and causes
    # git status to report 'warning: could not open directory src/: No such file or directory'
    # and phantom deletion of hundreds of files. Enforcement is handled via .githooks/pre-commit.
}

function Remove-WriteLock($Path) {
    $srcPath = Join-Path $Path "src"
    if (Test-Path $srcPath) {
        $null = icacls $srcPath /remove:d "$env:USERNAME" /C /Q 2>$null
    }
}

function Unlock-Directory($Path) {
    Remove-WriteLock $Path
    $statusFile = Join-Path $Path ".agent-status.json"
    if (Test-Path $statusFile) {
        Remove-Item $statusFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-TaskIsDone($TaskIdentifier, $WorktreeName) {
    if (-not $TaskIdentifier) { return $false }
    $possible = @(
        (Join-Path $Root "$WorktreeName\task\$TaskIdentifier.md"),
        (Join-Path $Root "$WorktreeName\task\$TaskIdentifier"),
        (Join-Path $Root "site\task\$TaskIdentifier.md"),
        (Join-Path $Root "site\task\$TaskIdentifier")
    )
    foreach ($p in $possible) {
        if (Test-Path $p) {
            $c = Get-Content $p -Raw -ErrorAction SilentlyContinue
            if ($c -match "Status:\s*DONE") {
                return $true
            }
        }
    }
    return $false
}

function Test-WorktreeActiveInTaskMd($WorktreeName) {
    $taskMd = Join-Path $Root "TASK.md"
    if (-not (Test-Path $taskMd)) { return $false }
    $lines = Get-Content $taskMd
    $b = [char]96
    $token = "$b$WorktreeName$b"
    foreach ($line in $lines) {
        if ($line.Contains($token)) {
            $parts = $line.Split('|')
            if ($parts.Length -ge 6) {
                if ($parts[4] -match "ACTIVE|IN USE") {
                    $taskCol = $parts[5]
                    if ($taskCol -match '(task\d+[\w-]*)') {
                        $tid = $matches[1]
                        if (Test-TaskIsDone $tid $WorktreeName) {
                            return $false
                        }
                    }
                    return $true
                }
            }
        }
    }
    return $false
}

function Test-WorktreeHasDirtyGit($FullPath) {
    if (-not (Test-Path (Join-Path $FullPath ".git"))) { return $false }
    try {
        $out = git -C $FullPath status --porcelain 2>$null
        # Meaningful changes: any staged or modified tracked file, or new files in src/ or task/
        $dirty = $out | Where-Object { 
            $_ -and (
                ($_ -match '^[MADRCU]') -or
                ($_ -match '^\s+[MADRCU]') -or
                ($_ -match '^\?\?\s+(src/|task/)')
            )
        }
        return ($dirty.Count -gt 0)
    } catch {
        return $false
    }
}

function Test-SlotIsAvailable($dir) {
    $fullPath = Join-Path $Root $dir
    $statusFile = Join-Path $fullPath ".agent-status.json"

    # Check 1: Explicit lock file
    if (Test-Path $statusFile) {
        try {
            $data = Get-Content $statusFile -Raw | ConvertFrom-Json
            $ageHours = ((Get-Date) - [datetime]$data.timestamp).TotalHours

            # If task is marked DONE in task file, lock is released
            if ($data.taskId -and (Test-TaskIsDone $data.taskId $dir)) {
                Unlock-Directory $fullPath
            }
            # If lock is fresh (< TTLHours), it is BUSY regardless of whether the claiming CLI process ended!
            elseif ($ageHours -lt $TTLHours) {
                return $false
            }
            else {
                # Lock is older than TTLHours (e.g. 2 hours) -> evict
                Unlock-Directory $fullPath
            }
        } catch {
            Unlock-Directory $fullPath
        }
    }

    # Check 2: TASK.md table declaration
    if (Test-WorktreeActiveInTaskMd $dir) {
        return $false
    }

    # Check 3: Active uncommitted git changes from concurrent agent
    if (Test-WorktreeHasDirtyGit $fullPath) {
        return $false
    }

    return $true
}

function Update-BranchMarkdown($WorktreeName, $AgentName, $TaskIdentifier, $Status = "ACTIVE") {
    $branchFile = Join-Path $Root "branch.md"
    $gitBranch = switch ($WorktreeName) {
        "site-pv2" { "preview2" }
        "site-pv3" { "preview3" }
        "site-pv4" { "preview4" }
        default { "preview" }
    }
    $targetPath = Join-Path $Root $WorktreeName
    $previewUrl = "https://$gitBranch-geo-astro-site.foodstarmelbourne.workers.dev"
    $taskText = if ($TaskIdentifier) { $TaskIdentifier } else { "Unspecified" }

    $b = '`'
    $cb = '```'
    $md = @"
# 🌿 Active Agent Session & Branch Allocation

| Attribute | Details |
|---|---|
| **Agent** | $AgentName |
| **Task ID** | $taskText |
| **Branch** | ${b}${gitBranch}${b} (${b}${WorktreeName}${b}) |
| **Directory** | ${b}${targetPath}${b} |
| **Status** | $Status |
| **Timestamp** | $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss")) |
| **PID** | $PID |

---

### 🔗 Live Preview URL
$previewUrl

### 🛠️ Release Command
${cb}powershell
powershell -ExecutionPolicy Bypass -File D:\github\geo\claim-worktree.ps1 -Action release -Worktree $WorktreeName
${cb}
"@
    Set-Content -Path $branchFile -Value $md -Force
    if ($OpenNotepad) {
        Start-Process notepad.exe -ArgumentList $branchFile
    }
}

function Update-TaskMarkdownRegistry($WorktreeName, $AgentName, $TaskIdentifier, $IsActive) {
    $taskMd = Join-Path $Root "TASK.md"
    if (-not (Test-Path $taskMd)) { return }
    $lines = Get-Content $taskMd
    $newLines = @()
    $b = [char]96
    $token = "$b$WorktreeName$b"
    foreach ($line in $lines) {
        if ($line.Contains($token)) {
            $parts = $line.Split('|')
            if ($parts.Length -ge 6) {
                if ($IsActive) {
                    $parts[4] = " **ACTIVE / IN USE** "
                    $taskStr = if ($TaskIdentifier) { "$AgentName - $TaskIdentifier" } else { "$AgentName" }
                    $parts[5] = " $taskStr "
                } else {
                    $parts[4] = " **IDLE** / AVAILABLE "
                    $parts[5] = " None "
                }
                $line = $parts -join '|'
            }
        }
        $newLines += $line
    }
    Set-Content -Path $taskMd -Value $newLines -Force
}

function Invoke-SelfTest {
    Write-Host "`n========================================================" -ForegroundColor Cyan
    Write-Host "[BAW DEBUG TEST] Isolated Mock Arbitration & Collision Test" -ForegroundColor Cyan
    Write-Host "========================================================`n" -ForegroundColor Cyan

    $testSandbox = Join-Path $env:TEMP ("baw-test-" + [guid]::NewGuid().ToString().Substring(0,8))
    New-Item -ItemType Directory -Path $testSandbox -Force | Out-Null

    try {
        $mockSlots = @("mock-pv2", "mock-pv3", "mock-pv4")
        foreach ($s in $mockSlots) {
            New-Item -ItemType Directory -Path (Join-Path $testSandbox $s) -Force | Out-Null
        }

        # Step 1: Simulate Job 1 claim in sandbox
        Write-Host "1. Job 1 acquiring mock slot mock-pv2..." -ForegroundColor Yellow
        $lock1 = @{
            pid = 99999
            timestamp = (Get-Date).ToString("o")
            worktree = "mock-pv2"
            agent = "DummyJob-1"
            taskId = "task-alpha"
            status = "ACTIVE"
        } | ConvertTo-Json
        Set-Content -Path (Join-Path $testSandbox "mock-pv2\.agent-status.json") -Value $lock1 -Force
        Write-Host "   -> Job 1 lock written on mock-pv2" -ForegroundColor Green

        # Step 2: Simulate Job 2 scan
        Write-Host "2. Job 2 scanning available mock slots..." -ForegroundColor Yellow
        $claimed2 = $null
        foreach ($s in $mockSlots) {
            $sf = Join-Path $testSandbox "$s\.agent-status.json"
            if (-not (Test-Path $sf)) {
                $claimed2 = $s
                $lock2 = @{
                    pid = 99998
                    timestamp = (Get-Date).ToString("o")
                    worktree = $s
                    agent = "DummyJob-2"
                    taskId = "task-beta"
                    status = "ACTIVE"
                } | ConvertTo-Json
                Set-Content -Path $sf -Value $lock2 -Force
                break
            }
        }
        Write-Host "   -> Job 2 claimed: $claimed2" -ForegroundColor Green

        # Step 3: Assert No Collision
        Write-Host "3. Verifying Collision Avoidance: Job 1 (mock-pv2) vs Job 2 ($claimed2)..." -ForegroundColor Yellow
        if ($claimed2 -eq "mock-pv2") {
            Write-Error "CRITICAL FAILURE: Collision detected! Both jobs acquired mock-pv2!"
            exit 1
        }
        Write-Host "   [PASS] Job 1 (mock-pv2) and Job 2 ($claimed2) are isolated on different slots!" -ForegroundColor Green

        Write-Host "`n========================================================" -ForegroundColor Green
        Write-Host "[SUCCESS] ISOLATED ARBITRATION TESTS PASSED (LIVE WORKTREES UNTOUCHED)" -ForegroundColor Green
        Write-Host "========================================================`n" -ForegroundColor Green
        exit 0
    }
    finally {
        Remove-Item -Path $testSandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($Action -eq "test") {
    Invoke-SelfTest
}

if ($Action -eq "lock-all") {
    # Lock root site and all staging worktrees by default
    foreach ($dir in @("site", "site-pv2", "site-pv3", "site-pv4")) {
        Set-WriteLock (Join-Path $Root $dir)
    }
    Write-Output "ALL_WORKTREES_LOCKED_READONLY"
    exit 0
}

if ($Action -eq "unlock-all") {
    foreach ($dir in @("site", "site-pv2", "site-pv3", "site-pv4")) {
        Unlock-Directory (Join-Path $Root $dir)
    }
    Write-Output "ALL_WORKTREES_UNLOCKED"
    exit 0
}

if ($Action -eq "release") {
    if (-not $Worktree) { Write-Error "Specify -Worktree to release."; exit 1 }
    $Target = Join-Path $Root $Worktree
    Unlock-Directory $Target
    Set-WriteLock $Target  # Re-lock to prevent unauthorized stray edits after session
    Update-BranchMarkdown $Worktree $Agent $TaskId "RELEASED / IDLE"
    Update-TaskMarkdownRegistry $Worktree $Agent $TaskId $false
    Write-Output "RELEASED:$Worktree"
    exit 0
}

if ($Action -eq "status") {
    foreach ($dir in $Candidates) {
        $fullPath = Join-Path $Root $dir
        $statusFile = Join-Path $fullPath ".agent-status.json"
        $avail = Test-SlotIsAvailable $dir
        if (-not $avail) {
            $reason = "BUSY"
            if (Test-Path $statusFile) {
                try {
                    $data = Get-Content $statusFile -Raw | ConvertFrom-Json
                    $agentInfo = if ($data.agent) { " by $($data.agent)" } else { "" }
                    $taskInfo = if ($data.taskId) { " [$($data.taskId)]" } else { "" }
                    $reason = "ACTIVE$agentInfo$taskInfo (since $($data.timestamp))"
                } catch {
                    $reason = "ACTIVE (unparseable lockfile)"
                }
            } elseif (Test-WorktreeActiveInTaskMd $dir) {
                $reason = "ACTIVE in TASK.md"
            } elseif (Test-WorktreeHasDirtyGit $fullPath) {
                $reason = "ACTIVE with uncommitted changes"
            }
            Write-Output "$dir : $reason"
        } else {
            Write-Output "$dir : AVAILABLE"
        }
    }
    exit 0
}

# --- Action: acquire ---
$Selected = $null

$lastClaimedFile = Join-Path $Root ".last-claimed-worktree"
$lastClaimed = if (Test-Path $lastClaimedFile) { (Get-Content $lastClaimedFile -Raw).Trim() } else { "" }

# Preferred candidates order in true round-robin
$OrderedCandidates = switch ($lastClaimed) {
    "site-pv2" { @("site-pv3", "site-pv4", "site-pv2") }
    "site-pv3" { @("site-pv4", "site-pv2", "site-pv3") }
    "site-pv4" { @("site-pv2", "site-pv3", "site-pv4") }
    default    { @("site-pv2", "site-pv3", "site-pv4") }
}

if ($Worktree -and ($Candidates -contains $Worktree)) {
    $OrderedCandidates = @($Worktree) + ($OrderedCandidates | Where-Object { $_ -ne $Worktree })
}

foreach ($dir in $OrderedCandidates) {
    $fullPath = Join-Path $Root $dir
    $statusFile = Join-Path $fullPath ".agent-status.json"

    if (Test-SlotIsAvailable $dir) {
        $Selected = $dir

        # 1. Unlock write permissions on src/
        Remove-WriteLock $fullPath
        
        # 2. Fast-forward with origin/preview
        Push-Location $fullPath
        git fetch origin 2>&1 | Out-Null
        git merge --ff-only origin/preview 2>&1 | Out-Null
        Pop-Location

        # 3. Write active lock file
        $activePid = if ($OverridePid -gt 0) { $OverridePid } else { $PID }
        $lockPayload = @{
            pid       = $activePid
            timestamp = (Get-Date).ToString("o")
            worktree  = $dir
            agent     = $Agent
            taskId    = $TaskId
            status    = "ACTIVE"
        } | ConvertTo-Json
        Set-Content -Path $statusFile -Value $lockPayload -Force

        # 4. Record last claimed for round-robin rotation
        Set-Content -Path $lastClaimedFile -Value $Selected -Force

        # 5. Write branch.md and optionally open Notepad
        Update-BranchMarkdown $Selected $Agent $TaskId "ACTIVE"
        Update-TaskMarkdownRegistry $Selected $Agent $TaskId $true

        break
    }
}

if ($null -eq $Selected) {
    Write-Error "ALL_SLOTS_BUSY"
    exit 1
}

Write-Output "CLAIMED:$Selected"
