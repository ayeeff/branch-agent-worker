// src/git.ts
import { execSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';

export function runGit(cmd: string, cwd: string): string {
  try {
    return execSync(`git ${cmd}`, {
      cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 30000,
    }).trim();
  } catch (err: any) {
    const stderr = err.stderr ? err.stderr.toString().trim() : err.message;
    throw new Error(`Git error (git ${cmd}): ${stderr}`);
  }
}

export function isGitRepo(cwd: string): boolean {
  try {
    runGit('rev-parse --is-inside-work-tree', cwd);
    return true;
  } catch {
    return false;
  }
}

export function getRepoRoot(cwd: string): string {
  return runGit('rev-parse --show-toplevel', cwd);
}

export interface WorktreeInfo {
  path: string;
  commit: string;
  branch?: string;
  isBare?: boolean;
}

export function listWorktrees(repoRoot: string): WorktreeInfo[] {
  const output = runGit('worktree list --porcelain', repoRoot);
  const lines = output.split('\n');
  const worktrees: WorktreeInfo[] = [];

  let current: Partial<WorktreeInfo> = {};

  for (const line of lines) {
    if (line.startsWith('worktree ')) {
      if (current.path) worktrees.push(current as WorktreeInfo);
      current = { path: resolve(line.substring('worktree '.length).trim()) };
    } else if (line.startsWith('HEAD ')) {
      current.commit = line.substring('HEAD '.length).trim();
    } else if (line.startsWith('branch ')) {
      current.branch = line.substring('branch refs/heads/'.length).trim();
    } else if (line.startsWith('bare')) {
      current.isBare = true;
    }
  }

  if (current.path) worktrees.push(current as WorktreeInfo);
  return worktrees;
}

export function ensureWorktree(
  repoRoot: string,
  targetPath: string,
  branchName: string,
  baseBranch = 'main',
  remote = 'origin'
): void {
  if (existsSync(targetPath)) return;

  // Make sure remote branch is fetched
  try {
    runGit(`fetch ${remote} ${baseBranch}:${baseBranch}`, repoRoot);
  } catch {
    try {
      runGit(`fetch ${remote}`, repoRoot);
    } catch {
      // Offline or local only
    }
  }

  // Create worktree on branch
  try {
    runGit(`worktree add -B ${branchName} "${targetPath}" ${baseBranch}`, repoRoot);
  } catch (err: any) {
    // If branch already exists, checkout without -B
    try {
      runGit(`worktree add "${targetPath}" ${branchName}`, repoRoot);
    } catch {
      throw err;
    }
  }
}

export function syncWithUpstream(worktreePath: string, baseBranch = 'main', remote = 'origin'): void {
  try {
    runGit(`fetch ${remote} ${baseBranch}`, worktreePath);
  } catch {
    // Remote fetch failed, try general fetch or proceed
  }

  try {
    runGit(`merge --ff-only ${remote}/${baseBranch}`, worktreePath);
  } catch (err: any) {
    // If upstream has no remote tracking branch, try local baseBranch
    try {
      runGit(`merge --ff-only ${baseBranch}`, worktreePath);
    } catch {
      console.warn(`[baw] Warning: Fast-forward sync against ${remote}/${baseBranch} failed in ${worktreePath}`);
    }
  }
}

export function getCommitsBehind(worktreePath: string, upstreamRef: string): number {
  try {
    const count = runGit(`rev-list --count HEAD..${upstreamRef}`, worktreePath);
    return parseInt(count, 10) || 0;
  } catch {
    return 0;
  }
}
