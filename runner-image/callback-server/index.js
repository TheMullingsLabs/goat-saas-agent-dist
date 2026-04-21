/**
 * Runner VM callback server — receives gate responses and the initial
 * provisioning payload (secrets + config) from the MCP server, then
 * launches the goat-saas-agent pipeline locally.
 *
 * Runs on a random port and writes its port to /tmp/goat-runner-callback-port.
 */

import express from "express";
import { spawn, execSync } from "child_process";
import { promises as fs, writeFileSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { homedir } from "os";
import { timingSafeEqual } from "crypto";

const WORKDIR = "/opt/goat-runner/workspace";
const CONFIG_DIR = path.join(WORKDIR, "config");

// Module-level callback port. Set by the listen callback in script mode and
// readable by provisionAndRun() when it spawns the agent.
let LISTEN_PORT = 0;

const app = express();
app.use(express.json({ limit: "5mb" }));

function bearer(req) {
  const h = req.headers.authorization || "";
  return h.startsWith("Bearer ") ? h.slice(7) : "";
}

function requireRunnerToken(req, res, next) {
  const expected = process.env.GOAT_RUNNER_TOKEN || "";
  if (!expected) {
    res.status(503).json({ error: "Runner token not configured" });
    return;
  }

  const provided = bearer(req);
  if (!provided) {
    res.status(401).json({ error: "Runner token required" });
    return;
  }

  const expectedBuf = Buffer.from(expected, "utf-8");
  const providedBuf = Buffer.from(provided, "utf-8");
  if (expectedBuf.length !== providedBuf.length || !timingSafeEqual(expectedBuf, providedBuf)) {
    res.status(401).json({ error: "Invalid runner token" });
    return;
  }

  next();
}

/**
 * Each gate has TWO halves on the runner:
 *   1. The agent pipeline POSTs /agent/wait-gate (long poll). The Express
 *      response object is parked in `waiters` keyed by gateId.
 *   2. The MCP server later POSTs /gate-response with the operator's answer.
 *      That handler looks up the parked response and writes the answer back.
 *
 * If /gate-response arrives BEFORE /agent/wait-gate (race), the answer is
 * stashed in `pendingResponses` and replayed when the agent finally polls.
 */
const waiters = new Map();          // gateId -> Express res object (parked)
const pendingResponses = new Map(); // gateId -> { response, operatorAnswer }

/**
 * POST /agent/wait-gate — long-polled by the agent process when it hits a gate.
 * Holds the HTTP response open until /gate-response arrives. No timeout —
 * operators can take hours to respond.
 */
app.post("/agent/wait-gate", (req, res) => {
  const { gateId } = req.body || {};
  if (!gateId) {
    res.status(400).json({ error: "gateId is required" });
    return;
  }

  // Replay path: response already arrived
  const stashed = pendingResponses.get(gateId);
  if (stashed) {
    pendingResponses.delete(gateId);
    res.json(stashed);
    return;
  }

  // Park the response object — will be released by /gate-response.
  // Use res.on("close"), NOT req.on("close"): the request "close" event
  // fires as soon as the body is fully received, which is immediately for a
  // small JSON payload — that would tear down the parked entry before the
  // operator could ever respond. The response "close" event fires when the
  // long-poll connection actually closes (operator disconnects, callback
  // server shutdown, etc.), which is what we actually want to clean up on.
  waiters.set(gateId, res);
  res.on("close", () => {
    if (waiters.get(gateId) === res) waiters.delete(gateId);
  });
});

/**
 * POST /gate-response — receive gate response from MCP server.
 * Authenticated with the per-runner GOAT_RUNNER_TOKEN because the callback
 * port may be reachable over the network. Releases any parked /agent/wait-gate
 * response, or stashes the answer for replay if the agent hasn't polled yet.
 */
app.post("/gate-response", requireRunnerToken, (req, res) => {
  const { gateId, response, operatorAnswer } = req.body;

  if (!gateId || !response) {
    res.status(400).json({ error: "gateId and response are required" });
    return;
  }

  const parked = waiters.get(gateId);
  if (parked) {
    waiters.delete(gateId);
    parked.json({ response, operatorAnswer });
  } else {
    // Race: stash for the agent to pick up when it polls
    pendingResponses.set(gateId, { response, operatorAnswer });
  }
  res.json({ success: true });
});

/**
 * POST /provision-config — receive secrets + config and start the pipeline.
 * Authenticated with the per-runner GOAT_RUNNER_TOKEN even though cloud-init
 * posts over loopback. This keeps the endpoint safe if the callback port is
 * accidentally exposed beyond localhost.
 * Body shape (from MCP server's /runners/:id/register response):
 *   { buildId, githubRepo, config: { app, agent, integrations },
 *     secrets: { anthropicApiKey, githubPat, dbPassword, goatSaasApiKey },
 *     pipelineArgs }
 */
app.post("/provision-config", requireRunnerToken, async (req, res) => {
  const { buildId, githubRepo, config, secrets, pipelineArgs } = req.body || {};
  if (!buildId || !githubRepo || !config || !secrets) {
    res.status(400).json({ error: "buildId, githubRepo, config, and secrets are required" });
    return;
  }

  res.json({ success: true, status: "starting" });

  // Run provisioning asynchronously so we don't block the HTTP response.
  provisionAndRunImpl({ buildId, githubRepo, config, secrets, pipelineArgs }).catch((err) => {
    console.error("[provision] failed:", err);
    reportStatus("destroyed").catch(() => {});
  });
});

let provisionAndRunImpl = provisionAndRun;

async function provisionAndRun({ buildId, githubRepo, config, secrets, pipelineArgs }) {
  await reportStatus("cloning");

  // 1. Clean workspace
  await fs.rm(WORKDIR, { recursive: true, force: true });
  await fs.mkdir(WORKDIR, { recursive: true });

  // 2. Clone the repo using the github PAT
  const cloneUrl = `https://x-access-token:${secrets.githubPat}@github.com/${githubRepo}.git`;
  await runCommand("git", ["clone", "--depth", "1", cloneUrl, WORKDIR], {});

  // 3. Write config files (frontmatter YAML — agent reads via gray-matter).
  //    vercel-team-id arrives in config.integrations from the operator's
  //    integrations.md (it's not a secret — it's a public Vercel project ID).
  await fs.mkdir(CONFIG_DIR, { recursive: true });
  await writeConfigFile(path.join(CONFIG_DIR, "app.md"), config.app || {});
  await writeConfigFile(path.join(CONFIG_DIR, "agent.md"), config.agent || {});
  await writeConfigFile(path.join(CONFIG_DIR, "integrations.md"), config.integrations || {});

  // 4. Write secrets.md with 0o600 permissions.
  const secretsFields = {
    "anthropic-api-key": secrets.anthropicApiKey,
    "github-pat": secrets.githubPat,
    "db-password": secrets.dbPassword || "",
    "vercel-token": secrets.vercelToken || "",
  };
  const secretsPath = path.join(CONFIG_DIR, "secrets.md");
  await writeConfigFile(secretsPath, secretsFields);
  await fs.chmod(secretsPath, 0o600);

  // 4b/c. Configure git identity (so bootstrap doesn't prompt) and set up
  //       gh as the credential helper so subsequent git push calls use
  //       GH_TOKEN from env instead of persisting the PAT in .git/config.
  //       See configureGitCredentials() for the full sequence.
  await configureGitCredentials({
    workdir: WORKDIR,
    githubRepo,
    githubPat: secrets.githubPat,
  });

  // 4d. Pre-write a placeholder .env.local so bootstrap does not prompt for DB
  //     configuration. The runner uses the local PostgreSQL installed by
  //     setup.sh; the agent will read from secrets.md for the password.
  const envLocalPath = path.join(WORKDIR, ".env.local");
  if (!(await fileExists(envLocalPath))) {
    const dbName = (config.app && config.app["app-name"]) || "goat_saas_app";
    await fs.writeFile(
      envLocalPath,
      [
        `DATABASE_URL=postgresql://postgres:${secrets.dbPassword || "postgres"}@localhost:5432/${dbName}`,
        `PGHOST=localhost`,
        `PGPORT=5432`,
        `PGDATABASE=${dbName}`,
        `PGUSER=postgres`,
        `PGPASSWORD=${secrets.dbPassword || "postgres"}`,
      ].join("\n") + "\n",
      "utf-8",
    );
    await fs.chmod(envLocalPath, 0o600);
  }

  // 5. Write ~/.goat-saas-agent/credentials.json so the agent can validate
  //    its license and report build events to the MCP server. Also log into
  //    Claude Code by setting ANTHROPIC_API_KEY in the spawn environment.
  //    Both are best-effort — if either fails, the pipeline continues (the
  //    build reporter is fire-and-forget and the license check may still pass
  //    if credentials.json was baked into the snapshot image).
  const mcpServerUrl = process.env.GOAT_MCP_SERVER_URL || "";
  if (secrets.goatSaasApiKey && mcpServerUrl) {
    await writeAgentCredentials(secrets.goatSaasApiKey, mcpServerUrl);
  }

  // 5. Run the pipeline. Args and env are built by pure helpers
  //    (buildSpawnArgs / buildSpawnEnv) so they can be unit-tested without
  //    actually spawning the agent.
  //
  // Cycle 21-1 — agent stdout+stderr is piped through a line-buffered sink
  // that POSTs chunks to MCP's /runners/:id/log endpoint. The operator can
  // then fetch the log remotely with `goat-saas-agent runner-log <id>`,
  // which is the only practical way to debug a failed runner — ufw blocks
  // SSH from arbitrary IPs and the DO web console requires a password
  // reset that's cumbersome mid-debug. Lines are also tee'd to
  // /var/log/goat-callback.log via console.log so SSH-based debugging
  // remains a fallback when it works.
  await reportStatus("running");

  // Cycle 22 (prompt #7): heartbeat — re-POST status=running every 60s so
  // the MCP sweep job doesn't misclassify the runner as idle during long
  // Claude Code spawns. Without this, the status table shows "idle" while
  // the agent is actively generating code, which is misleading. The
  // heartbeat is best-effort — failures are silently swallowed.
  const HEARTBEAT_INTERVAL_MS = 60_000;
  const heartbeat = setInterval(() => {
    reportStatus("running").catch(() => {});
  }, HEARTBEAT_INTERVAL_MS);

  const args = buildSpawnArgs(pipelineArgs);
  const spawnEnv = buildSpawnEnv({
    baseEnv: process.env,
    callbackPort: LISTEN_PORT,
    buildId,
    githubPat: secrets.githubPat,
    anthropicApiKey: secrets.anthropicApiKey,
  });
  const logSink = buildLogSink({
    url: process.env.GOAT_MCP_SERVER_URL,
    instanceId: process.env.GOAT_RUNNER_INSTANCE_ID,
    token: process.env.GOAT_RUNNER_TOKEN,
  });
  // Cycle 21-1-1 — resolve the agent binary by absolute path.
  const agentBinary = resolveAgentBinary(spawnEnv);
  let exit;
  try {
    exit = await runAgentWithLogSink(
      agentBinary,
      args,
      { cwd: WORKDIR, env: spawnEnv },
      logSink,
    );
  } finally {
    clearInterval(heartbeat);
  }

  // Cycle 22: bulk-push the local log file to MCP as a fallback for when
  // the per-line Replit DB appends fail (which happens every time the Replit
  // DB token is invalid — observed 3 times in 48 hours). The local log file
  // at /var/log/goat-callback.log always has the full output because
  // runAgentWithLogSink tees every line to console.log.
  try {
    const { readFileSync: readLog } = await import("fs");
    const localLog = readLog("/var/log/goat-callback.log", "utf-8").split("\n").filter(l => l.trim());
    if (localLog.length > 0) {
      // Cap at 200 lines (LOG_RING_CAP) — take the last 200
      const capped = localLog.length > 200 ? localLog.slice(localLog.length - 200) : localLog;
      await logSink(capped);
    }
  } catch {
    // Best-effort — if the local log doesn't exist or the push fails, continue
  }

  // Early-wipe secrets.md immediately on agent exit (before status report).
  // Extracted to wipeSecretsAfterAgent() for testability.
  await wipeSecretsAfterAgent(secretsPath);

  await reportStatus(exit === 0 ? "idle" : "destroyed");
}

export function setProvisionAndRunImplementationForTests(fn) {
  provisionAndRunImpl = fn || provisionAndRun;
}

/**
 * Build the CLI argument array for spawning `goat-saas-agent run` on a
 * remote runner. Always includes --skip-codex --sync-state --no-update-check
 * and the analysis model. Optional flags are controlled by pipelineArgs.
 *
 * --no-update-check is required on headless runners: the update check prompts
 * interactively ("Update now? [y/N]") which would block indefinitely on a VM
 * with no attached terminal.
 *
 * Pure function — no side effects — so tests can assert the exact arg list.
 */
export function buildSpawnArgs(pipelineArgs = {}) {
  const args = ["run", "--skip-codex", "--sync-state", "--no-update-check", "--analysis-model", "claude-sonnet-4-6"];
  if (pipelineArgs.autoApprove) args.push("--auto-approve");
  if (pipelineArgs.force) args.push("--force");
  if (pipelineArgs.sequentialAnalysis) args.push("--sequential-analysis");
  if (pipelineArgs.skipPrototype) args.push("--skip-prototype");
  if (pipelineArgs.optimizeCost) args.push("--optimize-cost");
  if (pipelineArgs.fromStep) args.push("--from-step", pipelineArgs.fromStep);
  if (pipelineArgs.oneStep) args.push("--one-step", pipelineArgs.oneStep);
  return args;
}

/**
 * Cycle 21-1-1 — Resolve the goat-saas-agent binary path. install.sh writes
 * the binary to ${HOME}/.local/bin/goat-saas-agent and appends that dir to
 * the user's shell rc file. cloud-init's `nohup node callback-server/...`
 * does NOT source .bashrc, so the callback server's PATH does not include
 * the install dir, and `spawn("goat-saas-agent", ...)` returns ENOENT.
 *
 * This helper checks the known install paths in priority order and returns
 * the first one that exists. Falls back to the bare name if none of the
 * candidate paths exist — that lets a future install location still work
 * via PATH lookup.
 *
 * Pure function — takes an env object so tests can inject a fake HOME.
 * Exported for testability.
 */
import { existsSync as fsExistsSync } from "fs";

export function resolveAgentBinary(env = process.env, exists = fsExistsSync) {
  const home = env.HOME || "/root";
  const candidates = [
    path.posix.join(home, ".local", "bin", "goat-saas-agent"),
    "/root/.local/bin/goat-saas-agent",
    "/usr/local/bin/goat-saas-agent",
    "/usr/bin/goat-saas-agent",
  ];
  for (const c of candidates) {
    if (exists(c)) return c;
  }
  // Last resort — bare name. Lets the callback server still work if some
  // future runner image installs the binary somewhere we don't know about
  // AND has it on PATH. If it ENOENTs, the runAgentWithLogSink error
  // handler captures the spawn error in the log channel — making the
  // failure visible (cycle 21-1).
  return "goat-saas-agent";
}

/**
 * Build the env var object for spawning `goat-saas-agent run`. Copies the
 * base process.env and overlays the runner-specific vars the agent needs:
 *   - GOAT_REMOTE=1 enables runner-mode detection
 *   - GOAT_CALLBACK_PORT tells the agent's RemoteGateHandler where to long-poll
 *   - GOAT_SAAS_BUILD_ID is the MCP-side buildId (fixes the build ID schism)
 *   - GH_TOKEN is the GitHub PAT for gh credential helper
 *   - ANTHROPIC_API_KEY enables Claude Code to authenticate without interactive login
 *
 * Pure function — takes the base env + runner config, returns a new object.
 */
export function buildSpawnEnv({ baseEnv, callbackPort, buildId, githubPat, anthropicApiKey }) {
  // Cycle 21-1-1 — also prepend ~/.local/bin to PATH so subprocesses
  // spawned BY the agent (e.g. claude CLI, gh) can also find binaries
  // installed there. The primary fix for the agent itself is
  // resolveAgentBinary which uses an absolute path; this is defense-in-
  // depth for everything the agent transitively spawns.
  // Use path.posix.join because the runner is always Linux even if the
  // tests run on Windows.
  const home = baseEnv.HOME || "/root";
  const localBin = path.posix.join(home, ".local", "bin");
  const existingPath = baseEnv.PATH || "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
  const augmentedPath = existingPath.includes(localBin) ? existingPath : `${localBin}:${existingPath}`;

  const env = {
    ...baseEnv,
    PATH: augmentedPath,
    GOAT_REMOTE: "1",
    GOAT_CALLBACK_PORT: String(callbackPort),
    GOAT_SAAS_BUILD_ID: buildId,
    GH_TOKEN: githubPat,
    // Cycle 21-1-4 — never let git try to prompt interactively. Without this,
    // a credential-helper failure makes git hang trying to read username from
    // /dev/tty (which doesn't exist on the runner), producing the misleading
    // "could not read Username" stderr. With this set, the failure is fast
    // and unambiguous.
    GIT_TERMINAL_PROMPT: "0",
  };
  if (anthropicApiKey) {
    env.ANTHROPIC_API_KEY = anthropicApiKey;
  }
  return env;
}

/**
 * Write ~/.goat-saas-agent/credentials.json with the operator's API key and
 * MCP server URL. This allows the agent on the runner VM to validate its
 * license and report build events to the MCP server without requiring
 * `goat-saas-agent setup` to have been run on the snapshot image.
 *
 * Best-effort — silently returns false on any error. The VM destroy is the
 * ultimate safety net for any credential residue.
 */
export async function writeAgentCredentials(apiKey, serverUrl) {
  try {
    const dir = path.join(homedir(), ".goat-saas-agent");
    await fs.mkdir(dir, { recursive: true });
    const credPath = path.join(dir, "credentials.json");
    await fs.writeFile(credPath, JSON.stringify({ apiKey, serverUrl }, null, 2), { mode: 0o600 });
    return true;
  } catch {
    return false;
  }
}

/**
 * Best-effort wipe of secrets.md immediately after the agent exits. Takes a
 * path so tests can pass a tmp file and verify the delete without spawning
 * a real agent. Silently swallows errors — the VM destroy is the ultimate
 * safety net.
 */
export async function wipeSecretsAfterAgent(secretsPath) {
  try {
    await fs.rm(secretsPath, { force: true });
    return true;
  } catch {
    return false;
  }
}

/**
 * Configure git credentials on a freshly-cloned runner workspace:
 *   1. Set generic git identity so the agent's bootstrap doesn't prompt
 *   2. Strip the PAT from the clone URL (set-url to the bare URL)
 *   3. Set up `gh` as the credential helper via GH_TOKEN env
 *
 * Takes a commandRunner so tests can mock the spawn calls and assert
 * the sequence of commands + env vars.
 *
 * After this runs, subsequent `git push` calls authenticate via GH_TOKEN
 * from the agent's process env — the PAT is never persisted in .git/config.
 */
export async function configureGitCredentials({ workdir, githubRepo, githubPat, commandRunner = runCommand }) {
  // Set generic git identity so the agent's bootstrap step doesn't prompt
  await commandRunner("git", ["config", "user.name", "goat-saas-runner"], { cwd: workdir });
  await commandRunner("git", ["config", "user.email", "runner@goat-saas.local"], { cwd: workdir });

  // Replace the PAT-in-URL remote with a bare HTTPS URL
  await commandRunner(
    "git",
    ["remote", "set-url", "origin", `https://github.com/${githubRepo}.git`],
    { cwd: workdir },
  );

  // Cycle 21-1-4 — Inline credential helper that reads GH_TOKEN from env at
  // lookup time. Replaces `gh auth setup-git` which we previously hoped would
  // wire gh as the credential helper but observably failed: every git push
  // from the runner was returning `fatal: could not read Username for
  // 'https://github.com'`. The reason `gh auth setup-git` doesn't work in this
  // environment isn't worth chasing — the inline helper sidesteps the entire
  // class of failures because it has no external binary dependency.
  //
  // The helper is a bash function that responds to the `get` operation by
  // echoing username + password from env. Git calls credential helpers with
  // the operation as $1 (`get`, `store`, or `erase`); we only handle `get`
  // (the only one that matters for fetch/push) and silently ignore the rest.
  // The helper is written to global git config (~/.gitconfig) so EVERY git
  // invocation in any cwd uses it, not just one repo.
  //
  // GH_TOKEN reaches the helper via the spawn env: buildSpawnEnv sets it on
  // every agent spawn, the agent inherits it on every subprocess, git's
  // credential-helper child inherits it from git. The PAT is never persisted
  // to disk in any form.
  //
  // GIT_TERMINAL_PROMPT=0 (set in buildSpawnEnv) ensures git fails fast with
  // a clear error if the helper somehow returns nothing, instead of silently
  // hanging on an interactive prompt that has no TTY to answer.
  const helperScript = `!f() { test "$1" = get && echo username=x-access-token && echo password=$GH_TOKEN; }; f`;
  // --replace-all: if the snapshot image or a prior provision left multiple
  // credential.helper values, a plain `git config` fails with "cannot
  // overwrite multiple values with a single value". --replace-all clears
  // all existing values before writing the new one.
  await commandRunner(
    "git",
    ["config", "--global", "--replace-all", "credential.https://github.com.helper", helperScript],
    { cwd: workdir },
  );
  // Also set the same helper at the unscoped credential.helper key as a
  // fallback for any git internal that doesn't pick up the host-scoped one.
  await commandRunner(
    "git",
    ["config", "--global", "--replace-all", "credential.helper", helperScript],
    { cwd: workdir },
  );
}

async function fileExists(p) {
  try {
    await fs.stat(p);
    return true;
  } catch {
    return false;
  }
}

function writeConfigFile(filePath, fields) {
  const lines = ["---"];
  for (const [k, v] of Object.entries(fields)) {
    if (v === undefined || v === null) continue;
    lines.push(`${k}: ${serializeYamlValue(v)}`);
  }
  lines.push("---", "");
  return fs.writeFile(filePath, lines.join("\n"), "utf-8");
}

/**
 * Cycle 21-1-2 — Serialize a single YAML value safely.
 *
 * The previous implementation had a subtle but production-killing bug:
 * STRING values were emitted unquoted unless they contained `:` or `#`.
 * That left strings like "+16173317871" (a phone number) emitted as
 * `notify-sms: +16173317871`, which YAML parses as the INTEGER
 * 16173317871 because leading `+` is legal YAML for positive integers.
 * The agent's Zod schema then rejected the parsed config because
 * notify-sms is required to be a string. Result: every remote build
 * died at config validation with "Invalid configuration" and operators
 * had no way to debug it (until cycle 21-1's runner-log channel).
 *
 * The fix is structural: ALWAYS double-quote string values. JSON.stringify
 * handles escaping (quotes, newlines, backslashes) and the resulting
 * `"..."` is unambiguously a YAML string regardless of contents.
 * Booleans, numbers, objects, and arrays use JSON.stringify directly,
 * which produces YAML-compatible output (JSON is a strict subset of YAML).
 *
 * Exported for testability.
 */
export function serializeYamlValue(v) {
  if (v === undefined || v === null) return "null";
  if (typeof v === "string") {
    // Always quote strings — eliminates the entire class of YAML
    // type-coercion bugs (phone numbers parsed as ints, "yes"/"no"/
    // "on"/"off" parsed as booleans, "1.0" parsed as a float, etc.).
    return JSON.stringify(v);
  }
  // Booleans, numbers, arrays, objects all serialize correctly via JSON.
  return JSON.stringify(v);
}

function runCommand(cmd, args, opts) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { stdio: "inherit", ...opts });
    child.on("error", reject);
    child.on("exit", (code) => resolve(code ?? 0));
  });
}

