// src/lock.ts
import { existsSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { execSync } from 'node:child_process';
import type { AgentLockPayload, SlotStatus, SlotDefinition, BranchWorkerConfig } from './types.js';
import { resolveWorktreePath } from './config.js';

export const LOCK_FILE_NAME = '.agent-status.json';

/**
 * Checks if a process with the given PID is actively running.
 */
export function isPidAlive(pid: number): boolean {
  if (!pid || isNaN(pid) || pid <= 0) return false;
  try {
    if (process.platform === 'win32') {
      execSync(`powershell -NoProfile -Command "if (-not (Get-Process -Id ${pid} -ErrorAction SilentlyContinue)) { exit 1 }"`, {
        stdio: 'ignore',
        timeout: 3000,
      });
      return true;
    } else {
      process.kill(pid, 0);
      return true;
    }
  } catch {
    return false;
  }
}

/**
 * Reads and validates the lock file in a worktree.
 */
export function readLock(worktreePath: string): AgentLockPayload | null {
  const lockPath = join(worktreePath, LOCK_FILE_NAME);
  if (!existsSync(lockPath)) return null;

  try {
    const raw = readFileSync(lockPath, 'utf-8');
    return JSON.parse(raw) as AgentLockPayload;
  } catch {
    return null;
  }
}

/**
 * Writes an atomic lock payload to .agent-status.json.
 */
export function writeLock(worktreePath: string, payload: AgentLockPayload): void {
  const lockPath = join(worktreePath, LOCK_FILE_NAME);
  writeFileSync(lockPath, JSON.stringify(payload, null, 2), 'utf-8');
}

/**
 * Removes the lock file from a worktree.
 */
export function removeLock(worktreePath: string): void {
  const lockPath = join(worktreePath, LOCK_FILE_NAME);
  if (existsSync(lockPath)) {
    try {
      rmSync(lockPath, { force: true });
    } catch {
      // Ignore cleanup error if already removed
    }
  }
}

/**
 * Inspects a slot and returns its complete live status.
 */
export function getSlotStatus(repoRoot: string, config: BranchWorkerConfig, slot: SlotDefinition): SlotStatus {
  const fullPath = resolveWorktreePath(repoRoot, config, slot);
  const lock = readLock(fullPath);

  if (!lock) {
    return {
      id: slot.id,
      branch: slot.branch,
      folderName: slot.folderName,
      fullPath,
      isAvailable: true,
      isLocked: false,
    };
  }

  const pidAlive = isPidAlive(lock.pid);
  const lockDate = new Date(lock.timestamp);
  const ageHours = (Date.now() - lockDate.getTime()) / (1000 * 60 * 60);
  const isStale = !pidAlive || ageHours >= config.ttlHours;

  return {
    id: slot.id,
    branch: slot.branch,
    folderName: slot.folderName,
    fullPath,
    isAvailable: isStale,
    isLocked: !isStale,
    pid: lock.pid,
    isPidAlive: pidAlive,
    agent: lock.agent,
    taskId: lock.taskId,
    timestamp: lock.timestamp,
    isStale,
  };
}

/**
 * Sets OS-level write locks on the specified directory to physically prevent rogue agent tools from editing files.
 * NOTE: On Windows NTFS, setting a direct `(OI)(CI)(W,D)` deny ACE on a directory blocks Win32 directory traversal
 * and causes `git.exe` to fail enumeration ('warning: could not open directory: No such file or directory'),
 * reporting phantom file deletions. Physical commit enforcement is handled reliably via the .githooks/pre-commit hook.
 */
export function setOsWriteLock(worktreePath: string, targetSubdir = 'src'): void {
  // Safe no-op to prevent breaking git.exe directory enumeration on Windows.
}

/**
 * Removes OS-level write locks so the claimed worktree can be modified.
 */
export function removeOsWriteLock(worktreePath: string, targetSubdir = 'src'): void {
  if (process.platform !== 'win32') return;

  const targetPath = targetSubdir ? join(worktreePath, targetSubdir) : worktreePath;
  if (!existsSync(targetPath)) return;

  try {
    const user = process.env.USERNAME || 'CURRENT_USER';
    execSync(`icacls "${targetPath}" /remove:d "${user}" /C /Q`, {
      stdio: 'ignore',
      timeout: 5000,
    });
  } catch {
    // Non-fatal
  }
}
