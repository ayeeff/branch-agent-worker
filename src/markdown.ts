// src/markdown.ts
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import type { SlotDefinition, BranchWorkerConfig } from './types.js';

export function generateBranchMarkdown(
  repoRoot: string,
  config: BranchWorkerConfig,
  slot: SlotDefinition,
  agent: string,
  taskId: string,
  status: 'ACTIVE' | 'RELEASED / IDLE',
  worktreePath: string
): string {
  const branchFile = join(repoRoot, 'branch.md');
  const now = new Date().toISOString().replace('T', ' ').substring(0, 19);

  let previewUrl = '';
  if (config.previewUrlTemplate) {
    previewUrl = config.previewUrlTemplate.replace('{branch}', slot.branch).replace('{id}', slot.id);
  }

  const b = '`';
  const cb = '```';

  const previewSection = previewUrl
    ? `\n---\n\n### 🔗 Live Preview URL\n${previewUrl}\n`
    : '';

  const md = `# 🌿 Active Agent Session & Branch Allocation

| Attribute | Details |
|---|---|
| **Agent** | ${agent} |
| **Task ID** | ${taskId || 'Unspecified'} |
| **Branch** | ${b}${slot.branch}${b} (${b}${slot.folderName}${b}) |
| **Directory** | ${b}${worktreePath}${b} |
| **Status** | ${status} |
| **Timestamp** | ${now} |
| **PID** | ${process.pid} |
${previewSection}
---

### 🛠️ Release Command
${cb}bash
baw release --worktree ${slot.id}
${cb}
`;

  writeFileSync(branchFile, md, 'utf-8');
  return branchFile;
}

export function openInViewer(filePath: string, viewer = 'notepad'): void {
  try {
    if (process.platform === 'win32') {
      const child = spawn(viewer, [filePath], {
        detached: true,
        stdio: 'ignore',
        shell: true,
      });
      child.unref();
    } else {
      const opener = process.platform === 'darwin' ? 'open' : 'xdg-open';
      const child = spawn(opener, [filePath], {
        detached: true,
        stdio: 'ignore',
      });
      child.unref();
    }
  } catch (err: any) {
    console.warn(`[baw] Could not launch viewer '${viewer}':`, err.message);
  }
}