/**
 * Cycle 21-1 — Run the agent with stdout+stderr piped through a line-buffered
 * flusher that pushes chunks to MCP via POST /runners/:id/log. This lets the
 * operator read the agent's actual output remotely (via `goat-saas-agent
 * runner-log <id>`) without SSHing into the runner droplet — ufw blocks
 * external SSH and the DO web console requires a password reset that's
 * cumbersome to use mid-debug.
 *
 * Behavior:
 *   - Buffers up to FLUSH_LINE_THRESHOLD lines OR FLUSH_INTERVAL_MS milliseconds
 *   - Each line is also tee'd to /var/log/goat-callback.log via console.log so
 *     SSH-based debugging still works as a fallback
 *   - Final flush on exit, BEFORE the status report fires
 *   - All log push failures are silently dropped — the agent's exit code is
 *     authoritative, the log buffer is best-effort telemetry
 *
 * Exported as a separate function (not part of runCommand) so the existing
 * test suite for runCommand stays untouched and the new pipe behavior gets
 * its own focused tests.
 */
const FLUSH_LINE_THRESHOLD = 50;
const FLUSH_INTERVAL_MS = 3000;
const MAX_LINE_LENGTH = 4000; // truncate pathological lines (binary blobs, etc.)

export function runAgentWithLogSink(cmd, args, opts, logSink) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { stdio: ["ignore", "pipe", "pipe"], ...opts });

    let buffer = [];
    let flushTimer = null;
    let stdoutCarry = "";
    let stderrCarry = "";
    let flushing = false;

    const scheduleFlush = () => {
      if (flushTimer) return;
      flushTimer = setTimeout(() => {
        flushTimer = null;
        flushBuffer().catch(() => {});
      }, FLUSH_INTERVAL_MS);
    };

    const flushBuffer = async () => {
      if (flushing) return;
      if (!buffer.length) return;
      flushing = true;
      const lines = buffer;
      buffer = [];
      try {
        await logSink(lines);
      } catch {
        // Best-effort — drop the chunk
      } finally {
        flushing = false;
      }
    };

    const enqueue = (line) => {
      if (!line.length) return;
      const truncated = line.length > MAX_LINE_LENGTH ? line.slice(0, MAX_LINE_LENGTH) + "…[truncated]" : line;
      buffer.push(truncated);
      // Tee to local log for SSH-based debugging fallback
      console.log(truncated);
      if (buffer.length >= FLUSH_LINE_THRESHOLD) {
        // Fire-and-forget; don't await — backpressure on a slow MCP shouldn't
        // block the agent's stdout pipe (could deadlock the agent process).
        flushBuffer().catch(() => {});
      } else {
        scheduleFlush();
      }
    };

    const consumeChunk = (chunk, carryRef, prefix) => {
      const text = (carryRef.value || "") + chunk.toString("utf-8");
      const lines = text.split("\n");
      // Last element is partial (no trailing newline) → carry forward
      carryRef.value = lines.pop() || "";
      for (const line of lines) {
        enqueue(prefix + line);
      }
    };

    const stdoutCarryRef = { value: stdoutCarry };
    const stderrCarryRef = { value: stderrCarry };

    child.stdout.on("data", (chunk) => consumeChunk(chunk, stdoutCarryRef, ""));
    child.stderr.on("data", (chunk) => consumeChunk(chunk, stderrCarryRef, "[stderr] "));

    child.on("error", (err) => {
      enqueue(`[callback-server] spawn error: ${err.message}`);
      flushBuffer().finally(() => reject(err));
    });

    child.on("exit", (code) => {
      // Flush any partial trailing line that wasn't terminated by \n
      if (stdoutCarryRef.value) enqueue(stdoutCarryRef.value);
      if (stderrCarryRef.value) enqueue("[stderr] " + stderrCarryRef.value);
      // Cancel any pending timer and do one final flush before resolving so
      // the operator's `runner-log` fetch sees the agent's last words.
      if (flushTimer) {
        clearTimeout(flushTimer);
        flushTimer = null;
      }
      enqueue(`[callback-server] agent process exited with code ${code ?? 0}`);
      flushBuffer().finally(() => resolve(code ?? 0));
    });
  });
}

