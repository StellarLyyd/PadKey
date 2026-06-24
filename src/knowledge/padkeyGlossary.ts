export type GlossaryCategory =
  | "hardware"
  | "signal"
  | "transport"
  | "speech"
  | "training"
  | "evaluation";

export interface GlossaryEntry {
  term: string;
  category: GlossaryCategory;
  definition: string;
  importance: string;
  aliases?: string[];
}

export const glossaryCategories: Array<{ id: GlossaryCategory; label: string }> = [
  { id: "hardware", label: "Hardware & capture" },
  { id: "signal", label: "Signal processing" },
  { id: "transport", label: "Transport & data" },
  { id: "speech", label: "Speech & transcription" },
  { id: "training", label: "Machine learning" },
  { id: "evaluation", label: "Evaluation & reliability" }
];

export const padkeyGlossary: GlossaryEntry[] = ([
  {
    term: "ADC",
    category: "hardware",
    definition: "Analog-to-digital converter. It turns a changing sensor voltage into numbers a computer can store and process.",
    importance: "The piezo sensor reaches the ESP32 through an ADC input, so ADC range and noise directly affect training data.",
    aliases: ["analog-to-digital converter"]
  },
  {
    term: "Breadboard",
    category: "hardware",
    definition: "A reusable board for connecting components without soldering.",
    importance: "It makes early PadKey sensor experiments fast, but loose wires can introduce intermittent readings and electrical noise."
  },
  {
    term: "DMA",
    category: "hardware",
    definition: "Direct memory access. Hardware moves samples into memory without making the processor handle every sample individually.",
    importance: "The ESP32 I2S driver uses DMA buffers so continuous microphone capture is less likely to drop audio."
  },
  {
    term: "ESP32-S3",
    category: "hardware",
    definition: "The microcontroller that reads PadKey sensors, runs firmware, and sends data over USB or Wi-Fi.",
    importance: "Its sampling, memory, USB, and networking limits define what the frontend can receive in real time."
  },
  {
    term: "Firmware",
    category: "hardware",
    definition: "The program flashed onto the ESP32-S3.",
    importance: "Firmware controls sensor pins, sample rates, packet formats, thresholds, and whether the frontend receives telemetry or full PCM audio."
  },
  {
    term: "GPIO",
    category: "hardware",
    definition: "General-purpose input/output pin on the microcontroller.",
    importance: "I2S clock/data lines, the piezo ADC input, and the user LED are assigned to GPIO pins."
  },
  {
    term: "I2S",
    category: "hardware",
    definition: "A digital audio connection that carries a clock, left/right timing, and microphone sample data.",
    importance: "The INMP441 uses I2S; incorrect clock, word-select, channel, or data settings produce silence or corrupted samples."
  },
  {
    term: "INMP441",
    category: "hardware",
    definition: "The digital MEMS microphone used in the current PadKey breadboard.",
    importance: "It supplies the raw voice waveform used for WAV files and Whisper transcription."
  },
  {
    term: "MEMS microphone",
    category: "hardware",
    definition: "A very small microphone manufactured with microelectromechanical technology.",
    importance: "MEMS microphones are compact and repeatable, but their placement and acoustic path still strongly affect signal quality."
  },
  {
    term: "Piezoelectric sensor",
    category: "hardware",
    definition: "A sensor that generates voltage when it bends, vibrates, or experiences pressure.",
    importance: "PadKey uses piezo contact vibration as evidence that can complement the airborne microphone signal.",
    aliases: ["piezo"]
  },
  {
    term: "Pin mapping",
    category: "hardware",
    definition: "The table connecting firmware signal names to physical microcontroller pins.",
    importance: "A correct program with the wrong pin mapping still reads the wrong sensor—or nothing at all."
  },
  {
    term: "XIAO ESP32-S3",
    category: "hardware",
    definition: "Seeed Studio’s compact development board built around the ESP32-S3.",
    importance: "This is the specific board form factor used by the current PadKey prototype, including its USB connection and onboard LED."
  },
  {
    term: "Amplitude",
    category: "signal",
    definition: "The instantaneous size of a signal relative to zero.",
    importance: "Larger amplitude usually means stronger sound or vibration, but amplitude alone cannot reconstruct spoken words."
  },
  {
    term: "Bit depth",
    category: "signal",
    definition: "How many bits represent each sample, such as 16-bit PCM.",
    importance: "More usable bit depth provides finer level detail; PadKey exports signed 16-bit audio for broad tool compatibility."
  },
  {
    term: "Clipping",
    category: "signal",
    definition: "Distortion caused when a signal exceeds the largest value the system can represent.",
    importance: "Clipped speech loses waveform detail and usually reduces transcription and model quality."
  },
  {
    term: "DC offset",
    category: "signal",
    definition: "A waveform centered above or below zero instead of evenly around zero.",
    importance: "Removing DC offset prevents a constant bias from wasting signal range and contaminating features."
  },
  {
    term: "FFT",
    category: "signal",
    definition: "Fast Fourier transform. A calculation that converts a waveform into its frequency components.",
    importance: "It is the foundation for spectrum displays and frequency-selective processing such as spectral gating.",
    aliases: ["fast Fourier transform"]
  },
  {
    term: "Frequency spectrum",
    category: "signal",
    definition: "A view of how signal energy is distributed across low and high frequencies.",
    importance: "Speech modes and noise sources may look similar in peak level but different in frequency content.",
    aliases: ["spectrum"]
  },
  {
    term: "Gain",
    category: "signal",
    definition: "A multiplier that makes a signal larger or smaller.",
    importance: "Gain can improve a quiet recording, but it also amplifies noise and cannot restore clipped information."
  },
  {
    term: "High-pass filter",
    category: "signal",
    definition: "A filter that reduces frequencies below a chosen cutoff while keeping higher frequencies.",
    importance: "PadKey’s 80 Hz high-pass option reduces very slow drift and low-frequency rumble."
  },
  {
    term: "Latency",
    category: "signal",
    definition: "The delay between a physical action and its visible, audible, or predicted result.",
    importance: "Batch size, transport, processing, and stability voting all add latency to dictated output."
  },
  {
    term: "Noise floor",
    category: "signal",
    definition: "The background signal level present when the intended sound or gesture is absent.",
    importance: "Detection thresholds must sit above the changing noise floor without hiding quiet speech."
  },
  {
    term: "Noise gate",
    category: "signal",
    definition: "A rule that suppresses the signal when its level falls below a threshold.",
    importance: "A gate reduces quiet background noise, but an aggressive setting can remove whisper or subvocal detail."
  },
  {
    term: "Normalization",
    category: "signal",
    definition: "Scaling a recording or feature set toward a consistent level.",
    importance: "Normalization reduces variation caused only by speaking louder or placing the sensor differently."
  },
  {
    term: "PCM",
    category: "signal",
    definition: "Pulse-code modulation: a sequence of signed numeric samples representing the original waveform.",
    importance: "PCM preserves the time-varying audio required for WAV export, DSP, VAD, and Whisper. Peak telemetry does not.",
    aliases: ["pulse-code modulation", "raw audio"]
  },
  {
    term: "Peak value",
    category: "signal",
    definition: "The largest absolute sample value observed in a block.",
    importance: "Peak values are useful for detection and plotting but discard almost all information needed to understand speech."
  },
  {
    term: "Pre-emphasis",
    category: "signal",
    definition: "A filter that boosts rapid high-frequency changes relative to slower low-frequency content.",
    importance: "It can make quiet consonant detail more prominent before recognition, especially in weak speech."
  },
  {
    term: "RMS",
    category: "signal",
    definition: "Root mean square: a measure of average signal energy over a window.",
    importance: "RMS is more stable than one peak and is useful for level comparison, VAD, and normalization."
  },
  {
    term: "Sample",
    category: "signal",
    definition: "One measured value of a waveform or sensor at one moment.",
    importance: "A useful signal is built from many ordered samples, not a single reading."
  },
  {
    term: "Sample rate",
    category: "signal",
    definition: "How many samples are captured each second, measured in hertz.",
    importance: "PadKey targets 16,000 audio samples per second; low-rate telemetry is useful for gestures but not full speech reconstruction."
  },
  {
    term: "Signal-to-noise ratio",
    category: "signal",
    definition: "The strength of the intended signal compared with unwanted noise.",
    importance: "Higher signal-to-noise ratio usually gives cleaner segmentation, training features, and transcription.",
    aliases: ["SNR"]
  },
  {
    term: "Spectral gate",
    category: "signal",
    definition: "Noise reduction that attenuates frequency bins believed to contain mostly noise.",
    importance: "It can suppress steady noise while preserving stronger speech frequencies better than a single amplitude gate."
  },
  {
    term: "Threshold",
    category: "signal",
    definition: "A boundary used to decide whether a measurement counts as active, confident, or acceptable.",
    importance: "PadKey uses thresholds for sound detection, VAD decisions, and committing trained phrase predictions."
  },
  {
    term: "Waveform",
    category: "signal",
    definition: "The signal’s changing amplitude plotted over time.",
    importance: "The waveform contains timing and shape information that a single peak number throws away."
  },
  {
    term: "WAV",
    category: "signal",
    definition: "A common audio file container that can store uncompressed PCM samples.",
    importance: "WAV is the lossless intermediate used for playback, inspection, training data, and later MP3 conversion."
  },
  {
    term: "Base64",
    category: "transport",
    definition: "A text-safe way to represent binary bytes using ordinary characters.",
    importance: "The reference USB firmware wraps PCM bytes in Base64 JSON, which is simple but larger than binary transport."
  },
  {
    term: "Baud rate",
    category: "transport",
    definition: "The configured serial communication speed, usually expressed as bits per second.",
    importance: "115200 is adequate for telemetry; PadKey uses 921600 for the larger raw PCM stream."
  },
  {
    term: "Buffer",
    category: "transport",
    definition: "Temporary memory that holds incoming data until it can be processed.",
    importance: "Buffers absorb timing variation, but a buffer that fills faster than it drains causes delay or dropped data."
  },
  {
    term: "Frame",
    category: "transport",
    definition: "One structured telemetry reading, or a short block of samples depending on context.",
    importance: "The Signal Trainer groups consecutive telemetry frames into labeled batches."
  },
  {
    term: "JSON",
    category: "transport",
    definition: "A human-readable text format for structured data made of fields, arrays, strings, and numbers.",
    importance: "PadKey uses JSON for PCM messages, exported datasets, metadata, and portable browser models."
  },
  {
    term: "Packet",
    category: "transport",
    definition: "A bounded message sent through USB, Wi-Fi, or another connection.",
    importance: "PCM is divided into packets; missing or reordered packets create gaps in a recording."
  },
  {
    term: "Packet loss",
    category: "transport",
    definition: "Data packets that were sent but never arrived or could not be processed.",
    importance: "Packet loss can create audible clicks, timing gaps, and incomplete training examples."
  },
  {
    term: "Ring buffer",
    category: "transport",
    definition: "A fixed-size buffer that overwrites its oldest data when new data arrives.",
    importance: "The frontend uses one for a continuously updated recent PCM preview without unlimited memory growth."
  },
  {
    term: "Sequence number",
    category: "transport",
    definition: "A counter attached to ordered packets.",
    importance: "A gap between expected sequence numbers lets the frontend measure dropped PCM packets."
  },
  {
    term: "Serial connection",
    category: "transport",
    definition: "A wired byte stream between the ESP32-S3 and computer over USB.",
    importance: "It is the most direct bench connection and does not depend on local Wi-Fi conditions.",
    aliases: ["USB serial"]
  },
  {
    term: "Web Serial",
    category: "transport",
    definition: "A browser API that lets a permitted web page communicate with a serial device.",
    importance: "It allows PadKey Studio to connect directly to the XIAO from Chrome or Edge without a separate desktop app."
  },
  {
    term: "WebSocket",
    category: "transport",
    definition: "A persistent two-way network connection between a browser and a server.",
    importance: "The Wi-Fi frontend expects the ESP32-S3 to host a WebSocket that continuously publishes PadKey packets."
  },
  {
    term: "Wi-Fi transport",
    category: "transport",
    definition: "Sending PadKey telemetry and PCM over a wireless network rather than USB.",
    importance: "It enables untethered capture but introduces network configuration, security, latency, and packet-loss concerns."
  },
  {
    term: "ASR",
    category: "speech",
    definition: "Automatic speech recognition: software that converts spoken audio into text.",
    importance: "Whisper is the ASR engine in Speech Lab; the trained telemetry classifier is a different, vocabulary-limited path.",
    aliases: ["automatic speech recognition", "speech-to-text"]
  },
  {
    term: "Egressive speech",
    category: "speech",
    definition: "Speech produced while air moves outward from the lungs.",
    importance: "It is the normal speaking direction and the default PadKey capture profile."
  },
  {
    term: "Ingressive speech",
    category: "speech",
    definition: "Speech-like phonation produced while breathing inward.",
    importance: "It may be quieter and shorter, so PadKey uses a more sensitive segmentation profile."
  },
  {
    term: "Segment",
    category: "speech",
    definition: "A bounded portion of audio believed to contain one utterance or useful speech event.",
    importance: "DSP and Whisper run on detected segments instead of an endless stream."
  },
  {
    term: "Segment stitching",
    category: "speech",
    definition: "Combining speech regions separated by short gaps into one longer utterance.",
    importance: "It helps Whisper see enough context when quiet or subvocal speech is fragmented."
  },
  {
    term: "Stitch gap",
    category: "speech",
    definition: "The maximum silent gap allowed when merging adjacent detected speech regions.",
    importance: "Too short splits words; too long may combine separate thoughts or noise events."
  },
  {
    term: "Subvocal speech",
    category: "speech",
    definition: "Very quiet or partially articulated speech with little or no normal audible voice.",
    importance: "It is a core PadKey target and produces weaker, more person-specific signals than ordinary speech."
  },
  {
    term: "Timestamp",
    category: "speech",
    definition: "A recorded time marking when a frame, segment, word, or event happened.",
    importance: "Timestamps align telemetry, contact evidence, PCM segments, and exported labels."
  },
  {
    term: "Token",
    category: "speech",
    definition: "A small text unit used by a language model; it may be a word, part of a word, or punctuation.",
    importance: "Whisper generates tokens that are decoded into the transcript shown in Speech Lab."
  },
  {
    term: "Transcription",
    category: "speech",
    definition: "The text produced from recorded or live speech.",
    importance: "It is the final open-ended output of the PCM → Whisper path."
  },
  {
    term: "Utterance",
    category: "speech",
    definition: "One continuous spoken unit, from a sound or word to a full phrase.",
    importance: "VAD and stitching decide where each utterance begins and ends before transcription."
  },
  {
    term: "VAD",
    category: "speech",
    definition: "Voice activity detection: deciding which parts of an audio stream probably contain speech.",
    importance: "Silero VAD helps PadKey separate speech from quiet gaps and background sound.",
    aliases: ["voice activity detection"]
  },
  {
    term: "Whisper",
    category: "speech",
    definition: "A family of speech-recognition models used to turn PCM audio into open-ended text.",
    importance: "It provides general transcription, while the Signal Trainer learns a small custom vocabulary from telemetry."
  },
  {
    term: "Batch",
    category: "training",
    definition: "A fixed-length group of consecutive telemetry frames captured as one labeled attempt.",
    importance: "Each PadKey training batch should represent one clean repetition of one phrase, including `rest`."
  },
  {
    term: "Browser worker",
    category: "training",
    definition: "Code that runs in a background browser thread separate from the interface.",
    importance: "PadKey trains and runs heavier processing without freezing buttons, charts, and status updates.",
    aliases: ["Web Worker"]
  },
  {
    term: "Class",
    category: "training",
    definition: "One answer a classifier is allowed to predict, such as `rest`, `yes`, or `help`.",
    importance: "The Signal Trainer is vocabulary-limited to the classes present in its labeled dataset."
  },
  {
    term: "Classifier",
    category: "training",
    definition: "A model that chooses among a fixed set of categories.",
    importance: "PadKey’s browser signal model classifies a telemetry window into one trained phrase class."
  },
  {
    term: "Dataset",
    category: "training",
    definition: "An organized collection of examples and labels used to train or evaluate a model.",
    importance: "Dataset quality and variety usually matter more than simply increasing the number of training epochs."
  },
  {
    term: "Epoch",
    category: "training",
    definition: "One full training pass through the available examples.",
    importance: "Too few epochs may underfit; too many can overfit, especially with a small dataset."
  },
  {
    term: "Feature extraction",
    category: "training",
    definition: "Turning raw frames into a smaller set of useful measurements such as mean, variation, range, slope, and change rate.",
    importance: "The current signal classifier learns from 48 batch features rather than memorizing every raw frame."
  },
  {
    term: "Ground truth",
    category: "training",
    definition: "The label believed to be correct for a captured example.",
    importance: "When you label a batch `yes`, that label becomes truth for training—so capture mistakes directly teach the wrong behavior."
  },
  {
    term: "Inference",
    category: "training",
    definition: "Using a trained model to make a prediction on new data.",
    importance: "Live dictation runs inference repeatedly on new telemetry windows after training is complete."
  },
  {
    term: "Label",
    category: "training",
    definition: "The human-provided name attached to a training example.",
    importance: "Consistent labels connect sensor patterns to the words you want PadKey to dictate."
  },
  {
    term: "Loss",
    category: "training",
    definition: "A number measuring how wrong model predictions are during training.",
    importance: "Training attempts to reduce loss, but low training loss does not guarantee reliable behavior on new sessions."
  },
  {
    term: "Model",
    category: "training",
    definition: "Learned parameters and rules that transform input features into predictions.",
    importance: "PadKey exports the browser signal model as JSON so it can be saved, shared, and loaded later."
  },
  {
    term: "ONNX",
    category: "training",
    definition: "An open format for representing machine-learning models across different tools and runtimes.",
    importance: "Silero and browser Whisper models run through ONNX-compatible web runtimes."
  },
  {
    term: "Rest class",
    category: "training",
    definition: "A labeled state where no intended phrase or gesture is being produced.",
    importance: "It teaches the model what not speaking looks like and re-arms repeated words in the dictation workflow."
  },
  {
    term: "Softmax",
    category: "training",
    definition: "A calculation that turns model scores into probabilities that add up to 100 percent.",
    importance: "The browser classifier uses softmax probabilities to rank phrase candidates and apply a confidence gate."
  },
  {
    term: "Training",
    category: "training",
    definition: "Adjusting model parameters so labeled examples receive higher predicted probability.",
    importance: "Training is when PadKey learns your signal patterns; inference is when it uses what it learned."
  },
  {
    term: "Training/validation split",
    category: "training",
    definition: "Separating examples used to learn from examples held back to test the result.",
    importance: "PadKey reports held-out accuracy so the score is not based only on data the model already saw."
  },
  {
    term: "Vocabulary-limited model",
    category: "training",
    definition: "A model that can output only the finite labels it was trained to recognize.",
    importance: "Signal Trainer can learn custom phrases but cannot invent arbitrary transcription like Whisper."
  },
  {
    term: "WebAssembly",
    category: "training",
    definition: "A fast, portable binary format that lets compiled code run inside a web browser.",
    importance: "ONNX Runtime Web uses WebAssembly to run Silero and Whisper computations locally.",
    aliases: ["WASM"]
  },
  {
    term: "Accuracy",
    category: "evaluation",
    definition: "The fraction of evaluated examples the model classified correctly.",
    importance: "It is useful, but a high score on a tiny or repetitive validation set can be misleading."
  },
  {
    term: "Calibration",
    category: "evaluation",
    definition: "How closely predicted confidence matches real-world correctness.",
    importance: "A well-calibrated 80 percent confidence prediction should be correct about eight times out of ten."
  },
  {
    term: "Confidence",
    category: "evaluation",
    definition: "The model’s numerical strength for a prediction, not a guarantee that it is correct.",
    importance: "PadKey combines confidence with repeated-window stability before committing dictated text."
  },
  {
    term: "Confidence gate",
    category: "evaluation",
    definition: "A minimum confidence required before a prediction can trigger an action.",
    importance: "Raising it reduces accidental dictation but may reject quiet or unusual attempts."
  },
  {
    term: "Confusion matrix",
    category: "evaluation",
    definition: "A table showing which true classes are being predicted as which other classes.",
    importance: "It reveals specific mix-ups—such as `yes` being mistaken for `rest`—that overall accuracy hides."
  },
  {
    term: "False negative",
    category: "evaluation",
    definition: "A real intended phrase or speech event that the system fails to detect or recognize.",
    importance: "Too-high thresholds, weak contact, or an underrepresented phrase can increase false negatives."
  },
  {
    term: "False positive",
    category: "evaluation",
    definition: "The system reports a phrase or speech event when none was intended.",
    importance: "Rest data, confidence gating, and stability voting are key defenses against accidental dictation."
  },
  {
    term: "Generalization",
    category: "evaluation",
    definition: "How well a model works on new sessions and conditions instead of only its training examples.",
    importance: "A useful PadKey model should survive small changes in placement, pressure, timing, and background noise."
  },
  {
    term: "Overfitting",
    category: "evaluation",
    definition: "When a model memorizes training details but performs poorly on new examples.",
    importance: "Capture varied repetitions across sessions; repeating nearly identical batches can create a falsely impressive model."
  },
  {
    term: "Stability voting",
    category: "evaluation",
    definition: "Requiring the same prediction across multiple consecutive windows before accepting it.",
    importance: "PadKey requires two matching confident windows to reduce flickering and accidental dictated tokens."
  }
] satisfies GlossaryEntry[]).sort((left, right) => left.term.localeCompare(right.term));
