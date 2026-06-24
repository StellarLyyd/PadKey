import { Bluetooth, Cable, Loader2 } from "lucide-react";
import { useAppStore } from "../store";
import { useBLE } from "../ble/useBLE";
import { useSerial } from "../serial/useSerial";

export function TopBar() {
  const bleConnected = useAppStore((state) => state.bleConnected);
  const bleDeviceName = useAppStore((state) => state.bleDeviceName);
  const bleStatus = useAppStore((state) => state.bleStatus);
  const bleError = useAppStore((state) => state.bleError);
  const serialConnected = useAppStore((state) => state.serialConnected);
  const serialDeviceName = useAppStore((state) => state.serialDeviceName);
  const serialStatus = useAppStore((state) => state.serialStatus);
  const serialError = useAppStore((state) => state.serialError);
  const { connect, disconnect } = useBLE();
  const serial = useSerial();

  const connecting = bleStatus === "connecting";
  const hasError = bleStatus === "error";
  const label = bleConnected
    ? bleDeviceName ?? "OWO-SensorNode"
    : connecting
      ? "Scanning..."
        : hasError
          ? bleError ?? "Error"
          : "Connect BLE";
  const serialConnecting = serialStatus === "connecting";
  const serialHasError = serialStatus === "error";
  const serialLabel = serialConnected
    ? serialDeviceName ?? "Arduino USB"
    : serialConnecting
      ? "Opening USB..."
      : serialHasError
        ? serialError ?? "USB error"
        : "Connect USB";

  async function handleClick() {
    if (connecting) {
      return;
    }

    if (bleConnected) {
      disconnect();
      return;
    }

    await connect();
  }

  async function handleSerialClick() {
    if (serialConnecting) {
      return;
    }

    if (serialConnected) {
      await serial.disconnect();
      return;
    }

    await serial.connect();
  }

  return (
    <header className="flex h-[52px] shrink-0 items-center justify-between border-b-[0.5px] border-app-border px-5 dark:border-app-darkBorder">
      <div className="flex items-center gap-2 text-[14px] leading-none">
        <span className="font-medium text-app-ink dark:text-app-darkInk">PadKey</span>
        <span className="text-app-muted dark:text-app-darkSecondary">/</span>
        <span className="text-app-secondary dark:text-app-darkSecondary">silent speech studio</span>
      </div>

      <div className="flex items-center gap-2">
        <button
          type="button"
          onClick={handleClick}
          className={[
            "focus-ring inline-flex h-8 items-center gap-2 rounded-full border-[0.5px] px-3 text-[13px] transition-colors",
            bleConnected
              ? "border-sensor-green/30 bg-sensor-green/10 text-sensor-green"
              : hasError
                ? "border-sensor-red/30 bg-sensor-red/10 text-sensor-red"
                : "border-app-border text-app-ink hover:bg-app-surface dark:border-app-darkBorder dark:text-app-darkInk dark:hover:bg-app-darkSurface"
          ].join(" ")}
          aria-live="polite"
        >
          {connecting ? (
            <Loader2 className="h-3.5 w-3.5 animate-spin" aria-hidden="true" />
          ) : (
            <Bluetooth className="h-3.5 w-3.5" aria-hidden="true" />
          )}
          <span
            className={[
              "h-1.5 w-1.5 rounded-full",
              bleConnected ? "bg-sensor-green" : connecting ? "animate-pulse bg-app-muted" : hasError ? "bg-sensor-red" : "bg-app-muted"
            ].join(" ")}
            aria-hidden="true"
          />
          <span className="max-w-[180px] truncate">{label}</span>
        </button>

        <button
          type="button"
          onClick={handleSerialClick}
          className={[
            "focus-ring inline-flex h-8 items-center gap-2 rounded-full border-[0.5px] px-3 text-[13px] transition-colors",
            serialConnected
              ? "border-sensor-green/30 bg-sensor-green/10 text-sensor-green"
              : serialHasError
                ? "border-sensor-red/30 bg-sensor-red/10 text-sensor-red"
                : "border-app-border text-app-secondary hover:bg-app-surface dark:border-app-darkBorder dark:text-app-darkSecondary dark:hover:bg-app-darkSurface"
          ].join(" ")}
          aria-live="polite"
        >
          {serialConnecting ? (
            <Loader2 className="h-3.5 w-3.5 animate-spin" aria-hidden="true" />
          ) : (
            <Cable className="h-3.5 w-3.5" aria-hidden="true" />
          )}
          <span
            className={[
              "h-1.5 w-1.5 rounded-full",
              serialConnected ? "bg-sensor-green" : serialConnecting ? "animate-pulse bg-app-muted" : serialHasError ? "bg-sensor-red" : "bg-app-muted"
            ].join(" ")}
            aria-hidden="true"
          />
          <span className="max-w-[180px] truncate">{serialLabel}</span>
        </button>
      </div>
    </header>
  );
}
