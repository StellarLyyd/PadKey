import { useEffect, useRef } from "react";

interface StudioWaveformProps {
  original: Int16Array;
  processed: Int16Array;
  durationMs: number;
  trimStartMs: number;
  trimEndMs: number;
  positionSeconds: number;
  enhanced: boolean;
  overlays?: Array<{ samples: Int16Array; color: string }>;
  onSeek: (seconds: number) => void;
  onTrimStart: (milliseconds: number) => void;
  onTrimEnd: (milliseconds: number) => void;
}

function drawWaveform(
  context: CanvasRenderingContext2D,
  samples: Int16Array,
  width: number,
  height: number,
  color: string,
  lineWidth: number
) {
  if (!samples.length) return;
  context.strokeStyle = color;
  context.lineWidth = lineWidth;
  context.beginPath();
  const samplesPerPixel = Math.max(1, Math.floor(samples.length / width));
  for (let x = 0; x < width; x += 1) {
    const start = Math.min(samples.length - 1, x * samplesPerPixel);
    const end = Math.min(samples.length, start + samplesPerPixel);
    let minimum = 32767;
    let maximum = -32768;
    for (let index = start; index < end; index += 1) {
      minimum = Math.min(minimum, samples[index]);
      maximum = Math.max(maximum, samples[index]);
    }
    const top = height / 2 - (maximum / 32768) * height * 0.4;
    const bottom = height / 2 - (minimum / 32768) * height * 0.4;
    context.moveTo(x, top);
    context.lineTo(x, bottom);
  }
  context.stroke();
}

export function StudioWaveform(props: StudioWaveformProps) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const startPercent = props.durationMs ? (props.trimStartMs / props.durationMs) * 100 : 0;
  const endPercent = props.durationMs ? (props.trimEndMs / props.durationMs) * 100 : 100;
  const playheadPercent = props.durationMs ? ((props.positionSeconds * 1000) / props.durationMs) * 100 : 0;

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const dpr = window.devicePixelRatio || 1;
    const width = canvas.clientWidth;
    const height = canvas.clientHeight;
    canvas.width = Math.max(1, Math.floor(width * dpr));
    canvas.height = Math.max(1, Math.floor(height * dpr));
    const context = canvas.getContext("2d");
    if (!context) return;
    context.scale(dpr, dpr);
    context.clearRect(0, 0, width, height);
    context.strokeStyle = "rgba(27, 31, 36, .08)";
    context.lineWidth = 1;
    context.beginPath();
    context.moveTo(0, height / 2);
    context.lineTo(width, height / 2);
    context.stroke();
    drawWaveform(context, props.original, width, height, "rgba(62, 70, 78, .18)", 1);
    for (const overlay of props.overlays ?? []) {
      drawWaveform(context, overlay.samples, width, height, overlay.color, 1);
    }
    if (props.enhanced) drawWaveform(context, props.processed, width, height, "#1f5f55", 1.4);
    else drawWaveform(context, props.original, width, height, "#262b30", 1.35);
  }, [props.original, props.processed, props.enhanced, props.overlays]);

  function handleSeek(event: React.MouseEvent<HTMLDivElement>) {
    if ((event.target as HTMLElement).matches("input")) return;
    const bounds = event.currentTarget.getBoundingClientRect();
    const ratio = Math.max(0, Math.min(1, (event.clientX - bounds.left) / bounds.width));
    props.onSeek((props.durationMs * ratio) / 1000);
  }

  const minimumGap = Math.min(100, Math.max(10, props.durationMs / 20));

  return (
    <div className="studio-waveform" onClick={handleSeek} role="presentation">
      <canvas ref={canvasRef} aria-label="Audio waveform" />
      <div className="studio-waveform-mask studio-waveform-mask-left" style={{ width: `${startPercent}%` }} />
      <div className="studio-waveform-mask studio-waveform-mask-right" style={{ width: `${100 - endPercent}%` }} />
      <div className="studio-trim-line" style={{ left: `${startPercent}%` }} />
      <div className="studio-trim-line" style={{ left: `${endPercent}%` }} />
      <div className="studio-playhead" style={{ left: `${playheadPercent}%` }} />
      <label className="sr-only" htmlFor="studio-trim-start">Trim start</label>
      <input
        id="studio-trim-start"
        className="studio-trim-input studio-trim-start"
        type="range"
        min={0}
        max={Math.max(0, props.trimEndMs - minimumGap)}
        step={10}
        value={props.trimStartMs}
        onChange={(event) => props.onTrimStart(Number(event.target.value))}
      />
      <label className="sr-only" htmlFor="studio-trim-end">Trim end</label>
      <input
        id="studio-trim-end"
        className="studio-trim-input studio-trim-end"
        type="range"
        min={Math.min(props.durationMs, props.trimStartMs + minimumGap)}
        max={props.durationMs}
        step={10}
        value={props.trimEndMs}
        onChange={(event) => props.onTrimEnd(Number(event.target.value))}
      />
    </div>
  );
}
