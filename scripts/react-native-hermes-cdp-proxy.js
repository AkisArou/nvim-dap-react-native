#!/usr/bin/env node

import { createServer } from "node:http";
import process from "node:process";
import WebSocket, { WebSocketServer } from "ws";
import connectionModule from "vscode-cdp-proxy/dist/connection.js";
import transportModule from "vscode-cdp-proxy/dist/transports/websocket.js";

const { Connection } = connectionModule;
const { WebSocketTransport } = transportModule;

const CDP_API_NAMES = {
  DEBUGGER_SET_BREAKPOINT: "Debugger.setBreakpoint",
  RUNTIME_CALL_FUNCTION_ON: "Runtime.callFunctionOn",
  DEBUGGER_PAUSED: "Debugger.paused",
  RUNTIME_CONSOLE_API_CALLED: "Runtime.consoleAPICalled",
};

const HERMES_NATIVE_FUNCTION_NAME = "(native)";
const HERMES_NATIVE_FUNCTION_SCRIPT_ID = "4294967295";
const CLOSE_TIMEOUT_MS = 1000;

function parseArgs(argv) {
  const args = {};

  for (let index = 2; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key.startsWith("--")) {
      continue;
    }

    const name = key.slice(2);
    const next = argv[index + 1];
    if (!next || next.startsWith("--")) {
      args[name] = true;
      continue;
    }

    args[name] = next;
    index += 1;
  }

  return args;
}

function log(level, message, details) {
  const payload = {
    level,
    message,
    details,
    time: new Date().toISOString(),
  };

  process.stderr.write(`${JSON.stringify(payload)}\n`);
}

function requiredString(args, key) {
  const value = args[key];
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`Missing required --${key}`);
  }

  return value;
}

function requiredPort(args, key) {
  const value = Number(requiredString(args, key));
  if (!Number.isInteger(value) || value < 0 || value > 65535) {
    throw new Error(`--${key} must be a TCP port`);
  }

  return value;
}

function formatWebSocketHost(host) {
  return host.includes(":") && !host.startsWith("[") ? `[${host}]` : host;
}

async function createDebuggerServer({ host, port }) {
  const httpServer = createServer((_request, response) => {
    const address = httpServer.address();
    const resolvedPort = typeof address === "object" && address ? address.port : port;
    const wsHost = formatWebSocketHost(host);

    response.end(
      JSON.stringify({
        webSocketDebuggerUrl: `ws://${wsHost}:${resolvedPort}/ws`,
      }),
    );
  });
  const webSocketServer = new WebSocketServer({ server: httpServer });

  await new Promise((resolve, reject) => {
    const cleanup = () => {
      httpServer.off("error", onError);
      httpServer.off("listening", onListening);
    };
    const onError = (error) => {
      cleanup();
      reject(error);
    };
    const onListening = () => {
      cleanup();
      resolve();
    };

    httpServer.once("error", onError);
    httpServer.once("listening", onListening);
    httpServer.listen(port, host);
  });

  return {
    address: httpServer.address(),
    onConnection(callback) {
      webSocketServer.on("connection", (ws, request) => {
        callback([new Connection(new WebSocketTransport(ws)), request]);
      });
    },
    dispose() {
      for (const client of webSocketServer.clients) {
        client.close();
      }
      webSocketServer.close();
      httpServer.close();
    },
  };
}

// Ported from microsoft/vscode-react-native
// src/cdp-proxy/CDPMessageHandlers/hermesCDPMessageHandler.ts
// Upstream commit checked: a8dca181d7afb03f98efeaf35c18c185a8f8d43e
function processDebuggerCDPMessage(event) {
  let sendBack = false;

  if (event.method === CDP_API_NAMES.DEBUGGER_SET_BREAKPOINT) {
    event = handleBreakpointSetting(event);
  } else if (event.method === CDP_API_NAMES.RUNTIME_CALL_FUNCTION_ON) {
    event = handleCallFunctionOnEvent(event);
    sendBack = true;
  }

  return { event, sendBack };
}

// Ported from microsoft/vscode-react-native
// src/cdp-proxy/CDPMessageHandlers/hermesCDPMessageHandler.ts
function processApplicationCDPMessage(event) {
  if (event.method === CDP_API_NAMES.DEBUGGER_PAUSED) {
    event = handlePausedEvent(event);
  } else if (event.result?.result) {
    event = handleFunctionTypeResult(event);
  }

  if (
    event.method === CDP_API_NAMES.RUNTIME_CONSOLE_API_CALLED &&
    String(event.params?.args?.[0]?.value).includes("You are using an unsupported debugging client")
  ) {
    event.params.args[0].value = "";
  }

  return { event, sendBack: false };
}

function handleCallFunctionOnEvent(event) {
  return {
    result: {
      result: {
        objectId: event.params?.objectId,
      },
    },
    id: event.id,
  };
}

function handleFunctionTypeResult(event) {
  if (Array.isArray(event.result.result)) {
    for (const resultObject of event.result.result) {
      if (
        resultObject.value &&
        resultObject.value.type === "function" &&
        !resultObject.value.description
      ) {
        resultObject.value.description = "function() { ... }";
      }
    }
  }

  return event;
}

