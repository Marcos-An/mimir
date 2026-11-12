//! Microphone capture: the default input device, mixed to mono and resampled
//! to 16 kHz for Whisper. The whole utterance stays in memory (10-minute cap).
//! The cpal stream lives on its own thread because it is not `Send` on every
//! platform.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

pub const RATE: u32 = 16_000;
const MAX_SECONDS: usize = 600;

pub struct Recorder {
    stop: mpsc::Sender<()>,
    thread: JoinHandle<Result<Vec<f32>, String>>,
}

impl Recorder {
    /// Starts recording; fails at once if there is no microphone.
    pub fn start() -> Result<Self, String> {
        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();
        let thread = std::thread::spawn(move || -> Result<Vec<f32>, String> {
            let host = cpal::default_host();
            let setup = (|| {
                let device = host.default_input_device().ok_or("No microphone found.")?;
                let config = device.default_input_config().map_err(|e| format!("Microphone unavailable: {e}"))?;
                let channels = config.channels() as usize;
                let rate = config.sample_rate().0;
                let buffer = Arc::new(Mutex::new(Vec::<f32>::with_capacity(rate as usize * 30)));
                let cap = rate as usize * MAX_SECONDS;
                let sink = buffer.clone();
                let push = move |mono: &mut dyn Iterator<Item = f32>| {
                    let mut guard = sink.lock().unwrap();
                    for sample in mono {
                        if guard.len() >= cap {
                            break;
                        }
                        guard.push(sample);
                    }
                };
                let error = |e| eprintln!("microphone stream error: {e}");
                let stream_config: cpal::StreamConfig = config.clone().into();
                let stream = match config.sample_format() {
                    cpal::SampleFormat::F32 => {
                        let push = push.clone();
                        device.build_input_stream(
                            &stream_config,
                            move |data: &[f32], _| push(&mut data.chunks(channels).map(|f| f.iter().sum::<f32>() / channels as f32)),
                            error,
                            None,
                        )
                    }
                    cpal::SampleFormat::I16 => device.build_input_stream(
                        &stream_config,
                        move |data: &[i16], _| {
                            push(&mut data.chunks(channels).map(|f| f.iter().map(|&s| s as f32 / 32768.0).sum::<f32>() / channels as f32))
                        },
                        error,
                        None,
                    ),
                    cpal::SampleFormat::U16 => device.build_input_stream(
                        &stream_config,
                        move |data: &[u16], _| {
                            push(&mut data.chunks(channels).map(|f| {
                                f.iter().map(|&s| (s as f32 - 32768.0) / 32768.0).sum::<f32>() / channels as f32
                            }))
                        },
                        error,
                        None,
                    ),
                    other => return Err(format!("Unsupported microphone format {other:?}.")),
                }
                .map_err(|e| format!("Microphone unavailable: {e}"))?;
                stream.play().map_err(|e| format!("Microphone unavailable: {e}"))?;
                Ok::<_, String>((stream, buffer, rate))
            })();
            let (stream, buffer, rate) = match setup {
                Ok(parts) => {
                    let _ = ready_tx.send(Ok(()));
                    parts
                }
                Err(error) => {
                    let _ = ready_tx.send(Err(error.clone()));
                    return Err(error);
                }
            };
            let _ = stop_rx.recv();
            drop(stream);
            let samples = std::mem::take(&mut *buffer.lock().unwrap());
            Ok(resample(&samples, rate, RATE))
        });
        ready_rx.recv().map_err(|_| "Microphone thread stopped.".to_string())??;
        Ok(Self { stop: stop_tx, thread })
    }

    /// Stops and returns 16 kHz mono samples.
    pub fn finish(self) -> Result<Vec<f32>, String> {
        let _ = self.stop.send(());
        self.thread.join().map_err(|_| "Microphone thread crashed.".to_string())?
    }
}

/// Linear interpolation, after a box filter when going down in rate.
pub fn resample(input: &[f32], from: u32, to: u32) -> Vec<f32> {
    if from == to || input.is_empty() {
        return input.to_vec();
    }
    let ratio = from as f64 / to as f64;
    let width = ratio.floor().max(1.0) as usize;
    let smoothed: Vec<f32> = if width > 1 {
        let mut sum = 0.0f32;
        let mut out = Vec::with_capacity(input.len());
        for (i, &s) in input.iter().enumerate() {
            sum += s;
            if i >= width {
                sum -= input[i - width];
            }
            out.push(sum / width.min(i + 1) as f32);
        }
        out
    } else {
        input.to_vec()
    };
    let length = (input.len() as f64 / ratio) as usize;
    (0..length)
        .map(|i| {
            let position = i as f64 * ratio;
            let index = position as usize;
            let fraction = (position - index as f64) as f32;
            let a = smoothed[index];
            let b = *smoothed.get(index + 1).unwrap_or(&a);
            a + (b - a) * fraction
        })
        .collect()
}

/// True when the clip has at least a quarter second of sound above a
/// whisper-level floor. Silence makes Whisper invent "Obrigado.".
pub fn has_speech(samples: &[f32]) -> bool {
    const FRAME: usize = (RATE as usize) * 30 / 1000;
    let voiced = samples
        .chunks(FRAME)
        .filter(|frame| (frame.iter().map(|s| s * s).sum::<f32>() / frame.len() as f32).sqrt() > 0.008)
        .count();
    voiced >= 8
}

/// 16-bit PCM WAV, for cloud upload.
pub fn wav_bytes(samples: &[f32]) -> Vec<u8> {
    let mut cursor = std::io::Cursor::new(Vec::new());
    {
        let spec = hound::WavSpec { channels: 1, sample_rate: RATE, bits_per_sample: 16, sample_format: hound::SampleFormat::Int };
        let mut writer = hound::WavWriter::new(&mut cursor, spec).unwrap();
        for &s in samples {
            writer.write_sample((s.clamp(-1.0, 1.0) * 32767.0) as i16).unwrap();
        }
        writer.finalize().unwrap();
    }
    cursor.into_inner()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resample_and_gate() {
        let one_second_48k: Vec<f32> = (0..48_000).map(|i| (i as f32 * 0.05).sin() * 0.2).collect();
        assert_eq!(resample(&one_second_48k, 48_000, RATE).len(), 16_000);
        assert!(has_speech(&resample(&one_second_48k, 48_000, RATE)));
        assert!(!has_speech(&vec![0.001; 16_000 * 5]));
        assert!(wav_bytes(&[0.0; 160]).starts_with(b"RIFF"));
    }
}
