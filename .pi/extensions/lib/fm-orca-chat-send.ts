// Orca native-chat wake delivery: the one place Firstmate speaks Orca's
// internal structured-session RPC.
//
// Why it exists: Orca's native chat runs an omp primary as `omp acp`, and omp's
// ACP mode refuses to start any agent-initiated turn while the client has no
// session/prompt in flight (acp-client-bridge.ts deferAgentInitiatedTurns). A
// watcher follow-up sent while main is idle is therefore parked until the
// captain types again, and Orca never shows a turn it did not start. Handing
// the wake to Orca instead makes Orca itself send the prompt, so the turn runs
// and appears in the chat like a typed message.
//
// Contract used (verified against Orca 1.4.254; re-verify after an Orca update):
//   - Orca injects ORCA_STRUCTURED_SESSION=1 and ORCA_AGENT_SESSION_ID=<chat id>
//     into a chat agent's environment; omp's ACP mode runs as `omp acp`.
//   - ${ORCA_USER_DATA_PATH:-${XDG_CONFIG_HOME:-~/.config}/orca}/orca-runtime.json
//     names a unix-socket transport and the runtime authToken (the `orca` CLI
//     reads the same file); requests are one NDJSON line
//     {id, authToken, method, params}, replies are {id, ok, result|error} with
//     {_keepalive} frames in between.
//   - Method agentSession.send, params {envelope, delivery, body}:
//     envelope {sessionId, clientOperationId: <13-digit ms>-<32 hex>,
//     expectedRuntimeFence: <fence>|null, payloadFingerprint}, body
//     {kind:"message", role:"user", blocks:[{type:"text", text}]}.
//     delivery "queue-if-active" waits behind a running turn; omitting it
//     steers, which aborts the running turn, so it is never omitted here.
//   - payloadFingerprint is sha256 hex of the canonical JSON (keys sorted,
//     undefined dropped) of {method, sessionId, fields:{body, delivery}}.
//   - A success is result {ok:true, fence, value:{clientMessageId,
//     submission|queued}}: submission means sent now, queued means waiting
//     behind the running turn. A stale fence refusal carries currentFence.
//
// Re-apply after an Orca update that breaks it (the error text points here):
//   1. Mount the new AppImage and search resources/app.asar.unpacked/out for
//      `agentSession.send` (the RPC registration and its params schema live in
//      main/chunks and shared/rpc-contract), `queue-if-active`, and
//      structuredAgentSessionPayloadFingerprint; update the constants and
//      reply parsing above and below to match.
//   2. Re-run FM_OMP_ORCA_CHAT_LIVE=1 tests/fm-omp-orca-chat-live-e2e.test.sh,
//      which opens a throwaway Orca chat, proves an idle chat runs a delivered
//      wake, and removes the throwaway workspace.
import { createHash, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { createConnection } from "node:net";

export type OrcaChatTarget = {
  sessionId: string;
  metadataPath: string;
};

export type OrcaChatSendOutcome = "sent" | "queued";

export class OrcaChatSendError extends Error {
  constructor(detail: string) {
    super(
      `Orca chat wake delivery failed: ${detail}. Orca's agentSession.send contract may have changed; ` +
        "re-verify per the header of .pi/extensions/lib/fm-orca-chat-send.ts.",
    );
    this.name = "OrcaChatSendError";
  }
}

const sendMethod = "agentSession.send";
const delivery = "queue-if-active";
const defaultTimeoutMs = 15_000;
// The fence Orca last reported per chat; sends accept null, and a stale-fence
// refusal is answered by one retry with the fence it reports.
const knownFence = new Map<string, number>();

// The Orca chat this process serves, or null outside Orca's native chat. The
// acp argument keeps a terminal omp that merely inherited the chat's
// environment from posting into that chat.
export function orcaChatTarget(
  env: NodeJS.ProcessEnv = process.env,
  argv: readonly string[] = process.argv,
): OrcaChatTarget | null {
  const sessionId = env.ORCA_AGENT_SESSION_ID ?? "";
  if (env.ORCA_STRUCTURED_SESSION !== "1" || sessionId === "" || argv[2] !== "acp") return null;
  const dataDir = env.ORCA_USER_DATA_PATH || `${env.XDG_CONFIG_HOME || `${env.HOME ?? ""}/.config`}/orca`;
  return { sessionId, metadataPath: `${dataDir}/orca-runtime.json` };
}

function canonicalize(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value ?? null);
  if (Array.isArray(value)) return `[${value.map(canonicalize).join(",")}]`;
  const entries = Object.entries(value)
    .filter(([, entry]) => entry !== undefined)
    .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0));
  return `{${entries.map(([key, entry]) => `${JSON.stringify(key)}:${canonicalize(entry)}`).join(",")}}`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

type RuntimeMetadata = { endpoint: string; authToken: string };

