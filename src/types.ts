// src/types.ts
export interface BranchWorkerConfig {
  /** The base branch that all worker slots branch from and sync against (e.g. "main", "preview") */
  baseBranch: string;
  /** Remote name to fetch and sync against (default: "origin") */
  remote: string;
  /** Directory where worktrees are stored: "adjacent" (e.g. ../repo-pv2) or "nested" (e.g. ./worktrees/pv2) */
  worktreeLayout: 'adjacent' | 'nested';
  /** Slot definitions or prefix config */
  slots: SlotDefinition[];
  /** Hours before an inactive lock without a live PID is considered stale */
  ttlHours: number;
  /** Enable NTFS/OS-level write denials on locked/unclaimed directories */
  enableOsWriteLocks: boolean;
  /** Directory inside worktree to lock with OS permissions (default: "src") */
  lockTargetDir?: string;
  /** Template for generating staging/preview URLs, e.g. "https://{branch}-app.example.com" */
  previewUrlTemplate?: string;
}

export interface SlotDefinition {
  /** Identifier for the slot (e.g. "pv2", "worker-1") */
  id: string;
  /** Name of the git branch (e.g. "preview2", "worker-1") */
  branch: string;
  /** Worktree folder name (e.g. "site-pv2", "repo-pv2") */
  folderName: string;
}

export interface AgentLockPayload {
  pid: number;
  timestamp: string;
  worktree: string;
  branch: string;
  agent: string;
  taskId: string;
  status: 'ACTIVE' | 'RELEASED';
}

export interface SlotStatus {
  id: string;
  branch: string;
  folderName: string;
  fullPath: string;
  isAvailable: boolean;
  isLocked: boolean;
  pid?: number;
  isPidAlive?: boolean;
  agent?: string;
  taskId?: string;
  timestamp?: string;
  isStale?: boolean;
}