/**
 * Build a logSink function bound to the MCP server's POST /runners/:id/log
 * endpoint. Returns a function that takes an array of lines and POSTs them.
 * Pulled out for testability — tests can pass a stub sink instead of hitting
 * the network.
 */
export function buildLogSink({ url, instanceId, token, fetchImpl = fetch }) {
  let failCount = 0;
  return async (lines) => {
    if (!url || !instanceId || !lines.length) return;
    const target = `${url}/runners/${encodeURIComponent(instanceId)}/log`;
    try {
      const res = await fetchImpl(target, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
        body: JSON.stringify({ lines }),
      });
      if (!res.ok) {
        failCount++;
        // Log first 3 failures to local log so we can diagnose remotely
        // via SSH or by reading /var/log/goat-callback.log
        if (failCount <= 3) {
          const body = await res.text().catch(() => "");
          console.error(`[log-sink] POST ${target} returned ${res.status}: ${body}`);
        } else if (failCount === 4) {
          console.error(`[log-sink] Suppressing further failure logs (${failCount}+ failures)`);
        }
      } else {
        failCount = 0; // reset on success
      }
    } catch (err) {
      failCount++;
      if (failCount <= 3) {
        console.error(`[log-sink] POST ${target} threw: ${err.message || err}`);
      } else if (failCount === 4) {
        console.error(`[log-sink] Suppressing further failure logs (${failCount}+ failures)`);
      }
    }
  };
}

