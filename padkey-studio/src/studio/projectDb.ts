import type { AudioProject, AudioProjectSummary } from "./types";
import type { AudioChannel } from "../types";

const DATABASE_NAME = "padkey-studio";
const DATABASE_VERSION = 1;
const PROJECT_STORE = "audio-projects";

interface StoredAudioProject extends Omit<AudioProject, "samples" | "tracks"> {
  audio: Blob;
  trackAudio?: Partial<Record<AudioChannel, Blob>>;
}

function openDatabase() {
  return new Promise<IDBDatabase>((resolve, reject) => {
    const request = indexedDB.open(DATABASE_NAME, DATABASE_VERSION);
    request.onupgradeneeded = () => {
      const database = request.result;
      if (!database.objectStoreNames.contains(PROJECT_STORE)) {
        const store = database.createObjectStore(PROJECT_STORE, { keyPath: "id" });
        store.createIndex("updatedAt", "updatedAt");
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("Could not open local recording storage"));
  });
}

function runRequest<T>(mode: IDBTransactionMode, action: (store: IDBObjectStore) => IDBRequest<T>) {
  return openDatabase().then((database) => new Promise<T>((resolve, reject) => {
    const transaction = database.transaction(PROJECT_STORE, mode);
    const request = action(transaction.objectStore(PROJECT_STORE));
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("Local recording storage failed"));
    transaction.oncomplete = () => database.close();
    transaction.onerror = () => {
      database.close();
      reject(transaction.error ?? new Error("Local recording storage failed"));
    };
  }));
}

function toStoredProject(project: AudioProject): StoredAudioProject {
  const audioBytes = project.samples.slice().buffer as ArrayBuffer;
  const trackAudio = project.tracks
    ? Object.fromEntries(Object.entries(project.tracks).map(([channel, samples]) => [
        channel,
        new Blob([(samples as Int16Array).slice().buffer as ArrayBuffer], { type: "application/x-padkey-pcm" })
      ]))
    : undefined;
  const { samples: _samples, tracks: _tracks, ...metadata } = project;
  return { ...metadata, audio: new Blob([audioBytes], { type: "application/x-padkey-pcm" }), trackAudio };
}

async function fromStoredProject(project: StoredAudioProject): Promise<AudioProject> {
  const trackEntries = project.trackAudio
    ? await Promise.all(Object.entries(project.trackAudio).map(async ([channel, audio]) => [
        channel,
        new Int16Array(await audio.arrayBuffer())
      ] as const))
    : [];
  const { trackAudio: _trackAudio, audio, ...metadata } = project;
  return {
    ...metadata,
    samples: new Int16Array(await audio.arrayBuffer()),
    tracks: trackEntries.length ? Object.fromEntries(trackEntries) : undefined
  };
}

export async function saveAudioProject(project: AudioProject) {
  await runRequest("readwrite", (store) => store.put(toStoredProject(project)));
}

export async function getAudioProject(id: string) {
  const stored = await runRequest<StoredAudioProject | undefined>("readonly", (store) => store.get(id));
  return stored ? fromStoredProject(stored) : null;
}

export async function listAudioProjects(limit = 10): Promise<AudioProjectSummary[]> {
  const stored = await runRequest<StoredAudioProject[]>("readonly", (store) => store.getAll());
  return stored
    .sort((left, right) => right.updatedAt - left.updatedAt)
    .slice(0, limit)
    .map(({ id, name, source, createdAt, updatedAt, durationMs }) => ({
      id,
      name,
      source,
      createdAt,
      updatedAt,
      durationMs
    }));
}

export async function deleteAudioProject(id: string) {
  await runRequest("readwrite", (store) => store.delete(id));
}
