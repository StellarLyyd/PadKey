import { FormEvent, useEffect, useMemo, useState } from "react";
import { BookOpen, Circle, Download, Plus, Trash2, X } from "lucide-react";
import { useAppStore } from "../../store";
import type { TrainingSample } from "../../types";
import { ChannelControls } from "../ChannelControls";

const trainingScript = `import pandas as pd
import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report
from skl2onnx import convert_sklearn
from skl2onnx.common.data_types import FloatTensorType
import json, pickle

df = pd.read_csv('padkey_training_data.csv')
sensor_cols = ['pz1','mic','qt','pz2','mus','ext']
active_cols = ['active_pz1','active_mic','active_qt','active_pz2','active_mus','active_ext']

def extract_features(group, window=20):
    rows = []
    vals = group[sensor_cols].astype(float).values.copy()
    for col, active_col in enumerate(active_cols):
        if active_col in group.columns:
            vals[:, col] *= group[active_col].astype(int).values
    for i in range(window, len(vals)):
        w = vals[i-window:i]
        row = []
        for col in range(len(sensor_cols)):
            row += [w[:,col].mean(), w[:,col].max(),
                    w[:,col].min(), w[:,col].std()]
        rows.append(row)
    return rows

X, y = [], []
for label, group in df.groupby('label'):
    feats = extract_features(group)
    X.extend(feats)
    y.extend([label]*len(feats))

X, y = np.array(X), np.array(y)
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2)

model = RandomForestClassifier(n_estimators=100, random_state=42)
model.fit(X_train, y_train)

print(classification_report(y_test, model.predict(X_test)))

# export to ONNX
initial_type = [('float_input', FloatTensorType([None, 24]))]
onnx_model = convert_sklearn(model, initial_types=initial_type)
with open('padkey_model.onnx','wb') as f:
    f.write(onnx_model.SerializeToString())

# export metadata
classes = list(model.classes_)
acc = model.score(X_test, y_test)
json.dump({'classes': classes, 'accuracy': round(acc,4), 'features': 24},
          open('metadata.json','w'))

print("exported padkey_model.onnx + metadata.json")`;

