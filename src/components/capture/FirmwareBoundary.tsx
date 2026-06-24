import { Check, FileCode2 } from "lucide-react";

export function FirmwareBoundary() {
  return (
    <section className="control-section firmware-boundary" aria-labelledby="firmware-title">
      <div className="section-kicker">Firmware boundary</div>
      <h2 id="firmware-title" className="section-title">Recording sources</h2>
      <ul className="boundary-list">
        <li><Check size={15} aria-hidden="true" /><span>INMP441 packets stay on the digital microphone track</span></li>
        <li><Check size={15} aria-hidden="true" /><span>MAX4466 and piezo packets stay on their own tracks</span></li>
        <li><Check size={15} aria-hidden="true" /><span>MacBook baseline is captured locally and never relabeled as PadKey</span></li>
        <li><Check size={15} aria-hidden="true" /><span>BLE records all three sensors at 8 kHz; USB and Wi-Fi carry all three at 16 kHz</span></li>
      </ul>
      <details className="protocol-details">
        <summary><FileCode2 size={15} aria-hidden="true" /> Accepted stream protocol</summary>
        <div className="protocol-body">
          <code>INMP441:1820,MAX4466:840,NoiseFloor:1000,Gate:1600,PIEZO:114</code>
          <code>{`{"type":"audio","channel":"inmp441","format":"pcm_s16le","sampleRate":16000,"pcm":"…"}`}</code>
        </div>
      </details>
    </section>
  );
}
