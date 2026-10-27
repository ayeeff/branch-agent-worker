#!/usr/bin/env bun
// src/cli.ts
import { writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import {
  loadConfig,
  getDefaultConfig,
  CONFIG_FILE_NAME,
  claimSlot,
  releaseSlot,
  getAllSlotStatuses,
  installGitHooks,
  runInClaimedWorktree,
  setOsWriteLock,
  removeOsWriteLock,
  resolveWorktreePath,
} from './index.js';

const HELP_TEXT = `
branch-agent-worker (baw) - Autonomous Branch & Worktree Manager for LLM Agents

USAGE:
  baw <command> [options]

COMMANDS:
  init          Initialize .branch-worker.json, create worktrees, and install git hooks
  status        Display real-time allocation status of all worker branches
  claim         Scan for an available slot, acquire the lock, fast-forward, and record allocation
  release       Release a claimed worktree and reset permissions
  run           Execute a command inside a dynamically claimed worktree with guaranteed release
  hooks         Install git pre-commit safety hooks into current repo
  lock-all      Set OS-level write locks on all inactive worktrees
  unlock-all    Remove OS-level write locks across all worktrees

OPTIONS:
  -w, --worktree <name>   Target a specific worktree slot (e.g. pv2, pv3, site-pv2)
  -a, --agent <name>      Name of the AI agent or user (default: "Antigravity")
  -t, --task <id>         Task identifier or ticket name (e.g. "task44-20261028")
  -n, --notepad           Automatically open branch.md in Notepad on claim
  -s, --slots <number>    Number of worker slots during init (default: 3)
  -p, --prefix <prefix>   Slot name prefix during init (default: "pv")
  -h, --help              Show help information
  -v, --version           Show version information

EXAMPLES:
  baw init --slots 3
  baw status
  baw claim -a "Antigravity" -t "task45" --notepad
  baw release -w pv2
  baw run -a "Antigravity" -t "task45" -- code .
`;

async function main() {
  const args = process.argv.slice(2);
  const command = args[0];

  if (!command || command === '-h' || command === '--help') {
    console.log(HELP_TEXT);
    process.exit(0);
  }

  if (command === '-v' || command === '--version') {
    console.log('branch-agent-worker v1.0.0');
    process.exit(0);
  }

  const { values, positionals } = parseArgs({
    args: args.slice(1),
    options: {
      worktree: { type: 'string', short: 'w' },
      agent: { type: 'string', short: 'a', default: 'Antigravity' },
      task: { type: 'string', short: 't', default: '' },
      notepad: { type: 'boolean', short: 'n', default: false },
      slots: { type: 'string', short: 's', default: '3' },
      prefix: { type: 'string', short: 'p', default: 'pv' },
      help: { type: 'boolean', short: 'h', default: false },
    },
    allowPositionals: true,
  });

  const cwd = process.cwd();
  const { config, repoRoot } = loadConfig(cwd);

  switch (command) {
    case 'init': {
      console.log(`[baw] Initializing branch-agent-worker in: ${repoRoot}`);
      const configPath = join(repoRoot, CONFIG_FILE_NAME);

      if (!existsSync(configPath)) {
        const slotsCount = parseInt(values.slots || '3', 10);
        const prefix = values.prefix || 'pv';
        const newConfig = getDefaultConfig(repoRoot, slotsCount, prefix);
        writeFileSync(configPath, JSON.stringify(newConfig, null, 2), 'utf-8');
        console.log(`[baw] Created ${CONFIG_FILE_NAME}`);
      } else {
        console.log(`[baw] Configuration file ${CONFIG_FILE_NAME} already exists.`);
      }

      console.log(`[baw] Installing Git pre-commit hooks...`);
      installGitHooks(repoRoot);
      console.log(`[baw] Git hooks installed. Worktrees are protected.`);
      break;
    }

    case 'status': {
      const statuses = getAllSlotStatuses(repoRoot, config);
      console.log(`\n🌿 Worker Slot Registry (${repoRoot})\n`);
      console.log(
        'Slot'.padEnd(10) +
        'Branch'.padEnd(14) +
        'Status'.padEnd(14) +
        'PID'.padEnd(10) +
        'Agent'.padEnd(16) +
        'Task'
      );
      console.log('-'.repeat(75));

      for (const s of statuses) {
        const statusText = s.isAvailable ? 'AVAILABLE' : s.isStale ? 'STALE' : 'ACTIVE';
        const pidText = s.pid ? `${s.pid} ${s.isPidAlive ? '●' : '○'}` : '-';
        const agentText = s.agent || '-';
        const taskText = s.taskId || '-';

        console.log(
          s.id.padEnd(10) +
          s.branch.padEnd(14) +
          statusText.padEnd(14) +
          pidText.padEnd(10) +
          agentText.padEnd(16) +
          taskText
        );
      }
      console.log('');
      break;
    }

    case 'claim':
    case 'acquire': {
      const result = claimSlot(repoRoot, config, {
        agent: values.agent,
        taskId: values.task,
        preferredWorktree: values.worktree,
        openNotepad: values.notepad,
      });

      if (!result.success || !result.slot) {
        console.error(`\n❌ ${result.error}\n`);
        process.exit(1);
      }

      console.log(`\n✅ CLAIMED:${result.slot.id}`);
      console.log(`   Branch:    ${result.slot.branch}`);
      console.log(`   Directory: ${result.worktreePath}\n`);
      break;
    }

    case 'release': {
      const target = values.worktree || positionals[0];
      if (!target) {
        console.error(`[baw] Error: Specify slot or worktree name to release, e.g. 'baw release -w pv2'`);
        process.exit(1);
      }

      const ok = releaseSlot(repoRoot, config, target, values.agent, values.task);
      if (ok) {
        console.log(`\n🔓 RELEASED:${target}\n`);
      } else {
        process.exit(1);
      }
      break;
    }

    case 'run': {
      if (positionals.length === 0) {
        console.error(`[baw] Error: No command specified to run. Example: 'baw run -- code .'`);
        process.exit(1);
      }

      const execCmd = positionals[0];
      const execArgs = positionals.slice(1);

      const code = await runInClaimedWorktree(execCmd, execArgs, {
        agent: values.agent,
        taskId: values.task,
        worktree: values.worktree,
        openNotepad: values.notepad,
        repoRoot,
      });

      process.exit(code);
      break;
    }

    case 'hooks': {
      installGitHooks(repoRoot);
      console.log(`[baw] Git pre-commit safety hooks successfully configured in ${repoRoot}`);
      break;
    }

    case 'lock-all': {
      for (const slot of config.slots) {
        const path = resolveWorktreePath(repoRoot, config, slot);
        setOsWriteLock(path, config.lockTargetDir);
      }
      console.log(`[baw] Applied OS write deny rules to all slot directories.`);
      break;
    }

    case 'unlock-all': {
      for (const slot of config.slots) {
        const path = resolveWorktreePath(repoRoot, config, slot);
        removeOsWriteLock(path, config.lockTargetDir);
      }
      console.log(`[baw] Cleared OS write deny rules from all slot directories.`);
      break;
    }

    default:
      console.error(`[baw] Unknown command: '${command}'. Run 'baw --help' for available commands.`);
      process.exit(1);
  }
}

main().catch((err) => {
  console.error('[baw] Fatal error:', err);
  process.exit(1);
});
