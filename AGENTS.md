# AGENTS.md — Autonomous Agent Operating Protocol

> **Target Audience:** LLM Coding Assistants (Gemini Antigravity, Claude Code, Cursor, Copilot Workspace, custom autonomous agents).
> **Rule:** This protocol is **mandatory and strictly enforced** at both the OS NTFS level (`icacls`) and Git hook level (`pre-commit`). Bypassing this protocol will result in rejected commits or OS `Access Denied` exceptions.

---

## ⚡ Agent Jump Protocol — READ THIS FIRST, EXECUTE BEFORE TOUCHING CODE

You are strictly prohibited from editing files in the root integration repository or any worktree that has not been claimed via this protocol.

### 1. Identify Available Worktree Slot
Before executing any code edits, run the status command to view the live slot registry:

```bash
# Using Bun / Node CLI:
baw status

# Or using pure PowerShell on Windows:
powershell -ExecutionPolicy Bypass -File branch-worker.ps1 status
```

Review the table. Look for an `AVAILABLE` slot (or a `STALE` slot where the recorded process is no longer running).

### 2. Claim Exclusive Ownership & Fast-Forward Upstream
Acquire the first available slot:

```bash
# Using Bun / Node CLI:
baw claim --agent "<YourAgentName>" --task "<TaskId>" --notepad

# Or using pure PowerShell:
powershell -ExecutionPolicy Bypass -File branch-worker.ps1 claim -Agent "<YourAgentName>" -TaskId "<TaskId>" -OpenNotepad
```

This single command automatically:
1. Verifies PID liveness and evicts stale locks (> 2h or dead PID).
2. Unlocks the OS filesystem write permissions on that slot.
3. Fast-forwards the branch with the upstream base branch (`origin/main` or `origin/preview`).
4. Creates `.agent-status.json` recording your PID and timestamp.
5. Writes `branch.md` in the root directory and displays it in Notepad.

### 3. Work Strictly Inside the Claimed Worktree Directory
Navigate your operations strictly to the claimed directory reported in `branch.md` (e.g. `../my-repo-pv2` or `site-pv2`):

- **Rule 1:** Only read and edit files inside your claimed worktree directory.
- **Rule 2:** Do NOT modify files in the integration checkout or sibling worktrees.
- **Rule 3:** The Git `pre-commit` hook will reject any commit if `.agent-status.json` is missing or if the branch has fallen behind upstream.

### 4. Mandatory Release on Completion or Interrupt
Before concluding your final response, completing the task, or if you encounter an unrecoverable error, you MUST release your claimed slot:

```bash
# Using Bun / Node CLI:
baw release --worktree <slot-id>

# Or using pure PowerShell:
powershell -ExecutionPolicy Bypass -File branch-worker.ps1 release -Worktree <slot-id>
```

This removes `.agent-status.json`, updates `branch.md` to `RELEASED / IDLE`, and re-locks the directory to protect against stray writes.

---

## 🛡️ Failure Modes & Recovery Procedures

| Failure Symptom | Cause | Resolution |
|---|---|---|
| `COMMIT BLOCKED: Worktree has not been acquired (.agent-status.json missing)` | Attempting to commit in a folder without running `baw claim`. | Run `baw claim` to acquire the slot and create the lock file. |
| `COMMIT BLOCKED: Worktree is N commits behind upstream` | Upstream merged changes while you were working. | Run `git fetch origin && git merge --ff-only origin/<baseBranch>` inside the worktree before committing. |
| `System.UnauthorizedAccessException: Access to the path is denied` | Unclaimed worktree is locked with NTFS write denial. | Run `baw claim` to unlock permissions for your session. |
| `ALL_SLOTS_BUSY` | All slots (`pv2`, `pv3`, `pv4`) are currently locked by live agents. | Halt execution. Inform the user that all worker slots are active and wait for an existing session to release. |

---

## 📋 Copy-Paste Prompt Template for ANY External Repo

When adding this workflow to any external project, paste this section into that repo's `AGENTS.md` or system prompt:

```markdown
## Mandatory Worktree Arbitration Protocol

Before making any code edits or running builds:
1. Run `baw status` (or `powershell -ExecutionPolicy Bypass -File branch-worker.ps1 status`).
2. Run `baw claim --agent "<Name>" --task "<TaskId>" --notepad` to claim an available slot.
3. Switch your tool working directory to the claimed worktree directory reported in `branch.md`.
4. Perform all modifications strictly inside that directory.
5. Prior to exiting or concluding your turn, run `baw release --worktree <slot-id>`.
```
