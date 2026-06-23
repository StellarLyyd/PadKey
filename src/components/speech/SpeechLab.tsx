import { useEffect, useMemo, useState } from "react";
import { BrainCircuit, Check, Clipboard, Download, FileArchive, Loader2, Play, ScanSearch, Sparkles } from "lucide-react";
import { encodeWav } from "../../audio/exportAudio";
import { mergePcmChunks } from "../../audio/exportAudio";
import { exportSpeechDataset } from "../../speech/exportDataset";
import { useSpeechAnalysis } from "../../speech/useSpeechAnalysis";
import { useTranscriber } from "../../speech/useTranscriber";
import { useAppStore } from "../../store";
import type { SegmentTranscript, SpeechSegment } from "../../types";
import { SegmentTimeline } from "./SegmentTimeline";

const whisperModels = [
  { id: "onnx-community/whisper-tiny.en", label: "Whisper Tiny English" },
  { id: "onnx-community/whisper-base.en", label: "Whisper Base English" }
];

function floatToInt16(input: Float32Array) {
  return Int16Array.from(input, (sample) => Math.round(Math.max(-1, Math.min(0.999969, sample)) * 32768));
}

function formatMs(ms: number) {
  return `${(ms / 1000).toFixed(2)}s`;
}

export function SpeechLab() {
  const audioChunks = useAppStore((state) => state.audioChunks);
  const audioSampleRate = useAppStore((state) => state.audioSampleRate);
  const audioSampleCount = useAppStore((state) => state.audioSampleCount);
  const sessionRecording = useAppStore((state) => state.sessionRecording);
  const sessionStartedAt = useAppStore((state) => state.sessionStartedAt);
  const sessionFrames = useAppStore((state) => state.sessionFrames);
  const sessionMode = useAppStore((state) => state.sessionMode);
  const droppedAudioPackets = useAppStore((state) => state.droppedAudioPackets);
  const [gapMs, setGapMs] = useState(300);
  const [sileroThreshold, setSileroThreshold] = useState(sessionMode === "ingressive" ? 0.35 : 0.5);
  const [spectralGate, setSpectralGate] = useState(true);
  const [preEmphasis, setPreEmphasis] = useState(false);
  const [rmsNormalize, setRmsNormalize] = useState(true);
  const [segments, setSegments] = useState<SpeechSegment[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [sileroAvailable, setSileroAvailable] = useState<boolean | null>(null);
  const [sileroError, setSileroError] = useState<string | null>(null);
  const [transcripts, setTranscripts] = useState<SegmentTranscript[]>([]);
  const [model, setModel] = useState(whisperModels[0].id);
  const [datasetLabel, setDatasetLabel] = useState("");
  const [copied, setCopied] = useState(false);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const analysis = useSpeechAnalysis();
  const transcriber = useTranscriber();

  const totalMs = audioSampleRate ? (audioSampleCount / audioSampleRate) * 1000 : 0;
  const selected = segments.find((segment) => segment.id === selectedId) ?? null;
  const transcriptMap = useMemo(() => new Map(transcripts.map((item) => [item.segmentId, item])), [transcripts]);
  const fullTranscript = transcripts.map((item) => item.text).filter(Boolean).join(" ");

  useEffect(() => {
    setSileroThreshold(sessionMode === "ingressive" ? 0.35 : 0.5);
  }, [sessionMode]);

  useEffect(() => {
    if (audioSampleCount === 0) {
      setSegments([]);
      setTranscripts([]);
      setSelectedId(null);
    }
  }, [audioSampleCount]);

  useEffect(() => {
    if (previewUrl) URL.revokeObjectURL(previewUrl);
    if (!selected || !audioSampleRate) {
      setPreviewUrl(null);
      return;
    }
    const url = URL.createObjectURL(encodeWav(floatToInt16(selected.processedAudio), audioSampleRate));
    setPreviewUrl(url);
    return () => URL.revokeObjectURL(url);
    // The generated URL owns its cleanup lifecycle.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selected, audioSampleRate]);

  function contactRanges() {
    if (!sessionStartedAt) return [];
    const active = sessionFrames
      .filter((frame) => frame.piezo > frame.thresholdPiezo)
      .map((frame) => Math.max(0, frame.ts - sessionStartedAt));
    if (!active.length) return [];
    const ranges: Array<{ startMs: number; endMs: number }> = [];
    let start = active[0];
    let end = active[0];
    for (const value of active.slice(1)) {
      if (value <= end + 120) end = value;
      else {
        ranges.push({ startMs: Math.max(0, start - 100), endMs: end + 160 });
        start = value;
        end = value;
      }
    }
    ranges.push({ startMs: Math.max(0, start - 100), endMs: end + 160 });
    return ranges;
  }

  async function handleAnalyze() {
    if (!audioSampleRate || !audioSampleCount) return;
    try {
      const result = await analysis.analyze(mergePcmChunks(audioChunks), audioSampleRate, {
        mode: sessionMode,
        gapMs,
        sileroThreshold,
        minSpeechMs: sessionMode === "ingressive" ? 90 : 140,
        spectralGate,
        preEmphasis,
        rmsNormalize,
        contactRanges: contactRanges()
      });
      setSegments(result.segments);
      setSileroAvailable(result.sileroAvailable);
      setSileroError(result.sileroError);
      setSelectedId(result.segments[0]?.id ?? null);
      setTranscripts([]);
    } catch {
      setSegments([]);
      setSelectedId(null);
    }
  }

  async function handleTranscribe() {
    if (!segments.length) return;
    try {
      const result = await transcriber.transcribe(model, segments);
      setTranscripts(result);
    } catch {
      setTranscripts([]);
    }
  }

  async function handleCopy() {
    if (!fullTranscript) return;
    await navigator.clipboard.writeText(fullTranscript);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1600);
  }

  async function handleDatasetExport() {
    if (!audioSampleRate || !segments.length || !datasetLabel.trim()) return;
    await exportSpeechDataset({
      segments,
      transcripts,
      sampleRate: 16000,
      captureMode: sessionMode,
      label: datasetLabel,
      droppedPackets: droppedAudioPackets,
      processing: { gapMs, sileroThreshold, spectralGate, preEmphasis, rmsNormalize }
    });
  }

  const analyzing = analysis.status === "analyzing";
  const transcribing = transcriber.transcriptionProgress.total > 0 && transcriber.transcriptionProgress.current < transcriber.transcriptionProgress.total;

  return (
    <section className="speech-lab" aria-labelledby="speech-lab-title">
      <div className="speech-lab-header">
        <div>
          <div className="section-kicker">PCM to text</div>
          <h1 id="speech-lab-title" className="workspace-title">Speech processing lab</h1>
          <p className="panel-copy">Detect utterances, prepare the signal, transcribe locally, and retain labeled training evidence.</p>
        </div>
        <div className="lab-session-status">
          <span className={audioSampleCount ? "status-dot is-ready" : "status-dot"} />
          {audioSampleCount ? `${(totalMs / 1000).toFixed(1)}s PCM · ${sessionMode}` : "No recorded PCM session"}
        </div>
      </div>

      <div className="lab-settings">
        <div className="lab-setting-group">
          <label className="field-label" htmlFor="vad-threshold">Silero threshold <b className="mono">{sileroThreshold.toFixed(2)}</b></label>
          <input id="vad-threshold" type="range" min={0.2} max={0.8} step={0.05} value={sileroThreshold} onChange={(event) => setSileroThreshold(Number(event.target.value))} />
        </div>
        <div className="lab-setting-group">
          <label className="field-label" htmlFor="stitch-gap">Stitch gap <b className="mono">{gapMs} ms</b></label>
          <input id="stitch-gap" type="range" min={100} max={700} step={50} value={gapMs} onChange={(event) => setGapMs(Number(event.target.value))} />
        </div>
        <div className="lab-processing-toggles">
          <label className="check-row"><input type="checkbox" checked={spectralGate} onChange={() => setSpectralGate((value) => !value)} /><span>Spectral gate</span></label>
          <label className="check-row"><input type="checkbox" checked={preEmphasis} onChange={() => setPreEmphasis((value) => !value)} /><span>Pre-emphasis</span></label>
          <label className="check-row"><input type="checkbox" checked={rmsNormalize} onChange={() => setRmsNormalize((value) => !value)} /><span>RMS normalize</span></label>
        </div>
        <button type="button" className="button button-primary" onClick={() => void handleAnalyze()} disabled={!audioSampleCount || sessionRecording || analyzing}>
          {analyzing ? <Loader2 size={15} className="spin" aria-hidden="true" /> : <ScanSearch size={15} aria-hidden="true" />}
          {analyzing ? "Analyzing PCM…" : "Detect utterances"}
        </button>
      </div>

      {analysis.error ? <div className="lab-error">Signal analysis failed: {analysis.error}</div> : null}

      <div className="timeline-section">
        <div className="section-row-heading">
          <div>
            <h2>Segment timeline</h2>
            <p>{segments.length ? `${segments.length} stitched utterance${segments.length === 1 ? "" : "s"}` : "Run detection after recording raw PCM."}</p>
          </div>
          {sileroAvailable !== null ? (
            <div className={sileroAvailable ? "engine-state is-ready" : "engine-state is-warning"}>
              {sileroAvailable ? <Check size={14} aria-hidden="true" /> : <Sparkles size={14} aria-hidden="true" />}
              {sileroAvailable ? "Silero + energy + contact" : "Energy + contact fallback"}
            </div>
          ) : null}
        </div>
        {sileroError ? <p className="silero-error-note">Silero unavailable: {sileroError}</p> : null}
        {segments.length ? (
          <SegmentTimeline segments={segments} totalMs={totalMs} selectedId={selectedId} onSelect={setSelectedId} />
        ) : (
          <div className="lab-empty"><BrainCircuit size={21} aria-hidden="true" /><span>No detected segments yet.</span></div>
        )}
      </div>

      <div className="lab-split">
        <section className="segment-list-pane" aria-labelledby="segments-title">
          <div className="pane-heading">
            <h2 id="segments-title">Detected segments</h2>
            {previewUrl ? <audio className="segment-player" controls src={previewUrl}><track kind="captions" /></audio> : null}
          </div>
          <div className="segment-table" role="table" aria-label="Detected speech segments">
            <div className="segment-row segment-row-head" role="row"><span>Segment</span><span>Time</span><span>Detector</span><span>Signal</span></div>
            {segments.map((segment) => (
              <button key={segment.id} type="button" className={segment.id === selectedId ? "segment-row is-selected" : "segment-row"} onClick={() => setSelectedId(segment.id)} role="row">
                <span>{segment.id.replace("segment-", "#")}</span>
                <span className="mono">{formatMs(segment.startMs)}–{formatMs(segment.endMs)}</span>
                <span>{segment.source}</span>
                <span className="mono">{Math.round(segment.signalScore * 100)}%</span>
              </button>
            ))}
          </div>
        </section>

        <section className="transcript-pane" aria-labelledby="transcript-title">
          <div className="pane-heading">
            <div>
              <h2 id="transcript-title">Transcription</h2>
              <p>Runs in a browser worker. Models are fetched once and cached.</p>
            </div>
            <button type="button" className="icon-button" disabled={!fullTranscript} onClick={() => void handleCopy()} aria-label="Copy transcript" title="Copy transcript">
              {copied ? <Check size={16} aria-hidden="true" /> : <Clipboard size={16} aria-hidden="true" />}
            </button>
          </div>
          <div className="model-controls">
            <select className="field-control" value={model} disabled={transcriber.modelStatus === "loading" || transcribing} onChange={(event) => setModel(event.target.value)} aria-label="Whisper model">
              {whisperModels.map((item) => <option key={item.id} value={item.id}>{item.label}</option>)}
            </select>
            {transcriber.modelStatus === "ready" ? (
              <button type="button" className="button button-primary" disabled={!segments.length || transcribing} onClick={() => void handleTranscribe()}>
                {transcribing ? <Loader2 size={15} className="spin" aria-hidden="true" /> : <BrainCircuit size={15} aria-hidden="true" />}
                {transcribing ? `${transcriber.transcriptionProgress.current}/${transcriber.transcriptionProgress.total}` : "Transcribe segments"}
              </button>
            ) : (
              <button type="button" className="button button-secondary" disabled={transcriber.modelStatus === "loading"} onClick={() => transcriber.load(model)}>
                {transcriber.modelStatus === "loading" ? <Loader2 size={15} className="spin" aria-hidden="true" /> : <Download size={15} aria-hidden="true" />}
                {transcriber.modelStatus === "loading" ? `${transcriber.modelProgress}%` : "Load model"}
              </button>
            )}
          </div>
          {transcriber.modelStatus === "loading" ? (
            <div className="model-progress"><span style={{ width: `${transcriber.modelProgress}%` }} /><small>{transcriber.modelFile ?? "Preparing Whisper model"}</small></div>
          ) : null}
          {transcriber.error ? <div className="lab-error">{transcriber.error}</div> : null}
          <div className="transcript-output" aria-live="polite">
            {transcripts.length ? transcripts.map((item) => (
              <div className="transcript-result" key={item.segmentId}>
                <p><b>{item.segmentId.replace("segment-", "#")}</b> {item.text || <em>No text returned</em>}</p>
                {item.words.some((word) => word.confidence !== null) ? (
                  <div className="confidence-tokens" aria-label="Token confidence">
                    {item.words.map((word, index) => (
                      <span key={`${item.segmentId}-${index}`} title={word.confidence === null ? "Confidence unavailable" : `${Math.round(word.confidence * 100)}% confidence`}>
                        {word.text.trim() || "…"} {word.confidence === null ? "—" : `${Math.round(word.confidence * 100)}%`}
                      </span>
                    ))}
                  </div>
                ) : (
                  <small className="confidence-unavailable">Token confidence is not exposed by this compact ONNX checkpoint.</small>
                )}
              </div>
            )) : <div className="transcript-empty">Load a Whisper model, then transcribe the detected segments.</div>}
          </div>
        </section>
      </div>

      <div className="dataset-bar">
        <div>
          <div className="processing-title">Training dataset</div>
          <p className="field-hint">Exports processed segment WAVs, timestamps, detector evidence, capture mode, and transcripts.</p>
        </div>
        <input className="field-control" value={datasetLabel} onChange={(event) => setDatasetLabel(event.target.value)} placeholder="Ground-truth label or phrase" aria-label="Dataset label" />
        <button type="button" className="button button-secondary" disabled={!segments.length || !datasetLabel.trim()} onClick={() => void handleDatasetExport()}>
          <FileArchive size={15} aria-hidden="true" /> Export dataset ZIP
        </button>
      </div>
    </section>
  );
}
