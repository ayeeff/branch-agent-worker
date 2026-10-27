// src/config.ts
import { existsSync, readFileSync } from 'node:fs';
import { resolve, join, basename } from 'node:path';
import type { BranchWorkerConfig, SlotDefinition } from './types.js';

export const CONFIG_FILE_NAME = '.branch-worker.json';
export const DEFAULT_TTL_HOURS = 2;

/**
 * Loads configuration from .branch-worker.json or generates defaults from the current repo.
 */
export function loadConfig(targetRepoPath: string = process.cwd()): { config: BranchWorkerConfig; repoRoot: string } {
  const repoRoot = resolve(targetRepoPath);
  const configPath = join(repoRoot, CONFIG_FILE_NAME);

  if (existsSync(configPath)) {
    try {
      const raw = readFileSync(configPath, 'utf-8');
      const parsed = JSON.parse(raw);
      return {
        config: normalizeConfig(parsed, repoRoot),
        repoRoot,
      };
    } catch (err) {
      console.warn(`[baw] Warning: Failed to parse ${configPath}, falling back to defaults.`);
    }
  }

  return {
    config: getDefaultConfig(repoRoot),
    repoRoot,
  };
}

export function getDefaultConfig(repoRoot: string, slotCount = 3, prefix = 'pv'): BranchWorkerConfig {
  const repoName = basename(repoRoot);
  const slots: SlotDefinition[] = [];

  for (let i = 2; i <= slotCount + 1; i++) {
    const id = `${prefix}${i}`;
    slots.push({
      id,
      branch: `preview${i}`,
      folderName: `${repoName}-${id}`,
    });
  }

  return {
    baseBranch: 'main',
    remote: 'origin',
    worktreeLayout: 'adjacent',
    slots,
    ttlHours: DEFAULT_TTL_HOURS,
    enableOsWriteLocks: process.platform === 'win32',
    lockTargetDir: 'src',
  };
}

function normalizeConfig(raw: Partial<BranchWorkerConfig>, repoRoot: string): BranchWorkerConfig {
  const repoName = basename(repoRoot);
  const defaults = getDefaultConfig(repoRoot);

  return {
    baseBranch: raw.baseBranch || defaults.baseBranch,
    remote: raw.remote || defaults.remote,
    worktreeLayout: raw.worktreeLayout || defaults.worktreeLayout,
    slots: raw.slots && raw.slots.length > 0 ? raw.slots : defaults.slots,
    ttlHours: typeof raw.ttlHours === 'number' ? raw.ttlHours : defaults.ttlHours,
    enableOsWriteLocks: typeof raw.enableOsWriteLocks === 'boolean' ? raw.enableOsWriteLocks : defaults.enableOsWriteLocks,
    lockTargetDir: raw.lockTargetDir || defaults.lockTargetDir,
    previewUrlTemplate: raw.previewUrlTemplate,
  };
}

export function resolveWorktreePath(repoRoot: string, config: BranchWorkerConfig, slot: SlotDefinition): string {
  if (config.worktreeLayout === 'adjacent') {
    return resolve(repoRoot, '..', slot.folderName);
  }
  return resolve(repoRoot, '.worktrees', slot.folderName);
}
