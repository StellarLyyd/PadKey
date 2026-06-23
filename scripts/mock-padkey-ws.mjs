import { WebSocketServer } from "ws";

const port = Number(process.env.PADKEY_MOCK_PORT || 8787);
const sampleRate = 16000;
const samplesPerPacket = 512;
const server = new WebSocketServer({ host: "127.0.0.1", port });

function audioPacket(sequence, channel, frequency, amplitude) {
  const pcm = Buffer.alloc(samplesPerPacket * 2);
  for (let index = 0; index < samplesPerPacket; index += 1) {
    const time = (sequence * samplesPerPacket + index) / sampleRate;
    const envelope = (Math.sin(time * Math.PI * 2 * 1.3) + 1) / 2;
    const transient = channel === "piezo" ? Math.exp(-((index % 128) / 22)) : 1;
    const sample = Math.round(Math.sin(time * Math.PI * 2 * frequency) * amplitude * envelope * transient);
    pcm.writeInt16LE(sample, index * 2);
  }
  return JSON.stringify({
    type: "audio",
    format: "pcm_s16le",
    channel,
    sampleRate,
    channels: 1,
    sequence,
    pcm: pcm.toString("base64")
  });
}

server.on("connection", (socket) => {
  let sequence = 0;
  const timer = setInterval(() => {
    const mic = 1300 + Math.round(Math.abs(Math.sin(sequence / 5)) * 900);
    const noiseFloor = 980 + Math.round(Math.abs(Math.sin(sequence / 17)) * 90);
    const gate = Math.round(noiseFloor * 1.6);
    const max4466 = 900 + Math.round(Math.abs(Math.sin(sequence / 4)) * 700);
    const piezo = 55 + Math.round(Math.abs(Math.cos(sequence / 7)) * 90);
    socket.send(`INMP441:${mic},MAX4466:${max4466},NoiseFloor:${noiseFloor},Gate:${gate},PIEZO:${piezo}\n`);
    socket.send(audioPacket(sequence, "inmp441", 180, 8000));
    socket.send(audioPacket(sequence, "max4466", 225, 6200));
    socket.send(audioPacket(sequence, "piezo", 110, 10500));
    sequence += 1;
  }, 50);
  socket.on("close", () => clearInterval(timer));
});

console.log(`PadKey mock device listening on ws://127.0.0.1:${port}`);
