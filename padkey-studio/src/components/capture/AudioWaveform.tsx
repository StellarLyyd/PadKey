import { useEffect, useRef } from "react";

export function AudioWaveform({ samples }: { samples: Int16Array }) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);

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
    context.strokeStyle = "rgba(24,29,38,.12)";
    context.lineWidth = 1;
    context.beginPath();
    context.moveTo(0, height / 2);
    context.lineTo(width, height / 2);
    context.stroke();

    if (!samples.length) return;
    context.strokeStyle = "#aa2d00";
    context.lineWidth = 1.25;
    context.beginPath();
    const samplesPerPixel = Math.max(1, Math.floor(samples.length / width));
    for (let x = 0; x < width; x += 1) {
      const start = Math.min(samples.length - 1, x * samplesPerPixel);
      const end = Math.min(samples.length, start + samplesPerPixel);
      let min = 32767;
      let max = -32768;
      for (let index = start; index < end; index += 1) {
        min = Math.min(min, samples[index]);
        max = Math.max(max, samples[index]);
      }
      const top = height / 2 - (max / 32768) * (height * 0.42);
      const bottom = height / 2 - (min / 32768) * (height * 0.42);
      context.moveTo(x, top);
      context.lineTo(x, bottom);
    }
    context.stroke();
  }, [samples]);

  return <canvas ref={canvasRef} className="audio-waveform" aria-label="Recent raw PCM audio waveform" />;
}
