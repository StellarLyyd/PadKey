import asyncio
import wave
from bleak import BleakScanner, BleakClient

DEVICE_NAME = "ESP32_Audio"
CHAR_UUID = "abcd1234-1234-1234-1234-abcdef123456"

SAMPLE_RATE = 4000
RECORD_SECONDS = 10
OUTPUT_FILE = "ble_audio_4khz.wav"

audio_data = bytearray()

def callback(sender, data):
    audio_data.extend(data)
    print(f"{len(audio_data)} bytes", end="\r")

async def main():
    print("Searching...")
    device = await BleakScanner.find_device_by_name(DEVICE_NAME)

    if device is None:
        print("ESP32 not found")
        return

    async with BleakClient(device) as client:
        print("Connected")
        await client.start_notify(CHAR_UUID, callback)
        await asyncio.sleep(RECORD_SECONDS)
        await client.stop_notify(CHAR_UUID)

    with wave.open(OUTPUT_FILE, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(audio_data)

    print(f"\nSaved {OUTPUT_FILE}")

asyncio.run(main())
