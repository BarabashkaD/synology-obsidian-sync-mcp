const endpoint = process.env.MCP_URL ?? "http://127.0.0.1:8787/mcp";
const token = process.env.MCP_AUTH_TOKEN;
const notePath = `integration/mcp-${Date.now()}.md`;
const initialContent = "# MCP integration test\n\nCreated through MCP.";
const updatedContent = "# MCP integration test\n\nUpdated through MCP.";
let sessionId;
let nextId = 1;

function fail(message) {
  throw new Error(message);
}

function parseResponse(body, contentType) {
  if (!body.trim()) return undefined;
  if (contentType.includes("application/json")) return JSON.parse(body);

  const messages = body
    .split(/\r?\n/)
    .filter((line) => line.startsWith("data:"))
    .map((line) => JSON.parse(line.slice(5).trim()));

  return messages.find((message) => message.id !== undefined) ?? messages.at(-1);
}

async function post(payload, { authorization = token } = {}) {
  const headers = {
    Accept: "application/json, text/event-stream",
    "Content-Type": "application/json",
  };
  if (authorization) headers.Authorization = `Bearer ${authorization}`;
  if (sessionId) headers["Mcp-Session-Id"] = sessionId;

  const response = await fetch(endpoint, {
    method: "POST",
    headers,
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(20_000),
  });
  const body = await response.text();

  return {
    status: response.status,
    sessionId: response.headers.get("mcp-session-id"),
    message: parseResponse(body, response.headers.get("content-type") ?? ""),
    body,
  };
}

async function request(method, params = {}) {
  const id = nextId++;
  const response = await post({ jsonrpc: "2.0", id, method, params });

  if (!response.message) fail(`${method} returned an empty response (${response.status})`);
  if (response.message.id !== id) fail(`${method} returned an unexpected response id`);
  if (response.message.error) {
    fail(`${method} failed: ${JSON.stringify(response.message.error)}`);
  }
  return { result: response.message.result, response };
}

async function callTool(name, args) {
  const { result } = await request("tools/call", { name, arguments: args });
  if (result?.isError) fail(`${name} reported an error: ${JSON.stringify(result.content)}`);
  return result;
}

function resultText(result) {
  return (result?.content ?? [])
    .filter((item) => item.type === "text")
    .map((item) => item.text)
    .join("\n");
}

async function main() {
  if (!token) fail("MCP_AUTH_TOKEN is required");

  const unauthenticated = await post({
    jsonrpc: "2.0",
    id: 0,
    method: "initialize",
    params: {
      protocolVersion: "2025-03-26",
      capabilities: {},
      clientInfo: { name: "integration-test", version: "1.0.0" },
    },
  }, { authorization: null });
  if (![401, 403].includes(unauthenticated.status)) {
    fail(`Unauthenticated MCP request returned ${unauthenticated.status}`);
  }

  const invalidToken = await post({
    jsonrpc: "2.0",
    id: 0,
    method: "initialize",
    params: {
      protocolVersion: "2025-03-26",
      capabilities: {},
      clientInfo: { name: "integration-test", version: "1.0.0" },
    },
  }, { authorization: "invalid-integration-token" });
  if (![401, 403].includes(invalidToken.status)) {
    fail(`Invalid MCP token returned ${invalidToken.status}`);
  }

  const initialized = await request("initialize", {
    protocolVersion: "2025-03-26",
    capabilities: {},
    clientInfo: { name: "integration-test", version: "1.0.0" },
  });
  sessionId = initialized.response.sessionId;
  if (!initialized.result?.serverInfo?.name) fail("initialize omitted serverInfo");

  const notification = await post({
    jsonrpc: "2.0",
    method: "notifications/initialized",
  });
  if (notification.status >= 400) {
    fail(`notifications/initialized returned ${notification.status}`);
  }

  const { result: listed } = await request("tools/list");
  const tools = new Map((listed?.tools ?? []).map((tool) => [tool.name, tool]));
  for (const name of ["write_note", "read_note", "delete_note"]) {
    if (!tools.has(name)) fail(`Required tool is missing: ${name}`);
  }

  for (const name of ["write_note", "read_note", "delete_note"]) {
    const properties = tools.get(name)?.inputSchema?.properties ?? {};
    if (!("path" in properties)) fail(`${name} does not publish a path argument`);
  }
  if (!("content" in (tools.get("write_note")?.inputSchema?.properties ?? {}))) {
    fail("write_note does not publish a content argument");
  }

  let noteCreated = false;
  let primaryError;
  try {
    const written = await callTool("write_note", { path: notePath, content: initialContent });
    if (!resultText(written).includes(`Note saved: ${notePath}`)) fail("write_note did not confirm creation");
    noteCreated = true;
    const created = await callTool("read_note", { path: notePath });
    if (!resultText(created).includes(initialContent)) fail("read_note did not return created content");

    const rewritten = await callTool("write_note", { path: notePath, content: updatedContent });
    if (!resultText(rewritten).includes(`Note saved: ${notePath}`)) fail("write_note did not confirm update");
    const updated = await callTool("read_note", { path: notePath });
    if (!resultText(updated).includes(updatedContent)) fail("read_note did not return updated content");
  } catch (error) {
    primaryError = error;
  } finally {
    if (noteCreated) {
      try {
        const removed = await callTool("delete_note", { path: notePath });
        if (!resultText(removed).includes(`Deleted: ${notePath}`)) fail("delete_note did not confirm deletion");
      } catch (cleanupError) {
        if (!primaryError) throw cleanupError;
        console.error(`[MCP TEST] Cleanup also failed: ${cleanupError}`);
      }
    }
  }
  if (primaryError) throw primaryError;

  const deleted = await callTool("read_note", { path: notePath });
  if (!resultText(deleted).includes(`Note not found: ${notePath}`)) {
    fail("read_note did not confirm that the note was deleted");
  }

  console.log(`[MCP TEST] Passed against ${initialized.result.serverInfo.name}`);
}

await main();