async function reportStatus(status) {
  const url = process.env.GOAT_MCP_SERVER_URL;
  const id = process.env.GOAT_RUNNER_INSTANCE_ID;
  const token = process.env.GOAT_RUNNER_TOKEN;
  if (!url || !id) return;
  try {
    await fetch(`${url}/runners/${encodeURIComponent(id)}/status`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify({ status }),
    });
  } catch {
    // Status reports are best-effort
  }
}

/**
 * GET /health — health check
 */
app.get("/health", (_req, res) => {
  res.json({ status: "ok", waitingGates: waiters.size, pendingResponses: pendingResponses.size });
});

/**
 * Verify ufw is active on the runner. Bind on 0.0.0.0 is required because
 * the MCP server reaches us via the runner's public IP for /gate-response,
 * but the host firewall (configured by setup.sh) is the actual perimeter —
 * it must allow only the MCP server's IP on this dynamic port. /agent/wait-gate
 * has no authentication and depends on the agent always using 127.0.0.1 to
 * reach us; if the firewall is open, an attacker could spoof gate responses.
 *
 * Accepts an optional `{ exec, logger }` injection so tests can exercise all
 * three branches (active / inactive / missing-ufw) without depending on the
 * host environment. Returns a string describing the outcome for assertions.
 *
 * See goat-saas-skill-setup/runner-image/setup.sh for firewall configuration.
 */
