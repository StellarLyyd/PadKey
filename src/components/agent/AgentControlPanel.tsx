import { Check, Command, ExternalLink, Loader2, RefreshCw, ShieldCheck } from "lucide-react";
import { useCallback, useEffect, useState } from "react";

const AGENT_URL = "http://127.0.0.1:8788";

type AgentResponse = {
  ok: boolean;
  intent: string;
  spoken: string;
  frontmostApp?: string;
  selectedTarget?: string;
  actionResult?: string;
  clarification?: string;
  confirmationRequired: boolean;
  confirmationId?: string;
  permissionRequired?: string;
  message?: string;
};

type Permissions = {
  accessibility: { granted?: boolean; reason: string };
  automation: { granted?: boolean; reason: string };
  inputMonitoring: { granted?: boolean; reason: string };
};

const testCommands = [
  ["Notes", "Open Notes and create a new note called PadKey Demo"],
  ["FaceTime", "Open FaceTime and prepare to call John"],
  ["Focused field", "Type PadKey test into the focused field"],
  ["Button", "Click the Save button"],
  ["Browser", "Search the current page for PadKey"]
] as const;

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  let response: Response;
  try {
    response = await fetch(`${AGENT_URL}${path}`, init);
  } catch {
    throw new Error("PadKey Mac Control is offline. Launch the OwoFlow Mac app, then try again.");
  }
  const body = await response.json().catch(() => ({})) as T & { error?: { message?: string } };
  if (!response.ok) throw new Error(body.error?.message ?? "The Mac action could not be completed.");
  return body;
}

export function AgentControlPanel() {
  const [command, setCommand] = useState("");
  const [state, setState] = useState<"idle" | "loading" | "success" | "error">("idle");
  const [online, setOnline] = useState(false);
  const [result, setResult] = useState<AgentResponse | null>(null);
  const [permissions, setPermissions] = useState<Permissions | null>(null);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      await request<{ ok: boolean }>("/health");
      setOnline(true);
      setPermissions(await request<Permissions>("/permissions"));
      setError(null);
    } catch (refreshError) {
      setOnline(false);
      setError(refreshError instanceof Error ? refreshError.message : "Mac Control is offline.");
    }
  }, []);

  useEffect(() => { void refresh(); }, [refresh]);

  async function run(transcript = command) {
    const clean = transcript.trim();
    if (!clean) return;
    setCommand(clean);
    setState("loading");
    setError(null);
    try {
      const response = await request<AgentResponse>("/command", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ transcript: clean, source: "padkey_studio", mode: "mac_control" })
      });
      setResult(response);
      setState("success");
      setOnline(true);
      void refresh();
    } catch (runError) {
      setState("error");
      setError(runError instanceof Error ? runError.message : "The command failed.");
    }
  }

  async function confirm() {
    if (!result?.confirmationId) return;
    setState("loading");
    try {
      const response = await request<AgentResponse>("/confirm", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ confirmationId: result.confirmationId })
      });
      setResult(response);
      setState("success");
    } catch (confirmError) {
      setState("error");
      setError(confirmError instanceof Error ? confirmError.message : "Confirmation failed.");
    }
  }

  const accessibilityReady = permissions?.accessibility.granted === true;

  return (
    <section className="agent-panel" aria-labelledby="agent-title">
      <header className="agent-heading">
        <div>
          <span className="section-kicker">Mac control</span>
          <h1 id="agent-title" className="workspace-title">Turn speech into action</h1>
          <p className="panel-copy">Ask PadKey to work in Notes, FaceTime, browsers, and accessible Mac controls. Actions stay local to this Mac.</p>
        </div>
        <button type="button" className="button button-secondary" onClick={() => void refresh()}><RefreshCw size={15} /> Check connection</button>
      </header>

      <div className={`agent-availability ${online ? "is-online" : "is-offline"}`} role="status">
        <span className="status-dot" />
        <div><b>{online ? "Mac Control ready" : "Mac Control offline"}</b><span>{online ? "OwoFlow is listening on this Mac." : "Open the OwoFlow Mac app to enable actions."}</span></div>
      </div>

      <div className="agent-command-box">
        <label htmlFor="agent-command">What should PadKey do?</label>
        <div className="agent-command-row">
          <input id="agent-command" value={command} onChange={(event) => setCommand(event.target.value)} onKeyDown={(event) => event.key === "Enter" && void run()} placeholder="Open Notes and create a note called Demo ideas" />
          <button type="button" className="button button-primary" disabled={state === "loading" || !command.trim()} onClick={() => void run()}>{state === "loading" ? <Loader2 className="spin" size={16} /> : <Command size={16} />} Run on Mac</button>
        </div>
      </div>

      {error ? <div className="agent-message is-error">{error}</div> : null}
      {result?.confirmationRequired ? (
        <div className="agent-confirmation">
          <div><b>Confirm before continuing</b><span>{result.spoken}</span></div>
          <button type="button" className="button button-primary" onClick={() => void confirm()}><Check size={16} /> Confirm action</button>
        </div>
      ) : null}

      <div className="agent-grid">
        <article className="agent-card agent-result-card">
          <h2>Latest action</h2>
          <dl className="agent-details">
            <div><dt>Frontmost app</dt><dd>{result?.frontmostApp ?? "Waiting for a command"}</dd></div>
            <div><dt>Detected intent</dt><dd>{result?.intent ?? "—"}</dd></div>
            <div><dt>UI target</dt><dd>{result?.selectedTarget ?? "—"}</dd></div>
            <div><dt>Result</dt><dd>{result?.actionResult ?? "No action yet"}</dd></div>
            <div><dt>Spoken response</dt><dd>{result?.spoken ?? "—"}</dd></div>
          </dl>
          {result?.clarification ? <div className="agent-clarification">{result.clarification}</div> : null}
        </article>

        <article className="agent-card">
          <h2>Permission readiness</h2>
          <div className="agent-permissions">
            <div><ShieldCheck size={17} /><span><b>Accessibility</b>{accessibilityReady ? "Ready" : permissions?.accessibility.reason ?? "Checking…"}</span></div>
            <div><ExternalLink size={17} /><span><b>App automation</b>{permissions?.automation.reason ?? "Checked when first used"}</span></div>
          </div>
          <p className="agent-note">Calls and other consequential actions always ask for confirmation.</p>
        </article>
      </div>

      <article className="agent-card agent-tests">
        <div><h2>Production checks</h2><p>Run these against real Mac apps before a customer demo.</p></div>
        <div className="agent-test-buttons">
          {testCommands.map(([label, transcript]) => <button type="button" key={label} className="button button-secondary" disabled={state === "loading"} onClick={() => void run(transcript)}>Test {label}</button>)}
        </div>
      </article>
    </section>
  );
}
