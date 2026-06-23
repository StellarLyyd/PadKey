import { useEffect, useMemo, useRef, useState } from "react";
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
import { CHANNELS } from "../channels";
import { useAppStore } from "../store";
import type { SensorFrame } from "../types";
import type { ChannelKey } from "../types";

ChartJS.register(CategoryScale, LinearScale, LineController, LineElement, PointElement, Tooltip);

interface SignalPlotterProps {
  frames: SensorFrame[];
}

type YScaleMode = "auto" | "low" | "full" | "manual";
type PlotWindowSize = 30 | 60 | 120;

const datasets = CHANNELS.map((channel) => ({
  key: channel.key,
  label: channel.shortLabel,
  color:
    channel.key === "pz1"
      ? "#7F77DD"
      : channel.key === "pz2"
        ? "#A39DF0"
        : channel.key === "mic"
          ? "#378ADD"
          : channel.key === "mus"
            ? "#0F766E"
            : channel.key === "qt"
              ? "#1D9E75"
              : "#8A8A8A"
}));

function normalizeValue(frame: SensorFrame, key: ChannelKey) {
  return frame[key];
}

function clampAdc(value: number) {
  return Math.max(0, Math.min(1023, value));
}

function niceTickStep(range: number) {
  if (range <= 30) {
    return 5;
  }
  if (range <= 80) {
    return 10;
  }
  if (range <= 160) {
    return 20;
  }
  if (range <= 320) {
    return 40;
  }
  return 128;
}

