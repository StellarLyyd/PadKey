import type { ReactNode } from "react";

interface SensorCardProps {
  label: string;
  value: ReactNode;
  percent: number;
  accent: "purple" | "blue" | "teal" | "gray";
  hint?: string;
}

const accentClasses = {
  purple: "bg-sensor-purple",
  blue: "bg-sensor-blue",
  teal: "bg-sensor-teal",
  gray: "bg-app-secondary dark:bg-app-darkSecondary"
};

export function SensorCard({ label, value, percent, accent, hint }: SensorCardProps) {
  const width = Math.max(0, Math.min(100, percent));

  return (
    <article className="thin-border rounded-xl bg-app-surface p-4 dark:bg-app-darkSurface">
      <div className="tool-label">{label}</div>
      <div className="mt-3 font-mono text-[22px] leading-none text-app-ink dark:text-app-darkInk">{value}</div>
      {hint ? <div className="mt-2 text-[12px] text-app-secondary dark:text-app-darkSecondary">{hint}</div> : null}
      <div className="mt-4 h-[3px] overflow-hidden rounded-full bg-black/10 dark:bg-white/10">
        <div className={`h-full rounded-full ${accentClasses[accent]}`} style={{ width: `${width}%` }} />
      </div>
    </article>
  );
}