export function checkFirewall({ exec = execSync, logger = console.error } = {}) {
  try {
    const out = exec("ufw status 2>/dev/null", { encoding: "utf-8" });
    if (!/Status: active/i.test(out)) {
      logger("[WARN] ufw is INACTIVE on this runner. The callback server's");
      logger("       /gate-response endpoint is exposed to the public internet");
      logger("       and an attacker who learns the runner IP + port can spoof");
      logger("       gate responses. Run 'ufw enable' or rebuild the snapshot.");
      return "inactive";
    }
    return "active";
  } catch {
    logger("[WARN] ufw is not installed on this runner. Host firewall checks");
    logger("       skipped. The callback server is exposed to the public internet.");
    return "missing";
  }
}

// Export the Express app and helpers so tests can import them without
// triggering app.listen(). The script-mode entry below only runs when this
// file is invoked directly (e.g. by cloud-init's `node callback-server/index.js`).
// runAgentWithLogSink, buildLogSink, and resolveAgentBinary are exported via
// their `export` declarations above (cycle 21-1 / 21-1-1).
export { app, waiters, pendingResponses, writeConfigFile, fileExists, reportStatus };

// Exposed for tests — verify that importing the module does NOT trigger
// app.listen() (i.e. isMainModule is false under vitest).
export function getIsMainModule() {
  return isMainModule;
}

