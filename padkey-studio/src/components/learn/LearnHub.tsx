import { useMemo, useState } from "react";
import {
  ArrowDown,
  ArrowRight,
  BookOpen,
  BrainCircuit,
  Cable,
  CheckCircle2,
  Database,
  HelpCircle,
  Mic2,
  RadioTower,
  Search,
  SlidersHorizontal,
  Waves
} from "lucide-react";
import { glossaryCategories, padkeyGlossary } from "../../knowledge/padkeyGlossary";
import type { GlossaryCategory } from "../../knowledge/padkeyGlossary";

type LearnSection = "how" | "dictionary";
type CategoryFilter = "all" | GlossaryCategory;

const howSteps = [
  {
    title: "Sensors capture two kinds of evidence",
    body: "The INMP441 captures a digital airborne-audio waveform. The piezo captures contact vibration as changing voltage through the ESP32 ADC.",
    note: "These signals describe the same attempt from different physical paths."
  },
  {
    title: "Firmware samples and packages the data",
    body: "The ESP32-S3 reads I2S microphone samples and piezo values, calculates telemetry such as peaks and thresholds, and packages ordered messages.",
    note: "Firmware decides whether the frontend receives only summary telemetry or the complete PCM waveform."
  },
  {
    title: "USB, BLE, or Wi-Fi transports the stream",
    body: "USB and Wi-Fi carry continuous recording audio. BLE saves power while carrying telemetry, battery status, and waveform snapshots.",
    note: "Sequence numbers let the frontend detect missing PCM packets."
  },
  {
    title: "The frontend buffers and records",
    body: "PadKey Studio plots recent telemetry, keeps a short PCM ring buffer, and records lossless session data before post-processing.",
    note: "Original capture is preserved so processing settings can be changed later."
  },
  {
    title: "The selected recognition path runs",
    body: "Speech Lab segments PCM, cleans it, and sends it to Whisper. Signal Trainer converts labeled telemetry batches into features and trains a custom phrase classifier.",
    note: "Whisper is open-ended; the custom signal classifier is limited to its trained labels."
  },
  {
    title: "Results become text and reusable evidence",
    body: "Whisper returns a transcript. The signal model commits stable, confident phrase predictions into dictation. Both workflows export data for later analysis.",
    note: "Saved datasets are the evidence needed to improve future PadKey models."
  }
];

function HowItWorks() {
  return (
    <div className="how-workspace">
      <section className="learn-principle">
        <div className="learn-principle-icon"><Waves size={22} aria-hidden="true" /></div>
        <div>
          <div className="section-kicker">The central idea</div>
          <h2>PadKey has two recognition paths, not one.</h2>
          <p><b>PCM audio</b> contains the waveform needed for open-ended Whisper transcription. <b>Telemetry batches</b> contain simplified signal patterns that can learn a small personal phrase vocabulary.</p>
        </div>
      </section>

      <section className="system-map" aria-labelledby="system-map-title">
        <div className="learn-section-heading">
          <div><h2 id="system-map-title">System map</h2><p>Follow one physical attempt from your body to usable text.</p></div>
        </div>
        <div className="flow-trunk" aria-label="PadKey capture pipeline">
          <div className="flow-node sensor-node"><Mic2 size={18} aria-hidden="true" /><b>Sensors</b><span>INMP441 + piezo</span></div>
          <ArrowRight className="flow-arrow-horizontal arrow-one" size={18} aria-hidden="true" />
          <div className="flow-node firmware-node"><SlidersHorizontal size={18} aria-hidden="true" /><b>ESP32 firmware</b><span>Sample + packetize</span></div>
          <ArrowRight className="flow-arrow-horizontal arrow-two" size={18} aria-hidden="true" />
          <div className="flow-node transport-node"><Cable size={18} aria-hidden="true" /><b>Transport</b><span>USB, BLE, or Wi-Fi</span></div>
          <ArrowRight className="flow-arrow-horizontal arrow-three" size={18} aria-hidden="true" />
          <div className="flow-node browser-node"><Database size={18} aria-hidden="true" /><b>Browser capture</b><span>Buffer + record</span></div>
        </div>
        <ArrowDown className="flow-branch-arrow" size={18} aria-hidden="true" />
        <div className="flow-branches">
          <article className="flow-branch telemetry-branch">
            <div className="flow-branch-label"><RadioTower size={17} aria-hidden="true" /> Telemetry path</div>
            <h3>Signal Trainer</h3>
            <p>Batched frames → statistical features → your trained phrase classifier → confidence + stability gate → dictated phrases.</p>
            <span>Best for a small personalized vocabulary and non-audio sensor combinations.</span>
          </article>
          <article className="flow-branch pcm-branch">
            <div className="flow-branch-label"><BrainCircuit size={17} aria-hidden="true" /> PCM path</div>
            <h3>Speech Lab</h3>
            <p>Raw waveform → VAD + segmentation → DSP → Whisper → open-ended transcript.</p>
            <span>Best when the microphone preserves enough speech detail to reconstruct words.</span>
          </article>
        </div>
      </section>

      <section className="how-steps" aria-labelledby="step-title">
        <div className="learn-section-heading">
          <div><h2 id="step-title">What happens at each stage</h2><p>The pipeline in plain language, including the decision that matters at every stage.</p></div>
        </div>
        <ol>
          {howSteps.map((step, index) => (
            <li key={step.title}>
              <span className="step-number mono">{String(index + 1).padStart(2, "0")}</span>
              <div><h3>{step.title}</h3><p>{step.body}</p><small>{step.note}</small></div>
            </li>
          ))}
        </ol>
      </section>

      <section className="path-comparison" aria-labelledby="comparison-title">
        <div className="learn-section-heading">
          <div><h2 id="comparison-title">Which path should I use?</h2><p>Use both during research; they answer different questions.</p></div>
        </div>
        <div className="comparison-table" role="table" aria-label="Signal Trainer and Speech Lab comparison">
          <div className="comparison-row comparison-head" role="row"><span>Question</span><span>Signal Trainer</span><span>Speech Lab</span></div>
          <div className="comparison-row" role="row"><b>Input</b><span>Low-rate telemetry windows</span><span>16 kHz PCM waveform</span></div>
          <div className="comparison-row" role="row"><b>What it learns</b><span>Your labeled signal patterns</span><span>Uses a pretrained Whisper model</span></div>
          <div className="comparison-row" role="row"><b>Possible output</b><span>Only trained labels</span><span>Open-ended words and sentences</span></div>
          <div className="comparison-row" role="row"><b>Needs training here?</b><span>Yes—multiple batches per label</span><span>No local training required</span></div>
          <div className="comparison-row" role="row"><b>Main limitation</b><span>Cannot reconstruct arbitrary speech</span><span>Needs intelligible raw audio</span></div>
        </div>
      </section>

      <section className="learn-checklist" aria-labelledby="routine-title">
        <div className="learn-section-heading">
          <div><h2 id="routine-title">A reliable training routine</h2><p>Use this sequence when collecting real PadKey signal data.</p></div>
        </div>
        <div className="checklist-grid">
          {[
            "Capture `rest` in every session and sensor placement.",
            "Collect 5–10 varied batches per phrase before trusting accuracy.",
            "Keep one attempt inside each batch; do not label transition noise as speech.",
            "Change pressure, timing, and quiet background conditions deliberately.",
            "Judge held-out accuracy and live behavior—not training loss alone.",
            "Export datasets before clearing them so failures can be reproduced."
          ].map((item) => <div key={item}><CheckCircle2 size={16} aria-hidden="true" /><span>{item}</span></div>)}
        </div>
      </section>
    </div>
  );
}

