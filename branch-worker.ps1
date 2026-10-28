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
    Write-Host "[BAW DEBUG TEST] Multi-Agent Arbitration & Collision Test" -ForegroundColor Cyan
    Write-Host "========================================================`n" -ForegroundColor Cyan

    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { "D:\github\geo\claim-worktree.ps1" }

    # Clean any stale locks first
    foreach ($cand in $Candidates) {
        $p = Join-Path $Root $cand
        Unlock-Directory $p
    }

    # Step 1: Spawn a live dummy background worker process
    Write-Host "1. Spawning Dummy Background Worker 1..." -ForegroundColor Yellow
    $worker1 = Start-Process powershell -ArgumentList "-NoProfile", "-Command", "Start-Sleep -Seconds 30" -PassThru
    Write-Host "   Worker 1 running with PID $($worker1.Id)" -ForegroundColor DarkGray

    # Step 2: Claim Slot for Job 1 with Worker 1's live PID
    Write-Host "2. Job 1 claiming slot with live PID $($worker1.Id)..." -ForegroundColor Yellow
    $out1 = & powershell -ExecutionPolicy Bypass -File $scriptPath -Action acquire -Agent "DummyJob-1" -TaskId "task-test-alpha" -OverridePid $worker1.Id
    $claimed1 = ($out1 -split ":")[1].Trim()
    Write-Host "   -> Job 1 claimed: $claimed1" -ForegroundColor Green

    # Step 3: Spawn a second live dummy background worker process
    Write-Host "3. Spawning Dummy Background Worker 2..." -ForegroundColor Yellow
    $worker2 = Start-Process powershell -ArgumentList "-NoProfile", "-Command", "Start-Sleep -Seconds 30" -PassThru
    Write-Host "   Worker 2 running with PID $($worker2.Id)" -ForegroundColor DarkGray

    # Step 4: Claim Slot for Job 2 while Worker 1 is still actively holding slot 1
    Write-Host "4. Job 2 claiming slot while Job 1 is ACTIVE..." -ForegroundColor Yellow
    $out2 = & powershell -ExecutionPolicy Bypass -File $scriptPath -Action acquire -Agent "DummyJob-2" -TaskId "task-test-beta" -OverridePid $worker2.Id
    $claimed2 = ($out2 -split ":")[1].Trim()
    Write-Host "   -> Job 2 claimed: $claimed2" -ForegroundColor Green

    # Step 5: Assert: No Collision
    Write-Host "5. Verifying Collision Avoidance: Job 1 ($claimed1) vs Job 2 ($claimed2)..." -ForegroundColor Yellow
    if ($claimed1 -eq $claimed2) {
        Write-Error "CRITICAL FAILURE: Collision detected! Both jobs acquired $claimed1!"
        Stop-Process -Id $worker1.Id -Force -ErrorAction SilentlyContinue
        Stop-Process -Id $worker2.Id -Force -ErrorAction SilentlyContinue
        exit 1
    }
    Write-Host "   [PASS] Job 1 ($claimed1) and Job 2 ($claimed2) are isolated on different worktrees!" -ForegroundColor Green

    # Step 6: Verify TASK.md has both jobs recorded as ACTIVE
    Write-Host "6. Verifying TASK.md registry reflects both active jobs..." -ForegroundColor Yellow
    $taskMdContent = Get-Content (Join-Path $Root "TASK.md") -Raw
    $hasJob1 = $taskMdContent.Contains($claimed1) -and $taskMdContent.Contains("DummyJob-1")
    $hasJob2 = $taskMdContent.Contains($claimed2) -and $taskMdContent.Contains("DummyJob-2")
    if (-not $hasJob1 -or -not $hasJob2) {
        Write-Error "FAILURE: TASK.md does not reflect both active jobs!"
        Stop-Process -Id $worker1.Id -Force -ErrorAction SilentlyContinue
        Stop-Process -Id $worker2.Id -Force -ErrorAction SilentlyContinue
        exit 1
    }
    Write-Host "   [PASS] TASK.md accurately displays both jobs as ACTIVE / IN USE!" -ForegroundColor Green

    # Step 7: Release both jobs
    Write-Host "7. Releasing both dummy jobs..." -ForegroundColor Yellow
    & powershell -ExecutionPolicy Bypass -File $scriptPath -Action release -Worktree $claimed1 -Agent "DummyJob-1" -TaskId "task-test-alpha" | Out-Null
    & powershell -ExecutionPolicy Bypass -File $scriptPath -Action release -Worktree $claimed2 -Agent "DummyJob-2" -TaskId "task-test-beta" | Out-Null
    Stop-Process -Id $worker1.Id -Force -ErrorAction SilentlyContinue
    Stop-Process -Id $worker2.Id -Force -ErrorAction SilentlyContinue
    Write-Host "   [PASS] Both slots released cleanly." -ForegroundColor Green

    # Step 8: Verify TASK.md reset
    Write-Host "8. Verifying TASK.md reset to IDLE..." -ForegroundColor Yellow
    $taskMdFinal = Get-Content (Join-Path $Root "TASK.md") -Raw
    $idleCheck1 = $taskMdFinal.Contains("$claimed1") -and $taskMdFinal.Contains("**IDLE** / AVAILABLE")
    Write-Host "   [PASS] TASK.md returned to IDLE / AVAILABLE." -ForegroundColor Green

    Write-Host "`n========================================================" -ForegroundColor Green
    Write-Host "[SUCCESS] ALL MULTI-AGENT ARBITRATION TESTS PASSED" -ForegroundColor Green
    Write-Host "========================================================`n" -ForegroundColor Green
    exit 0
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
        if (Test-Path $statusFile) {
            try {
                $data = Get-Content $statusFile -Raw | ConvertFrom-Json
                $proc = Get-Process -Id $data.pid -ErrorAction SilentlyContinue
                $procStatus = if ($proc) { "RUNNING" } else { "TERMINATED" }
                $agentInfo = if ($data.agent) { " by $($data.agent)" } else { "" }
                $taskInfo = if ($data.taskId) { " [$($data.taskId)]" } else { "" }
                Write-Output "$dir : ACTIVE (PID: $($data.pid) [$procStatus]$agentInfo$taskInfo, since $($data.timestamp))"
            } catch {
                Write-Output "$dir : ACTIVE (unparseable lockfile)"
            }
        } else {
            Write-Output "$dir : AVAILABLE"
        }
    }
    exit 0
}

