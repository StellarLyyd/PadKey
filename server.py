import asyncio
import websockets
import numpy as np
import wave

PORT = 8888

wf = wave.open("test.wav", "wb")
wf.setnchannels(1)
wf.setsampwidth(2)
wf.setframerate(16000)

async def handler(websocket):

    print("ESP32 connected!")

    try:
        async for message in websocket:

            audio = np.frombuffer(message, dtype=np.int16)

            print(
                "Received bytes:",
                len(message),
                " min:",
                audio.min(),
                " max:",
                audio.max()
            )

            wf.writeframes(message)

    except websockets.exceptions.ConnectionClosed:
        print("ESP32 disconnected")

async def main():

    print(f"Listening on port {PORT}")

    async with websockets.serve(handler, "0.0.0.0", PORT):
        await asyncio.Future()

try:
    asyncio.run(main())

except KeyboardInterrupt:
    wf.close()
    print("Saved test.wav")
