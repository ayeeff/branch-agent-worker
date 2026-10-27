// tests/baw.test.ts
import { test, expect } from 'bun:test';
import { getDefaultConfig, resolveWorktreePath } from '../src/config.js';
import { isPidAlive } from '../src/lock.js';
import { generateBranchMarkdown } from '../src/markdown.js';
import { existsSync, readFileSync, rmSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

test('getDefaultConfig produces valid slot definitions', () => {
  const config = getDefaultConfig('/workspace/my-app', 3, 'pv');
  expect(config.baseBranch).toBe('main');
  expect(config.slots.length).toBe(3);
  expect(config.slots[0].id).toBe('pv2');
  expect(config.slots[0].folderName).toBe('my-app-pv2');
});

test('resolveWorktreePath computes adjacent layout properly', () => {
  const config = getDefaultConfig('D:\\github\\my-app', 2, 'worker');
  const path = resolveWorktreePath('D:\\github\\my-app', config, config.slots[0]);
  expect(path).toContain('my-app-worker2');
});

test('isPidAlive accurately detects current process', () => {
  expect(isPidAlive(process.pid)).toBe(true);
  expect(isPidAlive(9999999)).toBe(false);
  expect(isPidAlive(0)).toBe(false);
});

test('generateBranchMarkdown generates clean markdown and valid fields', () => {
  const testDir = join(tmpdir(), `baw-test-${Date.now()}`);
  mkdirSync(testDir, { recursive: true });

  const config = getDefaultConfig(testDir, 1, 'pv');
  const slot = config.slots[0];

  const mdPath = generateBranchMarkdown(
    testDir,
    config,
    slot,
    'Antigravity',
    'task-99',
    'ACTIVE',
    'D:\\github\\test-pv2'
  );

  expect(existsSync(mdPath)).toBe(true);
  const content = readFileSync(mdPath, 'utf-8');
  expect(content).toContain('**Agent** | Antigravity');
  expect(content).toContain('**Task ID** | task-99');
  expect(content).toContain('`preview2`');
  expect(content).toContain('ACTIVE');

  // Cleanup
  rmSync(testDir, { recursive: true, force: true });
});
