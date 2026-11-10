#!/usr/bin/env node
/**
 * AFF source checks for abap/src.
 *
 * Structural checks only (no SAP connection):
 *   - every *.json parses and carries a formatVersion
 *   - *.clas.abap / *.intf.abap start with CLASS / INTERFACE
 *   - <name>.tabl.json ships <name>.tabl.ddic and <name>.tabl.settings.json
 *   - <name>.stru.json ships <name>.stru.ddic
 *   - file names are lower case and follow <token>.<type>[.<sub>].<ext>
 *   - zakit_mcp.http.json declares generalInformation.handlerClass / servicePath
 *
 * Run with `npm run check:aff`; exits 1 and prints every problem on failure.
 */
import { readdir, readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const SRC_DIR = path.join(ROOT, 'abap', 'src');
const ICF_FILE = 'zakit_mcp.http.json';

// Object types this repository is allowed to ship. Extend when a new AFF type
// is really needed; a typo in the file name must fail the build, not pass it.
const OBJECT_TYPES = new Set([
  'clas',
  'intf',
  'prog',
  'fugr',
  'tabl',
  'stru',
  'view',
  'dtel',
  'doma',
  'ttyp',
  'msag',
  'http',
]);

// <token>.<type>[.<sub>].<ext>, all lower case. The optional <sub> is the AFF
// sub_type (e.g. settings in <name>.tabl.settings.json).
const FILE_NAME = /^([a-z][a-z0-9_]*)\.([a-z][a-z0-9_]*)(?:\.([a-z][a-z0-9_]*))?\.([a-z][a-z0-9_]*)$/;

const errors = [];
const warnings = [];
let fileCount = 0;
let jsonCount = 0;
let abapCount = 0;

const rel = (file) => path.relative(ROOT, file);

function fail(file, message) {
  errors.push(`${rel(file)}: ${message}`);
}

function warn(file, message) {
  warnings.push(`${rel(file)}: ${message}`);
}

/** Collect every file below abap/src, sorted for deterministic output. */
async function walk(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  entries.sort((a, b) => a.name.localeCompare(b.name));
  const files = [];
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await walk(full)));
    } else if (entry.isFile()) {
      files.push(full);
    }
  }
  return files;
}

function checkFileName(file) {
  const name = path.basename(file);
  const match = FILE_NAME.exec(name);
  if (!match) {
    fail(file, 'file name is not <token>.<type>[.<sub>].<ext> in lower case');
    return null;
  }
  const [, token, type, , ext] = match;
  if (!OBJECT_TYPES.has(type)) {
    fail(file, `unknown AFF object type "${type}" (known: ${[...OBJECT_TYPES].join(', ')})`);
  }
  if (token.length > 30) {
    warn(file, `object token is ${token.length} characters; SAP object names are limited to 30`);
  }
  if (!['abap', 'json', 'ddic'].includes(ext)) {
    fail(file, `unexpected AFF file extension ".${ext}" (expected .abap, .json or .ddic)`);
  }
  return { token, type, ext };
}

async function checkJson(file) {
  jsonCount += 1;
  let raw;
  try {
    raw = await readFile(file, 'utf8');
  } catch (error) {
    fail(file, `cannot be read: ${error.message}`);
    return null;
  }
  // JSON.parse rejects a UTF-8 BOM; ABAP editors occasionally write one.
  const text = raw.charCodeAt(0) === 0xfeff ? raw.slice(1) : raw;
  let data;
  try {
    data = JSON.parse(text);
  } catch (error) {
    fail(file, `invalid JSON: ${error.message}`);
    return null;
  }
  if (data === null || typeof data !== 'object' || Array.isArray(data)) {
    fail(file, 'top-level JSON value must be an object');
    return null;
  }
  if (typeof data.formatVersion !== 'string' || data.formatVersion === '') {
    fail(file, 'missing top-level "formatVersion" string');
  }
  return data;
}

async function checkAbap(file, parsed) {
  abapCount += 1;
  let raw;
  try {
    raw = await readFile(file, 'utf8');
  } catch (error) {
    fail(file, `cannot be read: ${error.message}`);
    return;
  }
  const text = raw.replace(/^\uFEFF/, '').replace(/^\s+/, '').toUpperCase();
  if (parsed.type === 'clas' && !text.startsWith('CLASS ')) {
    fail(file, 'source does not start with "CLASS "');
  }
  if (parsed.type === 'intf' && !text.startsWith('INTERFACE ') && !text.startsWith('CLASS ')) {
    fail(file, 'source does not start with "INTERFACE "');
  }
}

/** <name>.tabl.json / <name>.stru.json companion files. */
async function checkCompanions(files, file, parsed) {
  const base = path.basename(file);
  const stem = base.slice(0, base.length - '.json'.length); // <name>.tabl / <name>.stru

  // <name>.tabl.settings.json is itself a companion, not a definition.
  if (parsed.type === 'tabl' && base.endsWith('.tabl.settings.json')) {
    return;
  }

  const required = [];
  if (parsed.type === 'tabl' && base.endsWith('.tabl.json')) {
    required.push(`${stem}.ddic`, `${stem}.settings.json`);
  } else if (parsed.type === 'stru' && base.endsWith('.stru.json')) {
    required.push(`${stem}.ddic`);
  }

  for (const companion of required) {
    const target = path.join(path.dirname(file), companion);
    if (!files.has(target)) {
      fail(file, `missing companion file ${companion}`);
    }
  }
}

function checkIcf(data, file) {
  if (path.basename(file) !== ICF_FILE) {
    return;
  }
  const info = data.generalInformation;
  if (!info || typeof info !== 'object') {
    fail(file, 'missing "generalInformation" object');
    return;
  }
  if (typeof info.handlerClass !== 'string' || info.handlerClass === '') {
    fail(file, 'missing generalInformation.handlerClass');
  }
  if (typeof info.servicePath !== 'string' || !info.servicePath.startsWith('/')) {
    fail(file, 'generalInformation.servicePath must be an absolute ICF path starting with "/"');
  }
}

async function main() {
  try {
    await stat(SRC_DIR);
  } catch {
    console.error(`AFF check: source directory not found: ${rel(SRC_DIR)}`);
    process.exit(1);
  }

  const files = await walk(SRC_DIR);
  const fileSet = new Set(files.map((file) => path.resolve(file)));
  fileCount = files.length;

  for (const file of files) {
    const parsed = checkFileName(file);
    if (!parsed) {
      continue;
    }
    if (parsed.ext === 'json') {
      const data = await checkJson(file);
      if (data) {
        await checkCompanions(fileSet, file, parsed);
        checkIcf(data, file);
      }
    } else if (parsed.ext === 'abap') {
      await checkAbap(file, parsed);
    }
  }

  for (const message of warnings) {
    console.warn(`WARN  ${message}`);
  }
  if (errors.length > 0) {
    for (const message of errors) {
      console.error(`FAIL  ${message}`);
    }
    console.error(`\nAFF check failed: ${errors.length} problem(s) in ${fileCount} file(s).`);
    process.exit(1);
  }

  console.log(
    `AFF check passed: ${fileCount} file(s) in abap/src ` +
      `(${jsonCount} JSON, ${abapCount} ABAP, ${fileCount - jsonCount - abapCount} DDIC/other).`,
  );
}

main().catch((error) => {
  console.error(`AFF check crashed: ${error.stack ?? error.message}`);
  process.exit(1);
});
