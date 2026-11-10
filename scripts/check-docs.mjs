#!/usr/bin/env node
/**
 * Documentation checks (no SAP connection).
 *
 *   - required files exist (README pair, docs/, CHANGELOG, CONTRIBUTING, LICENSE)
 *   - relative Markdown links and image paths in the README files and docs resolve
 *   - the English and Chinese READMEs keep the same H2 structure
 *   - the license is MIT in LICENSE and package.json
 *
 * Run with `npm run check:docs`; exits 1 and prints every problem on failure.
 */
import { readdir, readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const DOCS_DIR = path.join(ROOT, 'docs');
const README_EN = 'README.md';
const README_ZH = 'README.zh-CN.md';

const REQUIRED_FILES = [
  README_EN,
  README_ZH,
  'CHANGELOG.md',
  'CONTRIBUTING.md',
  'LICENSE',
  'docs/design.md',
  'docs/protocol.md',
  'docs/tools.md',
  'docs/writing-a-tool.md',
  'docs/security.md',
  'docs/compatibility.md',
  'docs/troubleshooting.md',
  'docs/verification.md',
];

const errors = [];
let linkCount = 0;

const rel = (file) => path.relative(ROOT, file);

function fail(file, message) {
  errors.push(`${rel(file)}: ${message}`);
}

/** Markdown files checked for links: both READMEs plus docs/*.md (not docs/research/). */
async function documentationFiles() {
  const files = [path.join(ROOT, README_EN), path.join(ROOT, README_ZH)];
  const entries = await readdir(DOCS_DIR, { withFileTypes: true });
  for (const entry of entries) {
    if (entry.isFile() && entry.name.endsWith('.md')) {
      files.push(path.join(DOCS_DIR, entry.name));
    }
  }
  return files;
}

async function checkRequiredFiles() {
  for (const relative of REQUIRED_FILES) {
    const full = path.join(ROOT, relative);
    try {
      const info = await stat(full);
      if (!info.isFile()) {
        fail(full, 'exists but is not a regular file');
      }
    } catch {
      fail(full, 'required file is missing');
    }
  }
}

/** Fenced code blocks and inline code never contain real links. */
function stripCode(markdown) {
  return markdown
    .replace(/```[\s\S]*?```/g, '')
    .replace(/~~~[\s\S]*?~~~/g, '')
    .replace(/`[^`\n]*`/g, '');
}

const LINK = /!?\[[^\]]*\]\(\s*(<[^>\n]+>|[^)\s]+)(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)/g;
const EXTERNAL = /^(?:[a-z][a-z0-9+.-]*:|\/\/|#)/i;

function relativeTarget(target) {
  let value = target.trim();
  if (value.startsWith('<') && value.endsWith('>')) {
    value = value.slice(1, -1).trim();
  }
  if (EXTERNAL.test(value)) {
    return null; // http(s):, mailto:, tel:, data:, protocol-relative, in-page anchor
  }
  const withoutFragment = value.split('#')[0].split('?')[0];
  if (withoutFragment === '') {
    return null;
  }
  try {
    return decodeURIComponent(withoutFragment);
  } catch {
    return withoutFragment;
  }
}

async function checkLinksIn(file) {
  const markdown = await readFile(file, 'utf8');
  const text = stripCode(markdown);
  const baseDir = path.dirname(file);
  const seen = new Set();

  for (const match of text.matchAll(LINK)) {
    const target = relativeTarget(match[1]);
    if (!target || seen.has(target)) {
      continue;
    }
    seen.add(target);
    linkCount += 1;

    const resolved = path.resolve(baseDir, target);
    try {
      const info = await stat(resolved);
      if (!info.isFile()) {
        fail(file, `link target is not a file: ${target}`);
      }
    } catch {
      fail(file, `broken relative link: ${target}`);
    }
  }
}

function h2Headings(markdown) {
  return stripCode(markdown)
    .split(/\r?\n/)
    .filter((line) => /^##\s+\S/.test(line))
    .map((line) => line.replace(/^##\s+/, '').trim());
}

async function checkReadmeStructure() {
  const en = path.join(ROOT, README_EN);
  const zh = path.join(ROOT, README_ZH);
  let enText;
  let zhText;
  try {
    enText = await readFile(en, 'utf8');
    zhText = await readFile(zh, 'utf8');
  } catch {
    return; // already reported by checkRequiredFiles
  }

  const enSections = h2Headings(enText);
  const zhSections = h2Headings(zhText);
  if (enSections.length !== zhSections.length) {
    fail(
      zh,
      `H2 section count differs from README.md (${zhSections.length} vs ${enSections.length}); ` +
        'the Chinese README mirrors the English section structure',
    );
  }

  if (!enText.includes('README.zh-CN.md')) {
    fail(en, `does not link to ${README_ZH}`);
  }
  if (!enText.includes('](docs/') && !enText.includes('](docs/README.md')) {
    fail(en, 'does not link to the docs/ directory');
  }
  if (!zhText.includes('README.md')) {
    fail(zh, `does not link back to ${README_EN}`);
  }
}

async function checkLicense() {
  const licenseFile = path.join(ROOT, 'LICENSE');
  const packageFile = path.join(ROOT, 'package.json');
  try {
    const license = await readFile(licenseFile, 'utf8');
    if (!/MIT License/i.test(license)) {
      fail(licenseFile, 'does not contain the "MIT License" header');
    }
  } catch {
    // reported by checkRequiredFiles
  }
  try {
    const pkg = JSON.parse(await readFile(packageFile, 'utf8'));
    if (pkg.license !== 'MIT') {
      fail(packageFile, `license is "${pkg.license}" but the repository is MIT`);
    }
  } catch (error) {
    fail(packageFile, `unreadable package.json: ${error.message}`);
  }
}

async function main() {
  await checkRequiredFiles();
  try {
    await stat(DOCS_DIR);
  } catch {
    fail(DOCS_DIR, 'docs/ directory is missing');
  }

  if (errors.length === 0) {
    const files = await documentationFiles();
    for (const file of files) {
      await checkLinksIn(file);
    }
    await checkReadmeStructure();
    await checkLicense();
  }

  if (errors.length > 0) {
    for (const message of errors) {
      console.error(`FAIL  ${message}`);
    }
    console.error(`\nDocs check failed: ${errors.length} problem(s).`);
    process.exit(1);
  }

  console.log(`Docs check passed: ${REQUIRED_FILES.length} required files, ${linkCount} relative link(s).`);
}

main().catch((error) => {
  console.error(`Docs check crashed: ${error.stack ?? error.message}`);
  process.exit(1);
});
