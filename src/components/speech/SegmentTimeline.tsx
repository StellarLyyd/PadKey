import type { SpeechSegment } from "../../types";

export function SegmentTimeline({
  segments,
  totalMs,
  selectedId,
  onSelect
}: {
  segments: SpeechSegment[];
  totalMs: number;
  selectedId: string | null;
  onSelect: (id: string) => void;
}) {
  return (
    <div className="segment-timeline" aria-label="Detected speech timeline">
      <div className="timeline-track">
        {segments.map((segment) => (
          <button
            key={segment.id}
            type="button"
            className={segment.id === selectedId ? "timeline-segment is-selected" : "timeline-segment"}
            style={{
              left: `${(segment.startMs / Math.max(totalMs, 1)) * 100}%`,
              width: `${Math.max(0.7, (segment.durationMs / Math.max(totalMs, 1)) * 100)}%`
            }}
            onClick={() => onSelect(segment.id)}
            aria-label={`${segment.id}, ${(segment.startMs / 1000).toFixed(2)} to ${(segment.endMs / 1000).toFixed(2)} seconds`}
            title={`${segment.id} · ${segment.source}`}
          />
        ))}
      </div>
      <div className="timeline-scale mono"><span>0:00</span><span>{(totalMs / 1000).toFixed(1)}s</span></div>
    </div>
  );
}