function handlePausedEvent(event) {
  const callFrames = Array.isArray(event.params?.callFrames) ? event.params.callFrames : [];

  event.params.callFrames = callFrames.filter(
    (callFrame) =>
      callFrame.functionName !== HERMES_NATIVE_FUNCTION_NAME &&
      callFrame.location?.scriptId !== HERMES_NATIVE_FUNCTION_SCRIPT_ID,
  );

  return event;
}

function handleBreakpointSetting(event) {
  if (event.params?.location) {
    delete event.params.location.columnNumber;
  }

  return event;
}

function send(target, event) {
  if (!target) {
    return;
  }

  try {
    target.send(event);
  } catch (error) {
    log("warn", "failed to forward CDP message", {
      id: event?.id,
      method: event?.method,
      message: error?.message || String(error),
    });
  }
}

async function connectToHermes(websocketUrl, origin) {
  const ws = new WebSocket(websocketUrl, [], {
    headers: {
      Origin: origin,
    },
    perMessageDeflate: false,
    maxPayload: 256 * 1024 * 1024,
  });

  await new Promise((resolve, reject) => {
    ws.once("open", resolve);
    ws.once("error", reject);
  });

  return new Connection(new WebSocketTransport(ws));
}

async function closeQuietly(target) {
  if (!target) {
    return;
  }

  let timeoutId;
  const timeout = new Promise((resolve) => {
    timeoutId = setTimeout(resolve, CLOSE_TIMEOUT_MS);
  });

  try {
    await Promise.race([target.close(), timeout]);
  } catch {
    // Shutdown is best effort; the owning DAP session is already ending.
  } finally {
    clearTimeout(timeoutId);
  }
}

async function main() {
  const args = parseArgs(process.argv);
  const host = args.host || "127.0.0.1";
  const port = requiredPort(args, "port");
  const websocketUrl = requiredString(args, "websocket-url");
  const origin = requiredString(args, "origin");
  const label = args.label || "React Native Hermes";

  let currentDebuggerTarget = null;
  let currentApplicationTarget = null;
  let connectionToken = 0;

  const server = await createDebuggerServer({ host, port });
  const address = server.address;
  const resolvedHost = typeof address === "object" && address ? address.address : host;
  const resolvedPort = typeof address === "object" && address ? address.port : port;

  log("info", "ready", { host: resolvedHost, port: resolvedPort, label });

  server.onConnection(async ([debuggerTarget, request]) => {
    if (request.headers.origin) {
      log("warn", "rejected websocket connection with origin header", {
        origin: request.headers.origin,
      });
      await closeQuietly(debuggerTarget);
      return;
    }

    const token = connectionToken + 1;
    connectionToken = token;

    const isCurrentConnection = () =>
      token === connectionToken && currentDebuggerTarget === debuggerTarget;

    await closeQuietly(currentDebuggerTarget);
    await closeQuietly(currentApplicationTarget);

    currentDebuggerTarget = debuggerTarget;
    currentApplicationTarget = null;

    let applicationTarget = null;

    try {
      debuggerTarget.pause();
      applicationTarget = await connectToHermes(websocketUrl, origin);

      if (!isCurrentConnection()) {
        await closeQuietly(applicationTarget);
        await closeQuietly(debuggerTarget);
        return;
      }

      currentApplicationTarget = applicationTarget;

      debuggerTarget.onCommand((event) => {
        const processed = processDebuggerCDPMessage(event);
        send(processed.sendBack ? debuggerTarget : applicationTarget, processed.event);
      });

      debuggerTarget.onReply((event) => {
        const processed = processDebuggerCDPMessage(event);
        send(processed.sendBack ? debuggerTarget : applicationTarget, processed.event);
      });

      applicationTarget.onCommand((event) => {
        const processed = processApplicationCDPMessage(event);
        send(processed.sendBack ? applicationTarget : debuggerTarget, processed.event);
      });

      applicationTarget.onReply((event) => {
        const processed = processApplicationCDPMessage(event);
        send(processed.sendBack ? applicationTarget : debuggerTarget, processed.event);
      });

      applicationTarget.onError((error) => {
        log("error", "application target error", { message: error.message });
      });

      debuggerTarget.onError((error) => {
        log("error", "debugger target error", { message: error.message });
      });

      applicationTarget.onEnd(() => {
        if (currentApplicationTarget === applicationTarget) {
          currentApplicationTarget = null;
        }
        void closeQuietly(debuggerTarget);
      });

      debuggerTarget.onEnd(() => {
        if (currentDebuggerTarget === debuggerTarget) {
          currentDebuggerTarget = null;
        }
        void closeQuietly(applicationTarget);
      });

      debuggerTarget.unpause();
    } catch (error) {
      log("error", "failed to connect proxy targets", {
        message: error?.message || String(error),
      });
      await closeQuietly(debuggerTarget);
      await closeQuietly(applicationTarget);

      if (isCurrentConnection()) {
        currentDebuggerTarget = null;
        if (currentApplicationTarget === applicationTarget) {
          currentApplicationTarget = null;
        }
      }
    }
  });

  async function shutdown() {
    await closeQuietly(currentDebuggerTarget);
    await closeQuietly(currentApplicationTarget);
    server.dispose();
  }

  process.once("SIGTERM", () => {
    void shutdown().finally(() => process.exit(0));
  });

  process.once("SIGINT", () => {
    void shutdown().finally(() => process.exit(0));
  });
}

main().catch((error) => {
  log("error", "fatal", { message: error?.message || String(error) });
  process.exit(1);
});
