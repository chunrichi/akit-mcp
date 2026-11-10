#!/usr/bin/env node
/**
 * AKIT MCP installer (abap-cli based).
 *
 * Creates every ABAP object of abap/src in the target system, pushes the
 * sources, activates them, creates the ICF node and seeds the default MCP
 * endpoint. Idempotent: existing objects are reused, changed sources are
 * pushed again.
 *
 * Usage:
 *   node scripts/install.mjs [--package <pkg>] [--tr <transport>]
 *                            [--dry-run] [--yes]
 */
import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SRC = path.join(ROOT, 'abap', 'src');

const args = process.argv.slice(2);
const opt = {
  package: readOption('--package'),
  transport: readOption('--tr'),
  dryRun: args.includes('--dry-run'),
  yes: args.includes('--yes'),
};

function readOption(name) {
  const index = args.indexOf(name);
  return index >= 0 && args[index + 1] ? args[index + 1] : '';
}

function log(message) {
  process.stdout.write(`${message}\n`);
}

function fail(message) {
  process.stderr.write(`error: ${message}\n`);
  process.exit(1);
}

/** Run one abap-cli command and return its JSON envelope (never throws on CLI error). */
function abap(commandArgs) {
  const result = spawnSync('abap', [...commandArgs, '--json'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const stdout = (result.stdout || '').trim();
  const stderr = (result.stderr || '').trim();
  if (!stdout) {
    return { ok: false, code: 'CLI_FAILED', message: stderr || `abap ${commandArgs.join(' ')} failed` };
  }
  let envelope;
  try {
    envelope = JSON.parse(stdout);
  } catch {
    return { ok: false, code: 'CLI_OUTPUT', message: stdout.slice(0, 400) };
  }
  if (envelope.status === 'success') {
    return { ok: true, data: envelope.data || {} };
  }
  const error = envelope.error || {};
  return {
    ok: false,
    code: error.code || 'UNKNOWN',
    message: error.message || `abap ${commandArgs.join(' ')} failed`,
  };
}

function objectToken(fileName) {
  const match = /^(.+)\.(clas|intf|stru|tabl|prog|http)\.json$/.exec(fileName);
  if (!match) return undefined;
  return { token: match[1], type: match[2].toUpperCase() };
}

function readDescription(jsonPath) {
  try {
    const doc = JSON.parse(readFileSync(jsonPath, 'utf8'));
    return doc?.header?.description || 'AKIT MCP object';
  } catch {
    return 'AKIT MCP object';
  }
}

/** Discover the object manifest from the AFF files. */
function discover() {
  const objects = [];
  for (const fileName of readdirSync(SRC).sort()) {
    const parsed = objectToken(fileName);
    if (!parsed) continue;
    const { token, type } = parsed;
    const mainFile = path.join(SRC, fileName);
    const object = {
      token,
      type,
      name: token.toUpperCase(),
      mainFile,
      description: readDescription(mainFile),
      sourceFile: '',
      needsDdic: false,
    };
    if (type === 'TABL' || type === 'STRU') {
      object.needsDdic = true;
      const ddicFile = path.join(SRC, `${token}.${type.toLowerCase()}.ddic`);
      if (!existsSync(ddicFile)) {
        fail(`missing ${path.relative(ROOT, ddicFile)} (AFF table/structure sidecar)`);
      }
    }
    if (type === 'CLAS' || type === 'INTF') {
      object.sourceFile = path.join(SRC, `${token}.${type.toLowerCase()}.abap`);
      if (!existsSync(object.sourceFile)) fail(`missing ${path.relative(ROOT, object.sourceFile)}`);
    }
    if (type === 'PROG') {
      object.sourceFile = path.join(SRC, `${token}.prog.abap`);
      if (!existsSync(object.sourceFile)) fail(`missing ${path.relative(ROOT, object.sourceFile)}`);
    }
    objects.push(object);
  }
  return objects;
}

const CREATE_ORDER = ['TABL', 'STRU', 'INTF', 'CLAS', 'PROG', 'HTTP'];

function objectExists(name) {
  const result = abap(['inspect', name]);
  return result.ok;
}

function createObject(object) {
  const pkg = opt.package;
  const transportArgs = opt.transport ? ['--tr', opt.transport] : [];

  if (object.type === 'TABL' || object.type === 'STRU' || object.type === 'HTTP') {
    return abap(['create', object.type, object.name, '--file', path.relative(ROOT, object.mainFile),
      '--package', pkg, ...transportArgs, '--yes']);
  }

  if (object.type === 'PROG') {
    return abap(['create', 'PROG', object.name, '--package', pkg,
      '--description', object.description, '--template', 'report',
      '--no-pull', ...transportArgs, '--yes']);
  }

  return abap(['create', object.type, object.name, '--package', pkg,
    '--description', object.description, '--no-pull', ...transportArgs, '--yes']);
}

function pushSource(object) {
  return abap(['push', path.relative(ROOT, object.sourceFile), '--yes']);
}

function main() {
  if (!existsSync(path.join(ROOT, 'abap', '.abap.json')) && !existsSync(path.join(ROOT, '.abap.json'))) {
    fail('no .abap.json workspace binding. Run `abap init --profile <your profile>` in the repository root first.');
  }

  const version = spawnSync('abap', ['--version'], { cwd: ROOT, encoding: 'utf8' });
  if (version.status !== 0 || !/^\d+\.\d+\.\d+/.test((version.stdout || '').trim())) {
    fail('abap-cli (abap) is not available on PATH.');
  }

  if (!opt.package) {
    try {
      const workspace = JSON.parse(readFileSync(path.join(ROOT, '.abap.json'), 'utf8'));
      opt.package = workspace.package || '$TMP';
    } catch {
      opt.package = '$TMP';
    }
  }
  const isLocalPackage = opt.package.trim().startsWith('$');
  if (!isLocalPackage && !opt.transport && !opt.dryRun) {
    fail(`--package ${opt.package} is transportable: pass --tr <transport> as well.`);
  }

  const objects = discover();
  if (objects.length === 0) fail(`no AFF objects found under ${path.relative(ROOT, SRC)}`);

  log(`AKIT MCP installer — ${objects.length} objects, package ${opt.package}`);
  if (opt.dryRun) log('(dry run: nothing will be written)');

  const ordered = [...objects].sort(
    (a, b) => CREATE_ORDER.indexOf(a.type) - CREATE_ORDER.indexOf(b.type));
  let created = 0;
  let existing = 0;
  const failed = [];

  for (const object of ordered) {
    const known = object.type === 'HTTP' ? false : objectExists(object.name);
    if (known) {
      existing += 1;
      continue;
    }
    if (opt.dryRun) {
      log(`plan: create ${object.type} ${object.name}`);
      continue;
    }
    const result = createObject(object);
    if (result.ok) {
      created += 1;
      log(`created ${object.type} ${object.name}`);
    } else if (result.code === 'OBJECT_EXISTS' || /already exist/i.test(result.message)) {
      existing += 1;
    } else {
      failed.push(`${object.type} ${object.name}: ${result.message}`);
      log(`failed  ${object.type} ${object.name}: ${result.message}`);
    }
  }

  const sourceObjects = ordered.filter((object) => object.sourceFile);
  let round = 0;
  let pending = sourceObjects;
  const pushErrors = new Map();
  while (pending.length > 0 && round < 4) {
    round += 1;
    const next = [];
    for (const object of pending) {
      if (opt.dryRun) {
        log(`plan: push ${path.relative(ROOT, object.sourceFile)}`);
        continue;
      }
      const result = pushSource(object);
      if (result.ok) {
        pushErrors.delete(object.sourceFile);
        log(`pushed  ${object.type} ${object.name}`);
      } else {
        pushErrors.set(object.sourceFile, result.message);
        next.push(object);
      }
    }
    pending = next;
    if (pending.length > 0 && !opt.dryRun) {
      log(`retrying ${pending.length} object(s) whose dependencies are not active yet…`);
    }
  }

  for (const object of pending) {
    const message = pushErrors.get(object.sourceFile);
    failed.push(`${object.type} ${object.name}: ${message}`);
    log(`failed  ${object.type} ${object.name}: ${message}`);
  }

  if (!opt.dryRun) {
    const setup = abap(['run', 'zcl_akit_mcp_setup']);
    if (setup.ok) {
      log(`setup: ${(setup.data.output || '').trim()}`);
    } else {
      failed.push(`setup: ${setup.message}`);
      log(`setup failed: ${setup.message}`);
    }
  }

  log('');
  log(`Objects: ${created} created, ${existing} existing, ${failed.length} failed.`);
  if (failed.length > 0) {
    log('Failed:');
    for (const message of failed) log(`  - ${message}`);
    process.exit(1);
  }
  log('Next:');
  log('  1. Verify the protocol:  abap run zcl_akit_mcp_selftest');
  log('  2. Call tools:           node scripts/akit-mcp.mjs --url https://<host>:<port>/sap/bc/mcp/dev --user <u> tools');
  log('  3. Open an endpoint:     POST /sap/bc/mcp/<endpoint>');
}

main();
