import { ChangeEvent, FormEvent, useEffect, useMemo, useRef, useState } from "react";
import {
  BrainCircuit,
  Check,
  Circle,
  Clipboard,
  Download,
  FileUp,
  Loader2,
  Plus,
  RadioTower,
  RotateCcw,
  Trash2,
  Undo2,
  Volume2,
  X
} from "lucide-react";
import { extractSignalBatchFeatures, isBrowserSignalModel, predictBrowserSignalModel } from "../../ml/signalModel";
import { useSignalTrainer } from "../../ml/useSignalTrainer";
import { useAppStore } from "../../store";
import type { BrowserSignalModel, SensorFrame, SignalBatch } from "../../types";

const MIN_BATCHES_PER_LABEL = 3;

function downloadBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  anchor.click();
  URL.revokeObjectURL(url);
}

function exportDatasetJson(batches: SignalBatch[]) {
  downloadBlob(
    new Blob([JSON.stringify({ version: 1, exportedAt: new Date().toISOString(), batches }, null, 2)], { type: "application/json" }),
    "padkey-signal-batches.json"
  );
}

function csvValue(value: unknown) {
  const text = String(value ?? "");
  return /[",\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

function exportDatasetCsv(batches: SignalBatch[]) {
  const columns = ["batch_id", "label", "frame_index", "source", "timestamp", "pz1", "mic", "qt", "pz2", "mus", "ext", "piezo", "noise_floor"];
  const rows = batches.flatMap((batch) => batch.frames.map((frame, frameIndex) => [
    batch.id,
    batch.label,
    frameIndex,
    frame.source,
    frame.ts,
    frame.pz1,
    frame.mic,
    frame.qt,
    frame.pz2,
    frame.mus,
    frame.ext,
    frame.piezo,
    frame.noiseFloor
  ]));
  const csv = [columns, ...rows].map((row) => row.map(csvValue).join(",")).join("\n");
  downloadBlob(new Blob([csv], { type: "text/csv;charset=utf-8" }), "padkey-signal-batches.csv");
}

function exportModel(model: BrowserSignalModel) {
  downloadBlob(new Blob([JSON.stringify(model, null, 2)], { type: "application/json" }), "padkey-signal-model.json");
}

function formatTime(timestamp: number | undefined) {
  if (!timestamp) return "—";
  return new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit", second: "2-digit" }).format(timestamp);
}

function sourceLabel(frame: SensorFrame | null) {
  if (!frame) return "waiting";
  if (frame.source === "serial") return "USB serial";
  if (frame.source === "wifi") return "Wi-Fi";
  return frame.source;
}

export function SignalTrainingLab() {
  const [newLabel, setNewLabel] = useState("");
  const [batchSize, setBatchSize] = useState(32);
  const [confidenceThreshold, setConfidenceThreshold] = useState(0.72);
  const [liveDictation, setLiveDictation] = useState(false);
  const [modelImportError, setModelImportError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const lastInferenceFrame = useRef(0);
  const stablePrediction = useRef({ label: "", count: 0 });
  const emittedLabel = useRef<string | null>(null);
  const trainer = useSignalTrainer();

  const serialConnected = useAppStore((state) => state.serialConnected);
  const wifiConnected = useAppStore((state) => state.wifiConnected);
  const bleConnected = useAppStore((state) => state.bleConnected);
  const latestFrame = useAppStore((state) => state.latestFrame);
  const frameHistory = useAppStore((state) => state.frameHistory);
  const frameCount = useAppStore((state) => state.frameCount);
  const vocabulary = useAppStore((state) => state.vocabulary);
  const selectedWord = useAppStore((state) => state.selectedWord);
  const batches = useAppStore((state) => state.signalBatches);
  const activeCapture = useAppStore((state) => state.activeBatchCapture);
  const signalModel = useAppStore((state) => state.signalModel);
  const prediction = useAppStore((state) => state.signalPrediction);
  const dictationTokens = useAppStore((state) => state.dictationTokens);
  const addWord = useAppStore((state) => state.addWord);
  const setSelectedWord = useAppStore((state) => state.setSelectedWord);
  const startSignalBatch = useAppStore((state) => state.startSignalBatch);
  const cancelSignalBatch = useAppStore((state) => state.cancelSignalBatch);
  const clearSignalBatches = useAppStore((state) => state.clearSignalBatches);
  const setSignalModel = useAppStore((state) => state.setSignalModel);
  const setSignalPrediction = useAppStore((state) => state.setSignalPrediction);
  const appendDictationToken = useAppStore((state) => state.appendDictationToken);
  const undoDictationToken = useAppStore((state) => state.undoDictationToken);
  const clearDictation = useAppStore((state) => state.clearDictation);

  const connected = serialConnected || wifiConnected || bleConnected;
  const labelStats = useMemo(() => vocabulary.map((label) => {
    const labelBatches = batches.filter((batch) => batch.label === label);
    return { label, count: labelBatches.length, last: labelBatches[labelBatches.length - 1]?.endedAt };
  }), [batches, vocabulary]);
  const readyLabels = labelStats.filter((item) => item.count >= MIN_BATCHES_PER_LABEL).map((item) => item.label);
  const trainingBatches = batches.filter((batch) => readyLabels.includes(batch.label));
  const canTrain = readyLabels.length >= 2 && trainingBatches.length >= MIN_BATCHES_PER_LABEL * 2;
  const captureProgress = activeCapture ? activeCapture.frames.length / activeCapture.targetFrames : 0;
  const dictatedText = dictationTokens.map((token) => token.text).join(" ");
  const currentCandidates = prediction?.probabilities ?? signalModel?.labels.map((word) => ({ word, probability: 0 })) ?? [];

  function handleAddLabel(event: FormEvent) {
    event.preventDefault();
    const clean = newLabel.trim().toLowerCase();
    if (!clean) return;
    addWord(clean);
    setSelectedWord(clean);
    setNewLabel("");
  }

  async function handleTrain() {
    if (!canTrain) return;
    try {
      const model = await trainer.train(trainingBatches);
      setSignalModel(model);
    } catch {
      // The hook owns the visible error state.
    }
  }

  async function handleModelImport(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    try {
      const value = JSON.parse(await file.text()) as unknown;
      if (!isBrowserSignalModel(value)) throw new Error("This is not a PadKey browser signal model.");
      setSignalModel(value);
      setBatchSize(value.batchSize);
      setModelImportError(null);
    } catch (error) {
      setModelImportError(error instanceof Error ? error.message : "Could not import model");
    }
  }

  async function copyDictation() {
    if (!dictatedText) return;
    await navigator.clipboard.writeText(dictatedText);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1400);
  }

  function speakDictation() {
    if (!dictatedText || !("speechSynthesis" in window)) return;
    window.speechSynthesis.cancel();
    window.speechSynthesis.speak(new SpeechSynthesisUtterance(dictatedText));
  }

  useEffect(() => {
    if (!liveDictation || !signalModel || !connected || frameHistory.length < signalModel.batchSize) return;
    if (frameCount - lastInferenceFrame.current < signalModel.batchSize) return;
    lastInferenceFrame.current = frameCount;
    const frames = frameHistory.slice(-signalModel.batchSize);
    const result = predictBrowserSignalModel(signalModel, extractSignalBatchFeatures(frames));
    if (!result) return;
    setSignalPrediction({ ...result, ts: Date.now() });

    if (result.confidence < confidenceThreshold) {
      stablePrediction.current = { label: "", count: 0 };
      return;
    }
    stablePrediction.current = result.label === stablePrediction.current.label
      ? { label: result.label, count: stablePrediction.current.count + 1 }
      : { label: result.label, count: 1 };
    if (stablePrediction.current.count < 2) return;
    if (result.label === "rest") {
      emittedLabel.current = null;
      return;
    }
    if (emittedLabel.current !== result.label) {
      appendDictationToken(result.label, result.confidence);
      emittedLabel.current = result.label;
    }
  }, [appendDictationToken, confidenceThreshold, connected, frameCount, frameHistory, liveDictation, setSignalPrediction, signalModel]);

  useEffect(() => {
    if (!liveDictation) {
      stablePrediction.current = { label: "", count: 0 };
      emittedLabel.current = null;
      setSignalPrediction(null);
    }
  }, [liveDictation, setSignalPrediction]);

  return (
    <section className="trainer-lab" aria-labelledby="trainer-title">
      <header className="trainer-header">
        <div>
          <div className="section-kicker">Supervised signal learning</div>
          <h1 id="trainer-title" className="workspace-title">Batch signals into dictated phrases</h1>
          <p className="panel-copy">Collect fixed-length telemetry windows, label repetitions, train locally, then turn stable live predictions into text.</p>
        </div>
        <div className={connected ? "engine-state is-ready" : "engine-state"}>
          <RadioTower size={14} aria-hidden="true" /> {connected ? `${sourceLabel(latestFrame)} ready` : "Connect a device to capture"}
        </div>
      </header>

      <div className="trainer-metrics">
        <div><span>Captured batches</span><b className="mono">{batches.length}</b></div>
        <div><span>Trainable labels</span><b className="mono">{readyLabels.length}</b></div>
        <div><span>Model accuracy</span><b className="mono">{signalModel ? `${Math.round(signalModel.accuracy * 100)}%` : "—"}</b></div>
        <div><span>Dictated tokens</span><b className="mono">{dictationTokens.length}</b></div>
      </div>

      <div className="trainer-grid">
        <section className="trainer-dataset" aria-labelledby="dataset-capture-title">
          <div className="trainer-pane-heading">
            <div><h2 id="dataset-capture-title">1. Capture labeled batches</h2><p>One batch should contain one complete attempt of the selected phrase.</p></div>
            <span className="mono">{batchSize} frames</span>
          </div>

          <div className="trainer-capture-controls">
            <div className="trainer-labels" role="listbox" aria-label="Training phrase">
              {vocabulary.map((label) => {
                const count = labelStats.find((item) => item.label === label)?.count ?? 0;
                return (
                  <button key={label} type="button" className={label === selectedWord ? "trainer-label is-selected" : "trainer-label"} onClick={() => setSelectedWord(label)} role="option" aria-selected={label === selectedWord}>
                    <span>{label}</span><b className="mono">{count}</b>
                  </button>
                );
              })}
            </div>
            <form className="trainer-add-label" onSubmit={handleAddLabel}>
              <input className="field-control" value={newLabel} onChange={(event) => setNewLabel(event.target.value)} placeholder="Add a word or short phrase" aria-label="New training phrase" />
              <button type="submit" className="button button-secondary"><Plus size={14} aria-hidden="true" /> Add</button>
            </form>
            <label className="trainer-batch-size">
              <span>Frames per batch</span>
              <select className="field-control" value={batchSize} disabled={Boolean(activeCapture)} onChange={(event) => setBatchSize(Number(event.target.value))}>
                <option value={16}>16 · quick gesture</option>
                <option value={32}>32 · recommended</option>
                <option value={48}>48 · longer phrase</option>
                <option value={64}>64 · slow phrase</option>
              </select>
            </label>

            {activeCapture ? (
              <div className="batch-capture-live">
                <div className="batch-capture-row"><span><i /> Capturing “{activeCapture.label}”</span><b className="mono">{activeCapture.frames.length}/{activeCapture.targetFrames}</b></div>
                <div className="batch-progress" aria-label={`Batch capture ${Math.round(captureProgress * 100)} percent`}><span style={{ width: `${captureProgress * 100}%` }} /></div>
                <button type="button" className="button button-secondary" onClick={cancelSignalBatch}><X size={14} aria-hidden="true" /> Cancel</button>
              </div>
            ) : (
              <button type="button" className="button button-primary trainer-capture-button" disabled={!connected || !selectedWord} onClick={() => startSignalBatch(selectedWord, batchSize)}>
                <Circle size={14} aria-hidden="true" /> Capture one “{selectedWord}” batch
              </button>
            )}
            <p className="field-hint">Capture at least {MIN_BATCHES_PER_LABEL} clean batches for “rest” and each phrase. More variation produces a less brittle model.</p>
          </div>

          <div className="batch-table" role="table" aria-label="Signal batch coverage">
            <div className="batch-row batch-row-head" role="row"><span>Label</span><span>Batches</span><span>Readiness</span><span>Last</span></div>
            {labelStats.map((item) => (
              <div className="batch-row" role="row" key={item.label}>
                <span>{item.label}</span><span className="mono">{item.count}</span>
                <span className={item.count >= MIN_BATCHES_PER_LABEL ? "coverage-ready" : "coverage-needed"}>{item.count >= MIN_BATCHES_PER_LABEL ? "ready" : `${MIN_BATCHES_PER_LABEL - item.count} needed`}</span>
                <span className="mono">{formatTime(item.last)}</span>
              </div>
            ))}
          </div>

          <div className="trainer-action-row">
            <button type="button" className="button button-secondary" disabled={!batches.length} onClick={() => exportDatasetCsv(batches)}><Download size={14} aria-hidden="true" /> CSV</button>
            <button type="button" className="button button-secondary" disabled={!batches.length} onClick={() => exportDatasetJson(batches)}><Download size={14} aria-hidden="true" /> JSON</button>
            <button type="button" className="button button-quiet" disabled={!batches.length} onClick={() => window.confirm("Clear all labeled signal batches?") && clearSignalBatches()}><Trash2 size={14} aria-hidden="true" /> Clear batches</button>
          </div>
        </section>

        <div className="trainer-output-column">
          <section className="trainer-model" aria-labelledby="model-training-title">
            <div className="trainer-pane-heading">
              <div><h2 id="model-training-title">2. Train the phrase model</h2><p>Softmax classifier trained in a browser worker; data never leaves this machine.</p></div>
              {signalModel ? <span className="engine-state is-ready"><Check size={14} aria-hidden="true" /> ready</span> : null}
            </div>
            <div className="trainer-model-body">
              <div className="model-readiness">
                <div><span>Eligible data</span><b>{trainingBatches.length} batches · {readyLabels.length} labels</b></div>
                <div><span>Required</span><b>2 labels · {MIN_BATCHES_PER_LABEL} batches each</b></div>
              </div>
              {trainer.status === "training" ? (
                <div className="training-progress-block">
                  <div className="batch-capture-row"><span><Loader2 size={14} className="spin" /> Training model</span><b className="mono">{trainer.progress}%</b></div>
                  <div className="batch-progress"><span style={{ width: `${trainer.progress}%` }} /></div>
                  <small className="mono">loss {trainer.loss?.toFixed(4) ?? "—"}</small>
                </div>
              ) : null}
              {trainer.error || modelImportError ? <div className="lab-error">{trainer.error ?? modelImportError}</div> : null}
              {signalModel ? (
                <div className="trained-model-summary">
                  <BrainCircuit size={18} aria-hidden="true" />
                  <div><b>{signalModel.labels.length}-class signal model</b><span>{Math.round(signalModel.accuracy * 100)}% held-out accuracy · {signalModel.trainingBatches} batches</span></div>
                </div>
              ) : null}
              <div className="trainer-model-actions">
                <button type="button" className="button button-primary" disabled={!canTrain || trainer.status === "training"} onClick={() => void handleTrain()}>
                  {trainer.status === "training" ? <Loader2 size={14} className="spin" aria-hidden="true" /> : <BrainCircuit size={14} aria-hidden="true" />}
                  {signalModel ? "Retrain model" : "Train model"}
                </button>
                <label className="button button-secondary file-button"><FileUp size={14} aria-hidden="true" /> Import model<input type="file" accept="application/json,.json" onChange={(event) => void handleModelImport(event)} /></label>
                <button type="button" className="button button-secondary" disabled={!signalModel} onClick={() => signalModel && exportModel(signalModel)}><Download size={14} aria-hidden="true" /> Export</button>
              </div>
            </div>
          </section>

          <section className="trainer-dictation" aria-labelledby="live-dictation-title">
            <div className="trainer-pane-heading">
              <div><h2 id="live-dictation-title">3. Dictate from live signals</h2><p>Two matching windows are required before a phrase is committed.</p></div>
              <button type="button" className={liveDictation ? "live-toggle is-live" : "live-toggle"} disabled={!signalModel || !connected} onClick={() => setLiveDictation((value) => !value)} aria-pressed={liveDictation}>
                <i /> {liveDictation ? "Listening" : "Start dictation"}
              </button>
            </div>
            <div className="dictation-settings">
              <label><span>Confidence gate</span><b className="mono">{Math.round(confidenceThreshold * 100)}%</b><input type="range" min={0.5} max={0.95} step={0.01} value={confidenceThreshold} onChange={(event) => setConfidenceThreshold(Number(event.target.value))} /></label>
              <span className="dictation-rest-note"><RotateCcw size={13} aria-hidden="true" /> Say/capture “rest” between repeated words to re-arm them.</span>
            </div>
            <div className="live-prediction">
              <div><span>Live prediction</span><b>{prediction?.label ?? "—"}</b><small>{prediction ? `${Math.round(prediction.confidence * 100)}% confidence` : liveDictation ? "collecting a window" : "dictation stopped"}</small></div>
              <div className="candidate-bars">
                {currentCandidates.slice(0, 4).map((candidate) => (
                  <div key={candidate.word}><span>{candidate.word}</span><i><b style={{ width: `${candidate.probability * 100}%` }} /></i><em className="mono">{Math.round(candidate.probability * 100)}%</em></div>
                ))}
              </div>
            </div>
            <div className="dictation-output" aria-live="polite">
              {dictatedText || <span>Trained phrases will appear here as dictated text.</span>}
            </div>
            <div className="trainer-action-row dictation-actions">
              <button type="button" className="button button-secondary" disabled={!dictatedText} onClick={() => void copyDictation()}>{copied ? <Check size={14} aria-hidden="true" /> : <Clipboard size={14} aria-hidden="true" />} {copied ? "Copied" : "Copy"}</button>
              <button type="button" className="button button-secondary" disabled={!dictatedText} onClick={speakDictation}><Volume2 size={14} aria-hidden="true" /> Read aloud</button>
              <button type="button" className="button button-secondary" disabled={!dictationTokens.length} onClick={undoDictationToken}><Undo2 size={14} aria-hidden="true" /> Undo</button>
              <button type="button" className="button button-quiet" disabled={!dictationTokens.length} onClick={clearDictation}><Trash2 size={14} aria-hidden="true" /> Clear</button>
            </div>
          </section>
        </div>
      </div>
    </section>
  );
}
