import { useCallback, useEffect, useRef, useState } from "react";

function clamp(value: number, minimum: number, maximum: number) {
  return Math.max(minimum, Math.min(maximum, value));
}

export function useStudioPlayer(
  samples: Int16Array | null,
  sampleRate: number,
  trimStartMs: number,
  trimEndMs: number
) {
  const contextRef = useRef<AudioContext | null>(null);
  const samplesRef = useRef<Int16Array | null>(samples);
  const sourceRef = useRef<AudioBufferSourceNode | null>(null);
  const gainRef = useRef<GainNode | null>(null);
  const playingRef = useRef(false);
  const startedAtRef = useRef(0);
  const startOffsetRef = useRef(trimStartMs / 1000);
  const trimStartRef = useRef(trimStartMs / 1000);
  const trimEndRef = useRef(trimEndMs / 1000);
  const [playing, setPlaying] = useState(false);
  const [position, setPosition] = useState(trimStartMs / 1000);

  const currentPosition = useCallback(() => {
    const context = contextRef.current;
    if (!context || !playingRef.current) return startOffsetRef.current;
    return Math.min(trimEndRef.current, startOffsetRef.current + context.currentTime - startedAtRef.current);
  }, []);

  const stopCurrent = useCallback((fade = false) => {
    const context = contextRef.current;
    const source = sourceRef.current;
    const gain = gainRef.current;
    if (!source) return;
    if (fade && context && gain) {
      gain.gain.cancelScheduledValues(context.currentTime);
      gain.gain.setValueAtTime(gain.gain.value, context.currentTime);
      gain.gain.linearRampToValueAtTime(0, context.currentTime + 0.02);
      source.stop(context.currentTime + 0.025);
    } else {
      try { source.stop(); } catch { /* The source may already be stopped. */ }
    }
    if (sourceRef.current === source) sourceRef.current = null;
  }, []);

  const startAt = useCallback((requestedOffset: number, crossfade = false) => {
    const pcm = samplesRef.current;
    if (!pcm?.length) return;
    const context = contextRef.current ?? new AudioContext();
    contextRef.current = context;
    if (context.state === "suspended") void context.resume();

    const offset = clamp(requestedOffset, trimStartRef.current, Math.max(trimStartRef.current, trimEndRef.current - 0.01));
    const duration = Math.max(0.01, trimEndRef.current - offset);
    const buffer = context.createBuffer(1, pcm.length, sampleRate);
    const channel = buffer.getChannelData(0);
    for (let index = 0; index < pcm.length; index += 1) channel[index] = pcm[index] / 32768;

    const oldSource = sourceRef.current;
    const oldGain = gainRef.current;
    const source = context.createBufferSource();
    const gain = context.createGain();
    source.buffer = buffer;
    source.connect(gain).connect(context.destination);
    gain.gain.setValueAtTime(crossfade ? 0 : 1, context.currentTime);
    if (crossfade) gain.gain.linearRampToValueAtTime(1, context.currentTime + 0.02);

    sourceRef.current = source;
    gainRef.current = gain;
    startedAtRef.current = context.currentTime;
    startOffsetRef.current = offset;
    playingRef.current = true;
    setPlaying(true);
    setPosition(offset);
    source.start(0, offset, duration);

    if (crossfade && oldSource && oldGain) {
      oldGain.gain.cancelScheduledValues(context.currentTime);
      oldGain.gain.setValueAtTime(oldGain.gain.value, context.currentTime);
      oldGain.gain.linearRampToValueAtTime(0, context.currentTime + 0.02);
      oldSource.stop(context.currentTime + 0.025);
    } else if (oldSource) {
      try { oldSource.stop(); } catch { /* The source may already be stopped. */ }
    }

    source.onended = () => {
      if (sourceRef.current !== source) return;
      sourceRef.current = null;
      playingRef.current = false;
      setPlaying(false);
      setPosition(trimStartRef.current);
      startOffsetRef.current = trimStartRef.current;
    };
  }, [sampleRate]);

  useEffect(() => {
    samplesRef.current = samples;
    if (playingRef.current) void startAt(currentPosition(), true);
  }, [samples, currentPosition, startAt]);

  useEffect(() => {
    trimStartRef.current = trimStartMs / 1000;
    trimEndRef.current = trimEndMs / 1000;
    const nextPosition = clamp(currentPosition(), trimStartRef.current, trimEndRef.current);
    startOffsetRef.current = nextPosition;
    setPosition(nextPosition);
    if (playingRef.current) void startAt(nextPosition, true);
  }, [trimStartMs, trimEndMs, currentPosition, startAt]);

  useEffect(() => {
    if (!playing) return;
    const timer = window.setInterval(() => {
      const next = currentPosition();
      setPosition(next);
      if (next >= trimEndRef.current - 0.01) {
        stopCurrent();
        playingRef.current = false;
        setPlaying(false);
        startOffsetRef.current = trimStartRef.current;
        setPosition(trimStartRef.current);
      }
    }, 50);
    return () => window.clearInterval(timer);
  }, [playing, currentPosition, stopCurrent]);

  useEffect(() => () => {
    stopCurrent();
    void contextRef.current?.close();
  }, [stopCurrent]);

  const toggle = useCallback(() => {
    if (playingRef.current) {
      const next = currentPosition();
      stopCurrent(true);
      playingRef.current = false;
      startOffsetRef.current = next;
      setPosition(next);
      setPlaying(false);
    } else {
      const next = position >= trimEndRef.current - 0.01 ? trimStartRef.current : position;
      void startAt(next);
    }
  }, [currentPosition, position, startAt, stopCurrent]);

  const seek = useCallback((seconds: number) => {
    const next = clamp(seconds, trimStartRef.current, trimEndRef.current);
    startOffsetRef.current = next;
    setPosition(next);
    if (playingRef.current) void startAt(next, true);
  }, [startAt]);

  return { playing, position, toggle, seek };
}