function Dictionary() {
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState<CategoryFilter>("all");
  const normalizedQuery = query.trim().toLowerCase();
  const filtered = useMemo(() => padkeyGlossary.filter((entry) => {
    const categoryMatches = category === "all" || entry.category === category;
    const text = [entry.term, entry.definition, entry.importance, ...(entry.aliases ?? [])].join(" ").toLowerCase();
    return categoryMatches && (!normalizedQuery || text.includes(normalizedQuery));
  }), [category, normalizedQuery]);

  return (
    <div className="dictionary-workspace">
      <section className="dictionary-tools" aria-label="Dictionary filters">
        <label className="dictionary-search">
          <Search size={16} aria-hidden="true" />
          <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search a term, abbreviation, or idea" aria-label="Search PadKey dictionary" />
          {query ? <button type="button" onClick={() => setQuery("")}>Clear</button> : null}
        </label>
        <div className="dictionary-categories" aria-label="Term category">
          <button type="button" className={category === "all" ? "is-active" : ""} onClick={() => setCategory("all")}>All <span>{padkeyGlossary.length}</span></button>
          {glossaryCategories.map((item) => {
            const count = padkeyGlossary.filter((entry) => entry.category === item.id).length;
            return <button type="button" key={item.id} className={category === item.id ? "is-active" : ""} onClick={() => setCategory(item.id)}>{item.label} <span>{count}</span></button>;
          })}
        </div>
      </section>

      <div className="dictionary-summary">
        <span><b>{filtered.length}</b> {filtered.length === 1 ? "term" : "terms"}</span>
        <span>Definitions describe PadKey’s current prototype—not every possible use of the term.</span>
      </div>

      {filtered.length ? (
        <div className="glossary-grid">
          {filtered.map((entry) => {
            const categoryLabel = glossaryCategories.find((item) => item.id === entry.category)?.label ?? entry.category;
            return (
              <article className="glossary-entry" key={entry.term}>
                <header><h2>{entry.term}</h2><span>{categoryLabel}</span></header>
                {entry.aliases?.length ? <div className="glossary-aliases">Also: {entry.aliases.join(", ")}</div> : null}
                <p>{entry.definition}</p>
                <div className="glossary-importance"><HelpCircle size={14} aria-hidden="true" /><span><b>Why it matters:</b> {entry.importance}</span></div>
              </article>
            );
          })}
        </div>
      ) : (
        <div className="dictionary-empty"><Search size={22} aria-hidden="true" /><h2>No matching term</h2><p>Try a broader word or clear the selected category.</p></div>
      )}
    </div>
  );
}

export function LearnHub() {
  const [section, setSection] = useState<LearnSection>("how");

  return (
    <section className="learn-hub" aria-labelledby="learn-title">
      <header className="learn-header">
        <div className="learn-header-copy">
          <div className="learn-icon"><BookOpen size={20} aria-hidden="true" /></div>
          <div>
            <div className="section-kicker">PadKey field guide</div>
            <h1 id="learn-title" className="workspace-title">Understand the system you are building</h1>
            <p className="panel-copy">A practical explanation of the complete signal path and the vocabulary used across hardware, audio, firmware, and machine learning.</p>
          </div>
        </div>
        <div className="learn-secondary-tabs" role="tablist" aria-label="Learn sections">
          <button type="button" role="tab" aria-selected={section === "how"} className={section === "how" ? "is-active" : ""} onClick={() => setSection("how")}>How it works</button>
          <button type="button" role="tab" aria-selected={section === "dictionary"} className={section === "dictionary" ? "is-active" : ""} onClick={() => setSection("dictionary")}>Dictionary <span>{padkeyGlossary.length}</span></button>
        </div>
      </header>
      {section === "how" ? <HowItWorks /> : <Dictionary />}
    </section>
  );
}
