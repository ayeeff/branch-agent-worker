// src/index.ts
import { join } from 'node:path';
import type { BranchWorkerConfig, SlotDefinition, SlotStatus } from './types.js';
import { resolveWorktreePath } from './config.js';
import {
  getSlotStatus,
  writeLock,
  removeLock,
  setOsWriteLock,
  removeOsWriteLock,
} from './lock.js';
import { ensureWorktree, syncWithUpstream } from './git.js';
import { generateBranchMarkdown, openInViewer } from './markdown.js';

export * from './types.js';
export * from './config.js';
export * from './git.js';
export * from './lock.js';
export * from './hooks.js';
export * from './markdown.js';
export * from './launcher.js';

export interface ClaimOptions {
  agent?: string;
  taskId?: string;
  preferredWorktree?: string;
  openNotepad?: boolean;
}

export interface ClaimResult {
  success: boolean;
  slot?: SlotDefinition;
  worktreePath?: string;
  error?: string;
}

/**
 * Scans available slots, checks stale locks, fast-forwards upstream, and claims exclusive ownership.
 */
export function claimSlot(
  repoRoot: string,
  config: BranchWorkerConfig,
  options: ClaimOptions = {}
): ClaimResult {
  const agent = options.agent || 'Agent';
  const taskId = options.taskId || '';
  const preferred = options.preferredWorktree;

  let candidates = [...config.slots];

  // If a specific slot was requested, prioritize it
  if (preferred) {
    const match = candidates.find((s) => s.id === preferred || s.folderName === preferred || s.branch === preferred);
    if (match) {
      candidates = [match, ...candidates.filter((s) => s !== match)];
    }
  }

  for (const slot of candidates) {
    const status = getSlotStatus(repoRoot, config, slot);

    if (status.isAvailable) {
      const fullPath = status.fullPath;

      // Ensure the worktree exists
      ensureWorktree(repoRoot, fullPath, slot.branch, config.baseBranch, config.remote);

      // Unlock OS write permissions on target directory
      if (config.enableOsWriteLocks) {
        removeOsWriteLock(fullPath, config.lockTargetDir);
      }

      // Sync with upstream
      syncWithUpstream(fullPath, config.baseBranch, config.remote);

      // Write lock payload
      writeLock(fullPath, {
        pid: process.pid,
        timestamp: new Date().toISOString(),
        worktree: slot.folderName,
        branch: slot.branch,
        agent,
        taskId,
        status: 'ACTIVE',
      });

      // Write branch.md and optionally open Notepad
      const mdPath = generateBranchMarkdown(repoRoot, config, slot, agent, taskId, 'ACTIVE', fullPath);
      if (options.openNotepad) {
        openInViewer(mdPath);
      }

      return {
        success: true,
        slot,
        worktreePath: fullPath,
      };
    }
  }

  return {
    success: false,
    error: 'ALL_SLOTS_BUSY: All configured worker slots are currently locked by live agent sessions.',
  };
}

/**
 * Releases a worktree lock and updates branch.md.
 */
export function releaseSlot(
  repoRoot: string,
  config: BranchWorkerConfig,
  slotIdentifier: string,
  agent = 'Agent',
  taskId = ''
): boolean {
  const slot = config.slots.find(
    (s) => s.id === slotIdentifier || s.folderName === slotIdentifier || s.branch === slotIdentifier
  );

  if (!slot) {
    console.error(`[baw] Unknown slot: '${slotIdentifier}'`);
    return false;
  }

  const fullPath = resolveWorktreePath(repoRoot, config, slot);

  // Remove lock file
  removeLock(fullPath);

  // Re-apply OS write lock if configured
  if (config.enableOsWriteLocks) {
    setOsWriteLock(fullPath, config.lockTargetDir);
  }

  // Update branch.md
  generateBranchMarkdown(repoRoot, config, slot, agent, taskId, 'RELEASED / IDLE', fullPath);
  return true;
}

/**
 * Returns statuses of all slots.
 */
export function getAllSlotStatuses(repoRoot: string, config: BranchWorkerConfig): SlotStatus[] {
  return config.slots.map((slot) => getSlotStatus(repoRoot, config, slot));
}
