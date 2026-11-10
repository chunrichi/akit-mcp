#!/usr/bin/env node
/**
 * Minimal MCP client for AKIT MCP endpoints (development / operations helper).
 *
 * The server only speaks MCP over HTTP with SAP ICF authentication, so this
 * script does not depend on any MCP SDK: it performs the initialize handshake
 * once, then sends the requested JSON-RPC call with Basic authentication.
 *
 * Usage:
 *   node scripts/akit-mcp.mjs --url https://<host>:<port>/sap/bc/mcp/dev \
 *        --user <sap-user> [--password <pw>] [--insecure] <command>
 *
 * Commands:
 *   init                      initialize + notifications/initialized
 *   tools                     initialize + tools/list (one line per tool)
 *   call <tool> [json-args]   initialize + tools/call
 *   discover                  modern server/discover
 *   raw <json>                send a raw JSON-RPC request body
 *
 * Options:
 *   --modern                  use the 2026-07-28 protocol era
 *   --timeout <ms>            request timeout (default 30000)
 */
import { createInterface } from 'node:readline/promises';

const args = process.argv.slice(2);

function readOption(name, fallback = '') {
  const index = args.indexOf(name);
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
}

const url = readOption('--url', process.env.AKIT_MCP_URL || '');
const user = readOption('--user', process.env.AKIT_MCP_USER || '');
let password = readOption('--password', process.env.AKIT_MCP_PASSWORD || '');
const insecure = args.includes('--insecure');
const modern = args.includes('--modern');
const timeout = Number(readOption('--timeout', '30000'));

const positionals = args.filter((arg, index) => {
  if (arg.startsWith('--')) return false;
  const previous = args[index - 1];
  return !(previous === '--url' || previous === '--user' || previous === '--password'
    || previous === '--timeout');
});
const command = positionals[0] || 'tools';

if (!url) {
  console.error('error: --url is required (e.g. https://host:port/sap/bc/mcp/dev)');
  process.exit(2);
}

if (insecure) {
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
  console.error('warning: TLS verification disabled (--insecure)');
}

async function askPassword() {
  const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: true });
  const writeToOutput = rl._writeToOutput?.bind(rl);
  rl._writeToOutput = () => {};
  try {
    return await rl.question('SAP password: ');
  } finally {
    rl.close();
    if (writeToOutput) process.stdout.write('\n');
  }
}

if (!password && user && process.stdin.isTTY) {
  password = await askPassword();
}

const authHeader = user
  ? `Basic ${Buffer.from(`${user}:${password}`).toString('base64')}`
  : '';

let nextId = 1;

async function post(body, extraHeaders = {}) {
  const headers = {
    'content-type': 'application/json',
    accept: 'application/json, text/event-stream',
    ...(authHeader ? { authorization: authHeader } : {}),
    ...extraHeaders,
  };
  const response = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(timeout),
  });
  const text = await response.text();
  let json;
  try {
    json = text ? JSON.parse(text) : undefined;
  } catch {
    json = undefined;
  }
  return { status: response.status, text, json };
}

function modernHeaders(method, name) {
  return {
    ...(modern ? { 'mcp-protocol-version': '2026-07-28' } : {}),
    ...(method ? { 'mcp-method': method } : {}),
    ...(name ? { 'mcp-name': name } : {}),
  };
}

function modernMeta() {
  return {
    'io.modelcontextprotocol/protocolVersion': '2026-07-28',
    'io.modelcontextprotocol/clientCapabilities': {},
    'io.modelcontextprotocol/clientInfo': { name: 'akit-mcp-cli', version: '1.0.0' },
  };
}

function show(label, response) {
  console.log(`# ${label} -> HTTP ${response.status}`);
  console.log(response.json ? JSON.stringify(response.json, null, 2) : response.text);
  if (response.status >= 400) process.exitCode = 1;
  if (response.json?.error) process.exitCode = 1;
}

async function initialize() {
  if (modern) {
    const response = await post({
      jsonrpc: '2.0',
      id: nextId++,
      method: 'server/discover',
      params: { _meta: modernMeta() },
    }, modernHeaders('server/discover'));
    show('server/discover', response);
    return;
  }
  const response = await post({
    jsonrpc: '2.0',
    id: nextId++,
    method: 'initialize',
    params: {
      protocolVersion: '2025-11-25',
      capabilities: {},
      clientInfo: { name: 'akit-mcp-cli', version: '1.0.0' },
    },
  }, { 'mcp-protocol-version': '2025-11-25' });
  show('initialize', response);
  if (response.json?.error) return;
  await post({ jsonrpc: '2.0', method: 'notifications/initialized' },
    { 'mcp-protocol-version': '2025-11-25' });
}

async function main() {
  if (command === 'tools' || command === 'call' || command === 'init') {
    await initialize();
  }

  if (command === 'tools') {
    const response = await post({
      jsonrpc: '2.0',
      id: nextId++,
      method: 'tools/list',
      params: modern ? { _meta: modernMeta() } : {},
    }, modernHeaders('tools/list'));
    if (response.json?.result?.tools) {
      console.log(`\n# tools (${response.json.result.tools.length})`);
      for (const tool of response.json.result.tools) {
        console.log(`- ${tool.name}: ${tool.title || ''} — ${tool.description || ''}`);
      }
    } else {
      show('tools/list', response);
    }
    return;
  }

  if (command === 'call') {
    const toolName = positionals[1];
    if (!toolName) {
      console.error('error: call requires a tool name (node scripts/akit-mcp.mjs … call <tool> [json])');
      process.exit(2);
    }
    const rawArguments = positionals[2] || '{}';
    let toolArguments;
    try {
      toolArguments = JSON.parse(rawArguments);
    } catch (error) {
      console.error(`error: arguments are not valid JSON: ${error.message}`);
      process.exit(2);
    }
    const response = await post({
      jsonrpc: '2.0',
      id: nextId++,
      method: 'tools/call',
      params: {
        name: toolName,
        arguments: toolArguments,
        ...(modern ? { _meta: modernMeta() } : {}),
      },
    }, modernHeaders('tools/call', toolName));
    show(`tools/call ${toolName}`, response);
    return;
  }

  if (command === 'discover') {
    const response = await post({
      jsonrpc: '2.0',
      id: nextId++,
      method: 'server/discover',
      params: { _meta: modernMeta() },
    }, modernHeaders('server/discover'));
    show('server/discover', response);
    return;
  }

  if (command === 'raw') {
    const rawBody = positionals[1];
    if (!rawBody) {
      console.error('error: raw requires a JSON-RPC body');
      process.exit(2);
    }
    const response = await post(JSON.parse(rawBody), modernHeaders());
    show('raw', response);
    return;
  }

  if (command === 'init') {
    return;
  }

  console.error(`error: unknown command ${command} (init | tools | call | discover | raw)`);
  process.exit(2);
}

main().catch((error) => {
  console.error(`error: ${error.message}`);
  process.exit(1);
});