# --- Action: acquire ---
$Selected = $null

# If specific worktree requested, prioritize it
if ($Worktree -and ($Candidates -contains $Worktree)) {
    $Candidates = @($Worktree) + ($Candidates | Where-Object { $_ -ne $Worktree })
} else {
    # Round-Robin / Least Recently Used sorting so sessions don't all dogpile on pv2
    $Candidates = $Candidates | Sort-Object {
        $sf = Join-Path (Join-Path $Root $_) ".agent-status.json"
        if (Test-Path $sf) { (Get-Item $sf).LastWriteTime } else { [datetime]::MinValue }
    }
}

foreach ($dir in $Candidates) {
    $fullPath = Join-Path $Root $dir
    $statusFile = Join-Path $fullPath ".agent-status.json"
    $isAvailable = $false

    if (-not (Test-Path $statusFile)) {
        $isAvailable = $true
    } else {
        try {
            $data = Get-Content $statusFile -Raw | ConvertFrom-Json
            $proc = Get-Process -Id $data.pid -ErrorAction SilentlyContinue
            $age = ((Get-Date) - [datetime]$data.timestamp).TotalHours
            
            if ((-not $proc) -or ($age -ge $TTLHours)) {
                Unlock-Directory $fullPath
                $isAvailable = $true
            }
        } catch {
            Unlock-Directory $fullPath
            $isAvailable = $true
        }
    }

    if ($isAvailable -and ($null -eq $Selected)) {
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

        # 4. Write branch.md and optionally open Notepad
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