export function SignalPlotter({ frames }: SignalPlotterProps) {
  const chartRef = useRef<ChartJS<"line"> | null>(null);
  const [windowSize, setWindowSize] = useState<PlotWindowSize>(60);
  const [yScaleMode, setYScaleMode] = useState<YScaleMode>("auto");
  const [manualMin, setManualMin] = useState("0");
  const [manualMax, setManualMax] = useState("120");
  const visibleFrames = useMemo(() => frames.slice(-windowSize), [frames, windowSize]);
  const activeChannels = useAppStore((state) => state.activeChannels);
  const activeDatasets = useMemo(() => datasets.filter((dataset) => activeChannels[dataset.key]), [activeChannels]);

  const autoRange = useMemo(() => {
    const values = visibleFrames.flatMap((frame) => activeDatasets.map((dataset) => normalizeValue(frame, dataset.key)));

    if (values.length === 0) {
      return { min: 0, max: 120 };
    }

    const minValue = Math.min(...values);
    const maxValue = Math.max(...values);
    const span = Math.max(1, maxValue - minValue);
    const padding = Math.max(4, span * 0.2);
    const min = clampAdc(Math.floor(minValue - padding));
    const max = clampAdc(Math.ceil(maxValue + padding));

    if (max - min < 12) {
      const center = (minValue + maxValue) / 2;
      return {
        min: clampAdc(Math.floor(center - 8)),
        max: clampAdc(Math.ceil(center + 8))
      };
    }

    return { min, max };
  }, [activeDatasets, visibleFrames]);

  const yRange = useMemo(() => {
    if (yScaleMode === "full") {
      return { min: 0, max: 1023 };
    }

    if (yScaleMode === "low") {
      return { min: 0, max: 120 };
    }

    if (yScaleMode === "manual") {
      const parsedMin = Number(manualMin);
      const parsedMax = Number(manualMax);

      if (Number.isFinite(parsedMin) && Number.isFinite(parsedMax) && parsedMax > parsedMin) {
        return {
          min: clampAdc(parsedMin),
          max: clampAdc(parsedMax)
        };
      }

      return { min: 0, max: 120 };
    }

    return autoRange;
  }, [autoRange, manualMax, manualMin, yScaleMode]);

  const yTickStep = niceTickStep(yRange.max - yRange.min);

  const data = useMemo<ChartData<"line">>(
    () => ({
      labels: Array.from({ length: windowSize }, (_, index) => String(index + 1)),
      datasets: activeDatasets.map((dataset) => ({
        label: dataset.label,
        data: [],
        borderColor: dataset.color,
        backgroundColor: dataset.color,
        borderWidth: 1.5,
        pointRadius: 0,
        tension: 0.25
      }))
    }),
    [activeDatasets, windowSize]
  );

  const options = useMemo<ChartOptions<"line">>(
    () => ({
      responsive: true,
      maintainAspectRatio: false,
      animation: false,
      interaction: {
        intersect: false,
        mode: "index"
      },
      plugins: {
        legend: {
          display: false
        },
        tooltip: {
          enabled: true,
          displayColors: false
        }
      },
      scales: {
        x: {
          display: true,
          title: {
            display: true,
            text: "Frame index in rolling window",
            color: "rgba(138,138,138,0.9)",
            font: {
              size: 11,
              family: "Inter, system-ui, sans-serif",
              weight: 500
            }
          },
          ticks: {
            color: "rgba(138,138,138,0.9)",
            maxRotation: 0,
            autoSkip: true,
            callback: (_, index, ticks) => {
              if (index === 0) {
                return "oldest";
              }
              if (index === ticks.length - 1) {
                return "newest";
              }
              return index % 20 === 0 ? String(index) : "";
            }
          },
          grid: {
            display: false
          },
          border: {
            color: "rgba(138,138,138,0.14)"
          }
        },
        y: {
          min: yRange.min,
          max: yRange.max,
          title: {
            display: true,
            text: `Signal amplitude (ADC), y ${yRange.min}-${yRange.max}`,
            color: "rgba(138,138,138,0.9)",
            font: {
              size: 11,
              family: "Inter, system-ui, sans-serif",
              weight: 500
            }
          },
          ticks: {
            color: "rgba(138,138,138,0.9)",
            stepSize: yTickStep,
            maxTicksLimit: 8
          },
          border: {
            color: "rgba(138,138,138,0.14)"
          },
          grid: {
            color: (context) => (context.tick.value === 0 ? "rgba(138,138,138,0.20)" : "rgba(138,138,138,0.08)")
          }
        }
      }
    }),
    [yRange.max, yRange.min, yTickStep]
  );

  useEffect(() => {
    const chart = chartRef.current;
    if (!chart) {
      return;
    }

    chart.data.labels = visibleFrames.map((_, index) => String(index + 1));
    chart.data.datasets = activeDatasets.map((dataset) => ({
      label: dataset.label,
      data: visibleFrames.map((frame) => normalizeValue(frame, dataset.key)),
      borderColor: dataset.color,
      backgroundColor: dataset.color,
      borderWidth: 1.5,
      pointRadius: 0,
      tension: 0.25
    }));
    chart.update("none");
  }, [activeDatasets, frames, visibleFrames]);

  return (
    <section className="thin-border rounded-xl bg-app-surface p-4 dark:bg-app-darkSurface">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-[15px] font-medium text-app-ink dark:text-app-darkInk">Signal stream</h2>
          <p className="mt-1 text-[13px] text-app-secondary dark:text-app-darkSecondary">
            Rolling view of the last {Math.max(visibleFrames.length, 1)} frames. Y-axis zoom changes visibility only; raw capture is unchanged.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-3">
          {datasets.map((dataset) => (
            <div key={dataset.key} className="flex items-center gap-1.5 text-[12px] text-app-secondary dark:text-app-darkSecondary">
              <span className={activeChannels[dataset.key] ? "h-2 w-2 rounded-full" : "h-2 w-2 rounded-full opacity-25"} style={{ backgroundColor: dataset.color }} aria-hidden="true" />
              {dataset.label}
            </div>
          ))}
        </div>
      </div>
      <div className="mt-4 grid gap-3 rounded-lg border-[0.5px] border-app-border bg-white/60 p-3 dark:border-app-darkBorder dark:bg-app-darkBg/50 lg:grid-cols-[minmax(0,1fr)_auto]">
        <div className="flex flex-wrap items-center gap-2">
          <span className="font-mono text-[11px] uppercase tracking-[0.16em] text-app-muted dark:text-app-darkSecondary">Y zoom</span>
          {[
            { key: "auto", label: "Auto fit" },
            { key: "low", label: "Low 0-120" },
            { key: "full", label: "Full 0-1023" },
            { key: "manual", label: "Manual" }
          ].map((item) => (
            <button
              key={item.key}
              type="button"
              onClick={() => setYScaleMode(item.key as YScaleMode)}
              className={[
                "focus-ring h-8 rounded-full border-[0.5px] px-3 text-[12px] transition-colors",
                yScaleMode === item.key
                  ? "border-app-ink bg-app-ink text-white dark:border-app-darkInk dark:bg-app-darkInk dark:text-app-darkBg"
                  : "border-app-border text-app-secondary hover:bg-app-surface dark:border-app-darkBorder dark:text-app-darkSecondary dark:hover:bg-app-darkSurface"
              ].join(" ")}
            >
              {item.label}
            </button>
          ))}
          <label className="flex items-center gap-1.5 text-[12px] text-app-secondary dark:text-app-darkSecondary">
            min
            <input
              value={manualMin}
              onChange={(event) => {
                setManualMin(event.target.value);
                setYScaleMode("manual");
              }}
              inputMode="numeric"
              className="h-8 w-16 rounded-md border-[0.5px] border-app-border bg-white px-2 font-mono text-[12px] text-app-ink outline-none focus:border-app-ink dark:border-app-darkBorder dark:bg-app-darkBg dark:text-app-darkInk dark:focus:border-app-darkInk"
            />
          </label>
          <label className="flex items-center gap-1.5 text-[12px] text-app-secondary dark:text-app-darkSecondary">
            max
            <input
              value={manualMax}
              onChange={(event) => {
                setManualMax(event.target.value);
                setYScaleMode("manual");
              }}
              inputMode="numeric"
              className="h-8 w-16 rounded-md border-[0.5px] border-app-border bg-white px-2 font-mono text-[12px] text-app-ink outline-none focus:border-app-ink dark:border-app-darkBorder dark:bg-app-darkBg dark:text-app-darkInk dark:focus:border-app-darkInk"
            />
          </label>
          <span className="font-mono text-[11px] text-app-muted dark:text-app-darkSecondary">shown: {yRange.min}-{yRange.max} ADC</span>
        </div>
        <div className="flex flex-wrap items-center gap-2 lg:justify-end">
          <span className="font-mono text-[11px] uppercase tracking-[0.16em] text-app-muted dark:text-app-darkSecondary">Window</span>
          {([30, 60, 120] as PlotWindowSize[]).map((size) => (
            <button
              key={size}
              type="button"
              onClick={() => setWindowSize(size)}
              className={[
                "focus-ring h-8 rounded-full border-[0.5px] px-3 text-[12px] transition-colors",
                windowSize === size
                  ? "border-app-ink bg-app-ink text-white dark:border-app-darkInk dark:bg-app-darkInk dark:text-app-darkBg"
                  : "border-app-border text-app-secondary hover:bg-app-surface dark:border-app-darkBorder dark:text-app-darkSecondary dark:hover:bg-app-darkSurface"
              ].join(" ")}
            >
              {size} frames
            </button>
          ))}
        </div>
      </div>
      <div className="mt-4 h-[360px]">
        <Line ref={chartRef} data={data} options={options} />
      </div>
    </section>
  );
}
