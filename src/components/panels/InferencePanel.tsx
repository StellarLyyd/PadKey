import { ChangeEvent, DragEvent, useMemo, useState } from "react";
import { CheckCircle2, FileUp, Loader2, UploadCloud } from "lucide-react";
import { useInference } from "../../ml/useInference";
import { useAppStore } from "../../store";

function percent(value: number | null | undefined) {
  if (value === null || value === undefined) {
    return "-";
  }
  return `${Math.round(value * 100)}%`;
}

function MetricCard({ label, value }: { label: string; value: string | number }) {
  return (
    <article className="thin-border rounded-xl bg-app-surface p-4 dark:bg-app-darkSurface">
      <div className="tool-label">{label}</div>
      <div className="mt-3 font-mono text-[22px] leading-none text-app-ink dark:text-app-darkInk">{value}</div>
    </article>
  );
}

export function InferencePanel() {
  const [dragging, setDragging] = useState(false);
  const { loadModel, modelLoaded, vocabulary, loading, error } = useInference();
  const bleConnected = useAppStore((state) => state.bleConnected);
  const serialConnected = useAppStore((state) => state.serialConnected);
  const lastPrediction = useAppStore((state) => state.lastPrediction);
  const lastConfidence = useAppStore((state) => state.lastConfidence);
  const candidateProbabilities = useAppStore((state) => state.candidateProbabilities);
  const samples = useAppStore((state) => state.samples);
  const storeVocabulary = useAppStore((state) => state.vocabulary);
  const modelMetadata = useAppStore((state) => state.modelMetadata);

  const displayedCandidates = useMemo(() => {
    if (candidateProbabilities.length) {
      return candidateProbabilities;
    }
    return vocabulary.map((word) => ({ word, probability: 0 }));
  }, [candidateProbabilities, vocabulary]);

  async function handleFiles(fileList: FileList | null) {
    if (!fileList?.length) {
      return;
    }

    const files = Array.from(fileList);
    const onnxFile = files.find((file) => file.name.toLowerCase().endsWith(".onnx"));
    const metadataFile = files.find((file) => file.name.toLowerCase() === "metadata.json");

    if (onnxFile) {
      await loadModel(onnxFile, metadataFile);
    }
  }

  function handleInputChange(event: ChangeEvent<HTMLInputElement>) {
    void handleFiles(event.currentTarget.files);
    event.currentTarget.value = "";
  }

  function handleDrop(event: DragEvent<HTMLLabelElement>) {
    event.preventDefault();
    setDragging(false);
    void handleFiles(event.dataTransfer.files);
  }

  const uncertain = modelLoaded && lastConfidence !== null && lastConfidence < 0.6;
  const classCount = modelMetadata?.classes.length || vocabulary.length || storeVocabulary.length;

  return (
    <div className="grid gap-5 xl:grid-cols-[minmax(0,1fr)_380px]">
      <section className="grid gap-5">
        <div className="thin-border grid min-h-[290px] place-items-center rounded-xl bg-app-surface p-8 text-center dark:bg-app-darkSurface">
          <div>
            <div className="tool-label">Top prediction</div>
            <div className="mt-3 text-[56px] font-medium leading-none text-app-ink dark:text-app-darkInk">{lastPrediction ?? "-"}</div>
            <div className="mt-4 flex items-center justify-center gap-2 text-[13px] text-app-secondary dark:text-app-darkSecondary">
              <span>{lastConfidence === null ? "waiting for prediction" : `${percent(lastConfidence)} confident`}</span>
              {uncertain ? (
                <span className="rounded-full border-[0.5px] border-sensor-amber/30 bg-sensor-amber/10 px-2 py-0.5 text-[12px] text-sensor-amber">
                  uncertain
                </span>
              ) : null}
            </div>
          </div>
        </div>

        <div className="thin-border rounded-xl bg-app-surface p-4 dark:bg-app-darkSurface">
          <div className="mb-3 flex items-center justify-between">
              <h2 className="text-[15px] font-medium text-app-ink dark:text-app-darkInk">Class probabilities</h2>
            <span className="text-[12px] text-app-secondary dark:text-app-darkSecondary">
              {modelLoaded && (bleConnected || serialConnected) ? "streaming" : "idle"}
            </span>
          </div>
          <div className="flex flex-wrap gap-2">
            {displayedCandidates.map((candidate, index) => {
              const active = candidate.word === lastPrediction || index === 0;
              return (
                <div
                  key={candidate.word}
                  className={[
                    "inline-flex h-9 items-center gap-2 rounded-full border-[0.5px] px-3 text-[13px]",
                    active
                      ? "border-app-ink text-app-ink dark:border-app-darkInk dark:text-app-darkInk"
                      : "border-app-border text-app-secondary dark:border-app-darkBorder dark:text-app-darkSecondary"
                  ].join(" ")}
                >
                  <span className={active ? "font-medium" : undefined}>{candidate.word}</span>
                  <span className="font-mono text-[11px] text-app-muted dark:text-app-darkSecondary">{percent(candidate.probability)}</span>
                </div>
              );
            })}
          </div>
        </div>
      </section>

      <aside className="grid content-start gap-5">
        <div className="thin-border rounded-xl bg-app-surface p-4 dark:bg-app-darkSurface">
          <h2 className="text-[15px] font-medium text-app-ink dark:text-app-darkInk">Model loader</h2>
          <label
            onDragOver={(event) => {
              event.preventDefault();
              setDragging(true);
            }}
            onDragLeave={() => setDragging(false)}
            onDrop={handleDrop}
            className={[
              "focus-ring mt-4 grid min-h-[148px] cursor-pointer place-items-center rounded-lg border-[0.5px] border-dashed p-4 text-center transition-colors",
              dragging
                ? "border-sensor-blue bg-sensor-blue/10"
                : "border-app-border bg-white hover:bg-app-surface dark:border-app-darkBorder dark:bg-app-darkBg dark:hover:bg-app-darkSurface"
            ].join(" ")}
            tabIndex={0}
          >
            <input className="sr-only" type="file" accept=".onnx,.json,application/json" multiple onChange={handleInputChange} />
            <div>
              {loading ? (
                <Loader2 className="mx-auto h-7 w-7 animate-spin text-app-secondary dark:text-app-darkSecondary" aria-hidden="true" />
              ) : (
                <UploadCloud className="mx-auto h-7 w-7 text-app-secondary dark:text-app-darkSecondary" aria-hidden="true" />
              )}
              <div className="mt-3 text-[13px] font-medium text-app-ink dark:text-app-darkInk">Drop .onnx + metadata.json</div>
              <div className="mt-1 text-[12px] text-app-secondary dark:text-app-darkSecondary">or click to browse</div>
            </div>
          </label>

          {modelLoaded ? (
            <div className="mt-4 grid gap-2 rounded-lg border-[0.5px] border-app-border bg-white p-3 dark:border-app-darkBorder dark:bg-app-darkBg">
              <div className="flex items-center gap-2 text-[13px] text-app-ink dark:text-app-darkInk">
                <FileUp className="h-4 w-4 text-app-secondary dark:text-app-darkSecondary" aria-hidden="true" />
                <span className="min-w-0 flex-1 truncate">{modelMetadata?.filename ?? "model.onnx"}</span>
                <span className="inline-flex items-center gap-1 rounded-full border-[0.5px] border-sensor-green/30 bg-sensor-green/10 px-2 py-0.5 text-[12px] text-sensor-green">
                  <CheckCircle2 className="h-3 w-3" aria-hidden="true" />
                  loaded
                </span>
              </div>
              <div className="font-mono text-[11px] text-app-secondary dark:text-app-darkSecondary">{classCount} classes</div>
            </div>
          ) : null}

          {error ? <p className="mt-3 text-[12px] text-sensor-red">{error}</p> : null}
        </div>

        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3 xl:grid-cols-1">
          <MetricCard label="Total samples" value={samples.length} />
          <MetricCard label="Words in vocab" value={storeVocabulary.length} />
          <MetricCard label="Model accuracy" value={percent(modelMetadata?.accuracy)} />
        </div>
      </aside>
    </div>
  );
}