/**
 * Is this module the main entry point (i.e. invoked via `node index.js`,
 * not imported by a test)? Use fileURLToPath on both sides to handle both
 * POSIX (`/opt/.../index.js`) and Windows (`C:\\...\\index.js`) consistently.
 * The previous string-comparison approach worked on POSIX but always
 * returned false on Windows because `file://C:\\path` is not a valid URL.
 */
const isMainModule = (() => {
  try {
    if (!process.argv[1]) return false;
    const thisFile = fileURLToPath(import.meta.url);
    const entryFile = process.argv[1];
    // Normalize both — on Windows, path resolution may differ in case/sep
    return path.resolve(thisFile) === path.resolve(entryFile);
  } catch {
    return false;
  }
})();

if (isMainModule) {
  const PORT = process.env.CALLBACK_PORT || 0;
  const server = app.listen(PORT, "0.0.0.0", () => {
    const addr = server.address();
    LISTEN_PORT = (typeof addr === "object" && addr ? addr.port : Number(PORT)) || 0;
    console.log(`Runner callback server listening on port ${LISTEN_PORT}`);
    checkFirewall();

    // Write port to file for the cloud-init script to read
    try {
      writeFileSync("/tmp/goat-runner-callback-port", String(LISTEN_PORT));
    } catch {
      // Best-effort — non-Linux environments may not have /tmp
    }
  });
}
