import { useMemo, useState } from "react";
import {
  CategoryScale,
  Chart as ChartJS,
  LinearScale,
  LineController,
  LineElement,
  PointElement,
  Tooltip
} from "chart.js";
import type { ChartData, ChartOptions } from "chart.js";
import { Line } from "react-chartjs-2";
import type { AudioChannel, SensorFrame } from "../../types";

ChartJS.register(CategoryScale, LinearScale, LineController, LineElement, PointElement, Tooltip);

export function SignalChart({ frames, lockedChannel }: { frames: SensorFrame[]; lockedChannel?: Exclude<AudioChannel, "macbook"> }) {
  const [channels, setChannels] = useState({ inmp441: true, max4466: true, piezo: true });
  const visible = frames.slice(-120);
  const effectiveChannels = lockedChannel
    ? {
        inmp441: lockedChannel === "inmp441",
        max4466: lockedChannel === "max4466",
        piezo: lockedChannel === "piezo"
      }
    : channels;
  const data = useMemo<ChartData<"line">>(() => ({
    labels: visible.map((_, index) => String(index + 1)),
    datasets: [
      {
        label: "Microphone peak",
        data: visible.map((frame) => frame.mic),
        borderColor: "#315caa",
        backgroundColor: "#315caa",
        borderWidth: 1.5,
        pointRadius: 0,
        tension: 0.18,
        yAxisID: "mic",
        hidden: !effectiveChannels.inmp441
      },
      {
        label: "Adaptive gate",
        data: visible.map((frame) => frame.thresholdMic),
        borderColor: "rgba(49, 92, 170, .4)",
        borderDash: [5, 5],
        borderWidth: 1,
        pointRadius: 0,
        yAxisID: "mic",
        hidden: !effectiveChannels.inmp441
      },
      {
        label: "Noise floor",
        data: visible.map((frame) => frame.noiseFloor),
        borderColor: "rgba(109, 115, 124, .65)",
        borderDash: [2, 4],
        borderWidth: 1,
        pointRadius: 0,
        yAxisID: "mic",
        hidden: !effectiveChannels.inmp441
      },
      {
        label: "MAX4466 peak",
        data: visible.map((frame) => frame.max4466),
        borderColor: "#7a568d",
        backgroundColor: "#7a568d",
        borderWidth: 1.5,
        pointRadius: 0,
        tension: 0.18,
        yAxisID: "mic",
        hidden: !effectiveChannels.max4466
      },
      {
        label: "Piezo",
        data: visible.map((frame) => frame.piezo),
        borderColor: "#246b50",
        backgroundColor: "#246b50",
        borderWidth: 1.5,
        pointRadius: 0,
        tension: 0.18,
        yAxisID: "piezo",
        hidden: !effectiveChannels.piezo
      },
      {
        label: "Piezo threshold",
        data: visible.map((frame) => frame.thresholdPiezo),
        borderColor: "rgba(36, 107, 80, .4)",
        borderDash: [5, 5],
        borderWidth: 1,
        pointRadius: 0,
        yAxisID: "piezo",
        hidden: !effectiveChannels.piezo
      }
    ]
  }), [effectiveChannels.inmp441, effectiveChannels.max4466, effectiveChannels.piezo, visible]);

  const options = useMemo<ChartOptions<"line">>(() => ({
    responsive: true,
    maintainAspectRatio: false,
    animation: false,
    interaction: { intersect: false, mode: "index" },
    plugins: {
      legend: { display: false },
      tooltip: { displayColors: true, backgroundColor: "#171b22", padding: 10 }
    },
    scales: {
      x: {
        grid: { display: false },
        border: { color: "rgba(24,29,38,.12)" },
        ticks: { display: false }
      },
      mic: {
        type: "linear",
        position: "left",
        beginAtZero: true,
        suggestedMax: 2400,
        grid: { color: "rgba(24,29,38,.07)" },
        border: { display: false },
        ticks: { color: "#6d737c", font: { family: "ui-monospace, SFMono-Regular, Menlo, monospace", size: 10 } },
        title: { display: true, text: "MIC peak", color: "#315caa", font: { size: 11, weight: 500 } }
      },
      piezo: {
        type: "linear",
        position: "right",
        beginAtZero: true,
        suggestedMax: 400,
        grid: { drawOnChartArea: false },
        border: { display: false },
        ticks: { color: "#6d737c", font: { family: "ui-monospace, SFMono-Regular, Menlo, monospace", size: 10 } },
        title: { display: true, text: "Piezo ADC", color: "#246b50", font: { size: 11, weight: 500 } }
      }
    }
  }), []);

  return (
    <div className="signal-chart-block">
      <div className="signal-channel-toggles" aria-label="Visible signal channels">
        {([
          ["inmp441", "INMP441"],
          ["max4466", "MAX4466"],
          ["piezo", "Piezo"]
        ] as const).filter(([key]) => !lockedChannel || key === lockedChannel).map(([key, label]) => (
          <button type="button" key={key} className={effectiveChannels[key] ? "is-active" : ""} aria-pressed={effectiveChannels[key]} disabled={Boolean(lockedChannel)} onClick={() => setChannels((current) => ({ ...current, [key]: !current[key] }))}>
            <span /> {label}
          </button>
        ))}
        {lockedChannel ? <small>BLE displays only the selected wireless input.</small> : null}
      </div>
      <div className="chart-stage">
        {visible.length ? <Line data={data} options={options} /> : (
          <div className="empty-chart">
            <div className="empty-chart-line" aria-hidden="true" />
            <strong>Waiting for your first sensor frame</strong>
            <span>Connect the XIAO ESP32-S3 over USB, BLE, or Wi-Fi.</span>
          </div>
        )}
      </div>
    </div>
  );
}