function escapeCsv(value: string | number) {
  const text = String(value);
  if (!/[",\n]/.test(text)) {
    return text;
  }
  return `"${text.replace(/"/g, '""')}"`;
}

function exportCsv(samples: TrainingSample[]) {
  const header = [
    "label",
    "pz1",
    "mic",
    "qt",
    "pz2",
    "mus",
    "ext",
    "active_pz1",
    "active_mic",
    "active_qt",
    "active_pz2",
    "active_mus",
    "active_ext",
    "stream_rate_hz",
    "timestamp"
  ];
  const rows = samples.map((sample) => [
    sample.label,
    sample.pz1,
    sample.mic,
    sample.qt,
    sample.pz2,
    sample.mus,
    sample.ext,
    sample.activePz1 ? 1 : 0,
    sample.activeMic ? 1 : 0,
    sample.activeQt ? 1 : 0,
    sample.activePz2 ? 1 : 0,
    sample.activeMus ? 1 : 0,
    sample.activeExt ? 1 : 0,
    sample.streamRateHz,
    sample.ts
  ]);
  const csv = [header, ...rows].map((row) => row.map(escapeCsv).join(",")).join("\n");
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = "padkey_training_data.csv";
  anchor.click();
  URL.revokeObjectURL(url);
}

function formatLast(ts: number | null) {
  if (!ts) {
    return "-";
  }
  return new Intl.DateTimeFormat("en-US", {
    hour: "numeric",
    minute: "2-digit",
    second: "2-digit"
  }).format(new Date(ts));
}

export function TrainPanel() {
  const [newWord, setNewWord] = useState("");
  const [showHelp, setShowHelp] = useState(false);
  const vocabulary = useAppStore((state) => state.vocabulary);
  const selectedWord = useAppStore((state) => state.selectedWord);
  const samples = useAppStore((state) => state.samples);
  const recording = useAppStore((state) => state.recording);
  const bleConnected = useAppStore((state) => state.bleConnected);
  const serialConnected = useAppStore((state) => state.serialConnected);
  const addWord = useAppStore((state) => state.addWord);
  const setSelectedWord = useAppStore((state) => state.setSelectedWord);
  const setRecording = useAppStore((state) => state.setRecording);
  const clearSamples = useAppStore((state) => state.clearSamples);

  const sampleRows = useMemo(
    () =>
      vocabulary.map((word) => {
        const wordSamples = samples.filter((sample) => sample.label === word);
        const last = wordSamples[wordSamples.length - 1]?.ts ?? null;
        return { word, count: wordSamples.length, last };
      }),
    [samples, vocabulary]
  );

  const connected = bleConnected || serialConnected;
  const hint = !connected
    ? "connect BLE to begin"
    : recording
      ? `mouthing "${selectedWord}" - keep still between attempts`
      : "select a word, then hold Record while mouthing it silently";

  function handleAddWord(event: FormEvent) {
    event.preventDefault();
    addWord(newWord);
    setNewWord("");
  }

  function handleRecordToggle() {
    if (!connected) {
      return;
    }
    setRecording(!recording);
  }

  function handleClear() {
    if (samples.length && window.confirm("Clear all PadKey training samples?")) {
      clearSamples();
    }
  }

  useEffect(() => {
    if (!showHelp) {
      return;
    }

    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") {
        setShowHelp(false);
      }
    }

    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [showHelp]);

  return (
    <>
      <div className="grid gap-5 lg:grid-cols-[360px_minmax(0,1fr)]">
        <section className="grid content-start gap-5">
          <div className="thin-border rounded-xl bg-app-surface p-4 dark:bg-app-darkSurface">
            <div className="mb-4 flex items-center justify-between">
              <h2 className="text-[15px] font-medium text-app-ink dark:text-app-darkInk">Vocabulary</h2>
              <span className="font-mono text-[12px] text-app-secondary dark:text-app-darkSecondary">{vocabulary.length} words</span>
            </div>

            <div className="grid grid-cols-2 gap-2">
              {vocabulary.map((word) => {
                const selected = word === selectedWord;
                return (
                  <button
                    key={word}
                    type="button"
                    onClick={() => setSelectedWord(word)}
                    className={[
                      "focus-ring h-10 rounded-lg border-[0.5px] px-3 text-left text-[14px] transition-colors",
                      selected
                        ? "border-app-ink text-app-ink dark:border-app-darkInk dark:text-app-darkInk"
                        : "border-app-border text-app-secondary hover:bg-white dark:border-app-darkBorder dark:text-app-darkSecondary dark:hover:bg-app-darkBg"
                    ].join(" ")}
                  >
                    {word}
                  </button>
                );
              })}
            </div>

            <form onSubmit={handleAddWord} className="mt-4 flex gap-2">
              <label className="sr-only" htmlFor="new-word">
                Add word
              </label>
              <input
                id="new-word"
                value={newWord}
                onChange={(event) => setNewWord(event.target.value)}
                className="focus-ring h-10 min-w-0 flex-1 rounded-lg border-[0.5px] border-app-border bg-white px-3 text-[14px] text-app-ink placeholder:text-app-muted dark:border-app-darkBorder dark:bg-app-darkBg dark:text-app-darkInk"
                placeholder="new word"
              />
              <button
                type="submit"
                className="focus-ring inline-flex h-10 items-center gap-2 rounded-lg border-[0.5px] border-app-border px-3 text-[13px] font-medium text-app-ink hover:bg-white dark:border-app-darkBorder dark:text-app-darkInk dark:hover:bg-app-darkBg"
              >
                <Plus className="h-4 w-4" aria-hidden="true" />
                Add
              </button>
            </form>
          </div>

          <ChannelControls compact />

          <div className="thin-border rounded-xl bg-app-surface p-4 dark:bg-app-darkSurface">
            <button
              type="button"
              onClick={handleRecordToggle}
              disabled={!connected}
              title={!connected ? "connect device first" : undefined}
              className={[
                "focus-ring flex h-14 w-full items-center justify-center gap-2 rounded-lg border-[0.5px] text-[14px] font-medium transition-colors",
                recording
                  ? "border-sensor-red/30 bg-sensor-red/10 text-sensor-red"
                  : "border-app-border bg-white text-app-ink hover:bg-app-surface disabled:bg-app-surface disabled:text-app-muted dark:border-app-darkBorder dark:bg-app-darkBg dark:text-app-darkInk dark:hover:bg-app-darkSurface"
              ].join(" ")}
            >
              {recording ? (
                <span className="h-2.5 w-2.5 animate-pulse rounded-full bg-sensor-red" aria-hidden="true" />
              ) : (
                <Circle className="h-4 w-4" aria-hidden="true" />
              )}
              {recording ? `Recording "${selectedWord}"... tap to stop` : "Record sample"}
            </button>
            <p className="mt-3 min-h-5 text-[13px] text-app-secondary dark:text-app-darkSecondary">{hint}</p>
          </div>
        </section>

        <section className="thin-border grid min-h-[480px] grid-rows-[auto_minmax(0,1fr)_auto] rounded-xl bg-app-surface dark:bg-app-darkSurface">
          <div className="flex h-12 items-center justify-between border-b-[0.5px] border-app-border px-4 dark:border-app-darkBorder">
            <h2 className="text-[15px] font-medium text-app-ink dark:text-app-darkInk">Sample log</h2>
            <span className="font-mono text-[12px] text-app-secondary dark:text-app-darkSecondary">{samples.length} total</span>
          </div>

          <div className="min-h-0 overflow-auto">
            {sampleRows.some((row) => row.count > 0) ? (
              <table className="w-full border-collapse text-left text-[13px]">
                <thead className="sticky top-0 bg-app-surface text-app-secondary dark:bg-app-darkSurface dark:text-app-darkSecondary">
                  <tr className="border-b-[0.5px] border-app-border dark:border-app-darkBorder">
                    <th className="px-4 py-3 font-medium">Label</th>
                    <th className="px-4 py-3 font-medium">Captured frames</th>
                    <th className="px-4 py-3 font-medium">Last capture</th>
                  </tr>
                </thead>
                <tbody>
                  {sampleRows.map((row) => (
                    <tr key={row.word} className="border-b-[0.5px] border-app-border/70 dark:border-app-darkBorder">
                      <td className="px-4 py-3 text-app-ink dark:text-app-darkInk">{row.word}</td>
                      <td className="px-4 py-3 font-mono text-app-ink dark:text-app-darkInk">{row.count}</td>
                      <td className="px-4 py-3 font-mono text-app-secondary dark:text-app-darkSecondary">{formatLast(row.last)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            ) : (
              <div className="grid h-full min-h-[260px] place-items-center px-6 py-10 text-center">
                <div>
                  <div className="text-[15px] font-medium text-app-ink dark:text-app-darkInk">No labeled frames yet</div>
                  <p className="mt-2 max-w-md text-[13px] leading-6 text-app-secondary dark:text-app-darkSecondary">
                    Connect the device, choose one word, and record a few clean repetitions before adding more classes.
                  </p>
                </div>
              </div>
            )}
          </div>

          <div className="flex flex-wrap items-center gap-2 border-t-[0.5px] border-app-border p-4 dark:border-app-darkBorder">
            <button
              type="button"
              onClick={() => exportCsv(samples)}
              disabled={!samples.length}
              className="focus-ring inline-flex h-9 items-center gap-2 rounded-lg border-[0.5px] border-app-border px-3 text-[13px] font-medium text-app-ink hover:bg-white disabled:text-app-muted dark:border-app-darkBorder dark:text-app-darkInk dark:hover:bg-app-darkBg"
            >
              <Download className="h-4 w-4" aria-hidden="true" />
              Export CSV
            </button>
            <button
              type="button"
              onClick={handleClear}
              disabled={!samples.length}
              className="focus-ring inline-flex h-9 items-center gap-2 rounded-lg border-[0.5px] border-app-border px-3 text-[13px] font-medium text-app-secondary hover:bg-white disabled:text-app-muted dark:border-app-darkBorder dark:text-app-darkSecondary dark:hover:bg-app-darkBg"
            >
              <Trash2 className="h-4 w-4" aria-hidden="true" />
              Clear all
            </button>
            <button
              type="button"
              onClick={() => setShowHelp(true)}
              className="focus-ring ml-auto inline-flex h-9 items-center gap-2 rounded-lg border-[0.5px] border-app-border px-3 text-[13px] font-medium text-app-ink hover:bg-white dark:border-app-darkBorder dark:text-app-darkInk dark:hover:bg-app-darkBg"
            >
              <BookOpen className="h-4 w-4" aria-hidden="true" />
              How to train &gt;
            </button>
          </div>
        </section>
      </div>

      {showHelp ? (
        <div className="fixed inset-0 z-20 grid place-items-center bg-black/40 p-5" role="dialog" aria-modal="true" aria-labelledby="training-help-title">
          <div className="thin-border max-h-[86vh] w-full max-w-4xl overflow-hidden rounded-xl bg-white dark:bg-app-darkBg">
            <div className="flex h-12 items-center justify-between border-b-[0.5px] border-app-border px-4 dark:border-app-darkBorder">
              <h2 id="training-help-title" className="text-[15px] font-medium text-app-ink dark:text-app-darkInk">
                Python training
              </h2>
              <button
                type="button"
                onClick={() => setShowHelp(false)}
                className="focus-ring grid h-8 w-8 place-items-center rounded-lg text-app-secondary hover:bg-app-surface dark:text-app-darkSecondary dark:hover:bg-app-darkSurface"
                aria-label="Close"
              >
                <X className="h-4 w-4" aria-hidden="true" />
              </button>
            </div>
            <div className="max-h-[calc(86vh-48px)] overflow-auto p-5">
              <ol className="grid gap-2 text-[14px] text-app-ink dark:text-app-darkInk">
                <li>1. Export your CSV from the Train tab</li>
                <li>2. Install: <code className="font-mono">pip install scikit-learn pandas numpy skl2onnx</code></li>
                <li>3. Run the training script below</li>
                <li>4. Drop the output .onnx + metadata.json into the Inference tab</li>
              </ol>
              <pre className="mt-5 overflow-auto rounded-lg border-[0.5px] border-app-border bg-app-surface p-4 font-mono text-[12px] leading-relaxed text-app-ink dark:border-app-darkBorder dark:bg-app-darkSurface dark:text-app-darkInk">
                <code>{trainingScript}</code>
              </pre>
            </div>
          </div>
        </div>
      ) : null}
    </>
  );
}
