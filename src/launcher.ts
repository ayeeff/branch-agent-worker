// src/launcher.ts
import { spawn } from 'node:child_process';
import { loadConfig } from './config.js';
import { claimSlot, releaseSlot } from './index.js';

export async function runInClaimedWorktree(
  command: string,
  args: string[],
  options: {
    agent?: string;
    taskId?: string;
    worktree?: string;
    repoRoot?: string;
    openNotepad?: boolean;
  } = {}
): Promise<number> {
  const { config, repoRoot } = loadConfig(options.repoRoot || process.cwd());

  console.log(`[baw] Claiming an available worktree slot...`);
  const claimResult = claimSlot(repoRoot, config, {
    agent: options.agent || 'Agent',
    taskId: options.taskId || '',
    preferredWorktree: options.worktree,
    openNotepad: options.openNotepad,
  });

  if (!claimResult.success || !claimResult.slot || !claimResult.worktreePath) {
    console.error(`[baw] Error: ${claimResult.error || 'Failed to claim a worktree.'}`);
    return 1;
  }

  const { slot, worktreePath } = claimResult;
  console.log(`[baw] Successfully claimed slot '${slot.id}' at: ${worktreePath}`);
  console.log(`[baw] Launching command: ${command} ${args.join(' ')}`);

  let exitCode = 0;

  try {
    exitCode = await new Promise<number>((resolve) => {
      const child = spawn(command, args, {
        cwd: worktreePath,
        stdio: 'inherit',
        shell: true,
      });

      const handleSignal = () => {
        child.kill();
      };

      process.on('SIGINT', handleSignal);
      process.on('SIGTERM', handleSignal);

      child.on('close', (code) => {
        resolve(code ?? 0);
      });

      child.on('error', (err) => {
        console.error(`[baw] Process error:`, err);
        resolve(1);
      });
    });
  } finally {
    console.log(`[baw] Cleaning up and releasing slot '${slot.id}'...`);
    releaseSlot(repoRoot, config, slot.id, options.agent || 'Agent', options.taskId || '');
    console.log(`[baw] Slot '${slot.id}' released.`);
  }

  return exitCode;
}
