import { Wind } from "lucide-react";
import { useAppStore } from "../../store";
import type { CaptureMode } from "../../types";

const profiles: Array<{ id: CaptureMode; label: string; description: string }> = [
  { id: "egressive", label: "Outward", description: "Normal outward-breath speech and whisper capture." },
  { id: "ingressive", label: "Inward", description: "Lower VAD threshold and shorter minimum utterances." }
];

export function CaptureProfilePanel() {
  const captureMode = useAppStore((state) => state.captureMode);
  const sessionRecording = useAppStore((state) => state.sessionRecording);
  const setCaptureMode = useAppStore((state) => state.setCaptureMode);

  return (
    <section className="control-section" aria-labelledby="profile-title">
      <div className="section-kicker">Capture profile</div>
      <h2 id="profile-title" className="section-title">Breath direction</h2>
      <p className="section-copy">The profile changes segmentation sensitivity and is saved with exported training data.</p>
      <div className="segmented profile-segmented" role="radiogroup" aria-label="Breath direction">
        {profiles.map((profile) => (
          <button
            key={profile.id}
            type="button"
            role="radio"
            aria-checked={captureMode === profile.id}
            className={captureMode === profile.id ? "segmented-button is-active" : "segmented-button"}
            disabled={sessionRecording}
            onClick={() => setCaptureMode(profile.id)}
          >
            <Wind size={14} aria-hidden="true" />
            {profile.label}
          </button>
        ))}
      </div>
      <p className="profile-note">{profiles.find((profile) => profile.id === captureMode)?.description}</p>
    </section>
  );
}