function readRuntimeMetadata(path: string): RuntimeMetadata {
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new OrcaChatSendError(`could not read Orca runtime metadata ${path} (${error instanceof Error ? error.message : String(error)})`);
  }
  if (!isRecord(parsed) || typeof parsed.authToken !== "string" || !Array.isArray(parsed.transports)) {
    throw new OrcaChatSendError(`Orca runtime metadata ${path} has no authToken and transports`);
  }
  const unix = parsed.transports.find(
    (transport): transport is { kind: "unix"; endpoint: string } =>
      isRecord(transport) && transport.kind === "unix" && typeof transport.endpoint === "string",
  );
  if (!unix) throw new OrcaChatSendError(`Orca runtime metadata ${path} names no unix-socket transport`);
  return { endpoint: unix.endpoint, authToken: parsed.authToken };
}

function rpcRequest(metadata: RuntimeMetadata, params: unknown, timeoutMs: number): Promise<Record<string, unknown>> {
  return new Promise((resolveRequest, rejectRequest) => {
    const id = randomUUID();
    const socket = createConnection(metadata.endpoint);
    let buffered = "";
    let settled = false;
    const finish = (error: OrcaChatSendError | null, frame?: Record<string, unknown>) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      if (error) rejectRequest(error);
      else if (frame) resolveRequest(frame);
    };
    const timer = setTimeout(
      () => finish(new OrcaChatSendError(`Orca did not answer ${sendMethod} within ${timeoutMs}ms`)),
      timeoutMs,
    );
    socket.setEncoding("utf8");
    socket.on("error", (error) => finish(new OrcaChatSendError(`could not reach Orca's runtime socket ${metadata.endpoint} (${error.message})`)));
    socket.on("close", () => finish(new OrcaChatSendError("Orca closed the runtime connection before answering")));
    socket.on("data", (chunk: string) => {
      buffered += chunk;
      let newline = buffered.indexOf("\n");
      while (newline >= 0 && !settled) {
        const line = buffered.slice(0, newline);
        buffered = buffered.slice(newline + 1);
        newline = buffered.indexOf("\n");
        let frame: unknown;
        try {
          frame = JSON.parse(line);
        } catch {
          finish(new OrcaChatSendError("Orca returned a reply line that is not JSON"));
          return;
        }
        if (isRecord(frame) && "_keepalive" in frame) continue;
        if (!isRecord(frame) || frame.id !== id) {
          finish(new OrcaChatSendError("Orca returned a reply frame for a different request"));
          return;
        }
        finish(null, frame);
      }
    });
    socket.on("connect", () => {
      socket.write(`${JSON.stringify({ id, authToken: metadata.authToken, method: sendMethod, params })}\n`);
    });
  });
}

function sendParams(sessionId: string, text: string, fence: number | null): Record<string, unknown> {
  const body = { kind: "message", role: "user", blocks: [{ type: "text", text }] };
  const payloadFingerprint = createHash("sha256")
    .update(canonicalize({ method: sendMethod, sessionId, fields: { body, delivery } }))
    .digest("hex");
  return {
    envelope: {
      sessionId,
      clientOperationId: `${Date.now()}-${randomUUID().replaceAll("-", "")}`,
      expectedRuntimeFence: fence,
      payloadFingerprint,
    },
    delivery,
    body,
  };
}

function describe(value: unknown): string {
  const text = JSON.stringify(value);
  return text === undefined ? String(value) : text.length > 400 ? `${text.slice(0, 400)}...` : text;
}

// Deliver one user message to the Orca chat: "sent" when the idle chat started
// it now, "queued" when it waits behind the running turn. Throws
// OrcaChatSendError on any refusal, transport failure, or unrecognized reply.
export async function sendToOrcaChat(
  target: OrcaChatTarget,
  text: string,
  timeoutMs = defaultTimeoutMs,
): Promise<OrcaChatSendOutcome> {
  const metadata = readRuntimeMetadata(target.metadataPath);
  let fence = knownFence.get(target.sessionId) ?? null;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const frame = await rpcRequest(metadata, sendParams(target.sessionId, text, fence), timeoutMs);
    if (frame.ok !== true) {
      throw new OrcaChatSendError(`Orca rejected ${sendMethod}: ${describe(frame.error)}`);
    }
    const result = frame.result;
    if (!isRecord(result)) throw new OrcaChatSendError(`unrecognized ${sendMethod} reply ${describe(frame)}`);
    if (result.ok === false) {
      const refusal = isRecord(result.refusal) ? result.refusal : {};
      const details = isRecord(refusal.details) ? refusal.details : {};
      const current = refusal.currentFence ?? details.currentFence;
      if (attempt === 0 && refusal.code === "agent_session_checkpoint_stale" && typeof current === "number") {
        knownFence.set(target.sessionId, current);
        fence = current;
        continue;
      }
      throw new OrcaChatSendError(`Orca refused the message: ${describe(result.refusal)}`);
    }
    const value = result.ok === true && isRecord(result.value) ? result.value : null;
    if (!value || (!isRecord(value.submission) && !isRecord(value.queued))) {
      throw new OrcaChatSendError(`unrecognized ${sendMethod} reply ${describe(result)}`);
    }
    if (typeof result.fence === "number") knownFence.set(target.sessionId, result.fence);
    return isRecord(value.queued) ? "queued" : "sent";
  }
  throw new OrcaChatSendError("Orca kept reporting a stale conversation fence");
}
