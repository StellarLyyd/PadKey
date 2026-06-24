import { useMemo } from "react";
import { useAppStore } from "../store";

export function StatusBar() {
  const bleConnected = useAppStore((state) => state.bleConnected);
  const bleDeviceName = useAppStore((state) => state.bleDeviceName);
  const bleStatus = useAppStore((state) => state.bleStatus);
  const bleError = useAppStore((state) => state.bleError);
  const serialConnected = useAppStore((state) => state.serialConnected);
  const serialDeviceName = useAppStore((state) => state.serialDeviceName);
  const serialStatus = useAppStore((state) => state.serialStatus);
  const serialError = useAppStore((state) => state.serialError);
  const frameHistory = useAppStore((state) => state.frameHistory);
  const recording = useAppStore((state) => state.recording);
  const selectedWord = useAppStore((state) => state.selectedWord);
  const samples = useAppStore((state) => state.samples);
  const modelLoaded = useAppStore((state) => state.modelLoaded);
  const modelMetadata = useAppStore((state) => state.modelMetadata);

  const message = useMemo(() => {
    if (serialStatus === "connecting") {
      return "opening USB serial port at 115200 baud";
    }

    if (serialStatus === "error") {
      return `USB error - ${serialError ?? "serial connection failed"}`;
    }

    if (bleStatus === "connecting") {
      return "scanning for OWO-SensorNode";
    }

    if (bleStatus === "error") {
      return `BLE error - ${bleError ?? "connection failed"}`;
    }

    if (recording) {
      const count = samples.filter((sample) => sample.label === selectedWord).length;
      return `recording "${selectedWord}" - ${count} samples captured`;
    }

    if (!bleConnected && !serialConnected) {
      return "waiting for USB serial or BLE - close Arduino Serial Monitor before USB";
    }

    if (modelLoaded) {
      const classes = modelMetadata?.classes.length ?? 0;
      return `model loaded - ${classes || "unknown"} classes`;
    }

    const lastSecond = Date.now() - 1000;
    const fps = frameHistory.filter((frame) => frame.ts >= lastSecond).length;
    const source = serialConnected ? serialDeviceName ?? "Arduino USB" : bleDeviceName ?? "OWO-SensorNode";
    return `live - ${fps} fps from ${source}`;
  }, [
    bleConnected,
    bleDeviceName,
    bleError,
    bleStatus,
    frameHistory,
    modelLoaded,
    modelMetadata,
    recording,
    samples,
    selectedWord,
    serialConnected,
    serialDeviceName,
    serialError,
    serialStatus
  ]);

  return (
    <footer className="flex h-7 shrink-0 items-center border-t-[0.5px] border-app-border px-5 font-mono text-[11px] text-app-secondary dark:border-app-darkBorder dark:text-app-darkSecondary">
      {message}
    </footer>
  );
}
