export type PadKeyNativeEvent = CustomEvent<Record<string, unknown> & { type: string }>;

declare global {
  interface Window {
    __PADKEY_AGENT_URL__?: string;
    __PADKEY_NATIVE_APP__?: boolean;
    webkit?: {
      messageHandlers?: {
        padkeyBridge?: { postMessage: (message: Record<string, unknown>) => void };
      };
    };
  }
}

export function hasNativePadKeyBridge() {
  return Boolean(window.__PADKEY_NATIVE_APP__ && window.webkit?.messageHandlers?.padkeyBridge);
}

export function postNativePadKeyMessage(message: Record<string, unknown>) {
  window.webkit?.messageHandlers?.padkeyBridge?.postMessage(message);
}

export function decodeBase64Bytes(value: unknown) {
  const binary = window.atob(String(value ?? ""));
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}
