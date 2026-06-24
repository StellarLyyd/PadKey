import { useCallback, useEffect, useRef } from "react";
import { useAppStore } from "../store";

const TARGET_SAMPLE_RATE = 16000;

function isBuiltInMicrophone(label: string) {
  return /macbook|built[- ]?in|internal microphone/i.test(label);
}

function downsample(input: Float32Array, sourceRate: number, positionRef: { current: number }) {
  const ratio = sourceRate / TARGET_SAMPLE_RATE;
  const output: number[] = [];
  let position = positionRef.current;
  while (position < input.length) {
    const lower = Math.floor(position);
    const upper = Math.min(input.length - 1, lower + 1);
    const mix = position - lower;
    output.push(input[lower] * (1 - mix) + input[upper] * mix);
    position += ratio;
  }
  positionRef.current = position - input.length;
  return Int16Array.from(output, (sample) => Math.round(Math.max(-1, Math.min(0.999969, sample)) * 32768));
}

export interface MacMicrophoneController {
  start: () => Promise<boolean>;
  stop: () => Promise<void>;
  status: "idle" | "requesting" | "live" | "error";
  error: string | null;
  deviceName: string | null;
}

export function useMacMicrophone(): MacMicrophoneController {
  const streamRef = useRef<MediaStream | null>(null);
  const contextRef = useRef<AudioContext | null>(null);
  const processorRef = useRef<ScriptProcessorNode | null>(null);
  const sequenceRef = useRef(0);
  const resamplePositionRef = useRef(0);
  const pushAudioPacket = useAppStore((state) => state.pushAudioPacket);
  const status = useAppStore((state) => state.macMicrophoneStatus);
  const error = useAppStore((state) => state.macMicrophoneError);
  const deviceName = useAppStore((state) => state.macMicrophoneDeviceName);
  const setMacMicrophoneState = useAppStore((state) => state.setMacMicrophoneState);

  const stop = useCallback(async () => {
    processorRef.current?.disconnect();
    processorRef.current = null;
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
    const context = contextRef.current;
    contextRef.current = null;
    await context?.close().catch(() => undefined);
    sequenceRef.current = 0;
    resamplePositionRef.current = 0;
    setMacMicrophoneState("idle", null, null);
  }, [setMacMicrophoneState]);

  const start = useCallback(async () => {
    if (streamRef.current && contextRef.current) return true;
    if (!navigator.mediaDevices?.getUserMedia) {
      setMacMicrophoneState("error", "Mac microphone capture is unavailable in this browser.", null);
      return false;
    }

    setMacMicrophoneState("requesting", null, null);
    let permissionStream: MediaStream | null = null;
    try {
      const constraints: MediaTrackConstraints = {
        channelCount: 1,
        echoCancellation: false,
        noiseSuppression: false,
        autoGainControl: false
      };
      permissionStream = await navigator.mediaDevices.getUserMedia({ audio: constraints });
      const devices = await navigator.mediaDevices.enumerateDevices();
      const builtIn = devices.find((device) => device.kind === "audioinput" && isBuiltInMicrophone(device.label));
      let stream = permissionStream;
      if (builtIn?.deviceId && permissionStream.getAudioTracks()[0]?.getSettings().deviceId !== builtIn.deviceId) {
        permissionStream.getTracks().forEach((track) => track.stop());
        permissionStream = null;
        stream = await navigator.mediaDevices.getUserMedia({
          audio: { ...constraints, deviceId: { exact: builtIn.deviceId } }
        });
      }

      const context = new AudioContext();
      const source = context.createMediaStreamSource(stream);
      // ScriptProcessor remains the widest-compatible low-latency path for
      // localhost Web Serial demos. It is isolated here for later AudioWorklet
      // replacement without changing the Studio data model.
      const processor = context.createScriptProcessor(2048, 1, 1);
      const mutedOutput = context.createGain();
      mutedOutput.gain.value = 0;
      processor.onaudioprocess = (event) => {
        const samples = downsample(event.inputBuffer.getChannelData(0), context.sampleRate, resamplePositionRef);
        if (!samples.length) return;
        pushAudioPacket({
          channel: "macbook",
          samples,
          sampleRate: TARGET_SAMPLE_RATE,
          channels: 1,
          sequence: sequenceRef.current++,
          recordable: true,
          ts: Date.now()
        });
      };
      source.connect(processor);
      processor.connect(mutedOutput).connect(context.destination);
      if (context.state === "suspended") await context.resume();

      streamRef.current = stream;
      contextRef.current = context;
      processorRef.current = processor;
      const trackLabel = stream.getAudioTracks()[0]?.label || "Mac microphone";
      setMacMicrophoneState("live", null, trackLabel);
      return true;
    } catch (captureError) {
      permissionStream?.getTracks().forEach((track) => track.stop());
      const message = captureError instanceof DOMException && captureError.name === "NotAllowedError"
        ? "Microphone access was not allowed. Enable it for PadKey and try again."
        : captureError instanceof Error ? captureError.message : "The Mac microphone could not be opened.";
      setMacMicrophoneState("error", message, null);
      return false;
    }
  }, [pushAudioPacket, setMacMicrophoneState]);

  useEffect(() => () => {
    processorRef.current?.disconnect();
    streamRef.current?.getTracks().forEach((track) => track.stop());
    void contextRef.current?.close();
  }, []);

  return { start, stop, status, error, deviceName };
}
