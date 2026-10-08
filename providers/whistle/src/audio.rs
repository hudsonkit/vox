use crate::error;
use rubato::{FftFixedIn, Resampler};
use std::fs::File;
use std::path::Path;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as DecodeError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::{MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;
use vox_provider::ProviderError;

const SAMPLE_RATE: u32 = 16_000;
const MAX_SECONDS: u64 = 30;

pub struct DecodedAudio {
    mono: Vec<f32>,
    rate: u32,
}

impl DecodedAudio {
    pub fn duration_ms(&self) -> u64 {
        (self.mono.len() as u64 * 1000 + self.rate as u64 / 2) / self.rate as u64
    }
}

fn audio_error(e: impl std::fmt::Display) -> ProviderError {
    error(6, format!("Audio could not be decoded: {e}"))
}

fn too_long() -> ProviderError {
    error(
        -32602,
        "Whistle accepts at most 30 seconds per file. Split longer audio first.",
    )
}

pub fn decode(path: &Path) -> Result<DecodedAudio, ProviderError> {
    let source = File::open(path).map_err(audio_error)?;
    let stream = MediaSourceStream::new(Box::new(source), MediaSourceStreamOptions::default());
    let mut hint = Hint::new();
    if let Some(extension) = path.extension().and_then(|s| s.to_str()) {
        hint.with_extension(extension);
    }
    let mut format = symphonia::default::get_probe()
        .format(
            &hint,
            stream,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map_err(audio_error)?
        .format;
    let track = format
        .default_track()
        .filter(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .ok_or_else(|| audio_error("no supported audio track"))?;
    let track_id = track.id;
    let params = track.codec_params.clone();
    let mut decoder = symphonia::default::get_codecs()
        .make(&params, &DecoderOptions::default())
        .map_err(audio_error)?;
    let mut rate = params.sample_rate;
    if let (Some(rate), Some(frames)) = (rate, params.n_frames) {
        if rate == 0 {
            return Err(audio_error("zero sample rate"));
        }
        if frames > MAX_SECONDS * rate as u64 {
            return Err(too_long());
        }
    }
    let mut mono = Vec::new();
    loop {
        let packet = match format.next_packet() {
            Ok(packet) => packet,
            Err(DecodeError::IoError(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(e) => return Err(audio_error(e)),
        };
        if packet.track_id() != track_id {
            continue;
        }
        let decoded = decoder.decode(&packet).map_err(audio_error)?;
        let spec = *decoded.spec();
        if spec.rate == 0
            || spec.rate > 384_000
            || spec.channels.count() == 0
            || spec.channels.count() > 64
        {
            return Err(audio_error("unsupported sample rate or channel count"));
        }
        if rate.is_some_and(|previous| previous != spec.rate) {
            return Err(audio_error("sample rate changes within the file"));
        }
        rate = Some(spec.rate);
        if mono.len() as u64 + decoded.frames() as u64 > MAX_SECONDS * spec.rate as u64 {
            return Err(too_long());
        }
        let mut samples = SampleBuffer::<f32>::new(decoded.capacity() as u64, spec);
        samples.copy_interleaved_ref(decoded);
        for frame in samples.samples().chunks_exact(spec.channels.count()) {
            if frame.iter().any(|s| !s.is_finite()) {
                return Err(audio_error("non-finite sample"));
            }
            // Average in f64 so finite float32 input cannot overflow the sum.
            mono.push(
                (frame.iter().map(|&s| f64::from(s)).sum::<f64>() / frame.len() as f64) as f32,
            );
        }
    }
    if mono.is_empty() {
        return Err(audio_error("no samples"));
    }
    Ok(DecodedAudio {
        mono,
        rate: rate.ok_or_else(|| audio_error("missing sample rate"))?,
    })
}

pub fn prepare(audio: DecodedAudio) -> Result<Vec<f32>, ProviderError> {
    let mut pcm = if audio.rate == SAMPLE_RATE {
        audio.mono
    } else {
        resample(&audio.mono, audio.rate)?
    };
    for sample in &mut pcm {
        if !sample.is_finite() {
            return Err(audio_error("non-finite resampled sample"));
        }
        *sample = sample.clamp(-1.0, 1.0);
    }
    Ok(pcm)
}

fn resample(input: &[f32], rate: u32) -> Result<Vec<f32>, ProviderError> {
    let mut resampler = FftFixedIn::<f32>::new(rate as usize, SAMPLE_RATE as usize, 1024, 2, 1)
        .map_err(audio_error)?;
    let delay = resampler.output_delay();
    let target =
        ((input.len() as u64 * SAMPLE_RATE as u64 + rate as u64 / 2) / rate as u64).max(1) as usize;
    let mut output = Vec::with_capacity(target + delay + 2048);
    let mut offset = 0;
    while input.len() - offset >= resampler.input_frames_next() {
        let end = offset + resampler.input_frames_next();
        output.extend(
            resampler
                .process(&[&input[offset..end]], None)
                .map_err(audio_error)?
                .remove(0),
        );
        offset = end;
    }
    if offset < input.len() {
        output.extend(
            resampler
                .process_partial(Some(&[&input[offset..]]), None)
                .map_err(audio_error)?
                .remove(0),
        );
    }
    // Flush the filter tail, then remove its latency to keep timestamps aligned.
    while output.len() < target + delay {
        output.extend(
            resampler
                .process_partial::<&[f32]>(None, None)
                .map_err(audio_error)?
                .remove(0),
        );
    }
    Ok(output[delay..delay + target].to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wav(
        path: &Path,
        rate: u32,
        frames: usize,
        channels: u16,
        signal: impl Fn(usize, u16) -> f32,
    ) {
        let mut writer = hound::WavWriter::create(
            path,
            hound::WavSpec {
                channels,
                sample_rate: rate,
                bits_per_sample: 32,
                sample_format: hound::SampleFormat::Float,
            },
        )
        .unwrap();
        for frame in 0..frames {
            for channel in 0..channels {
                writer.write_sample(signal(frame, channel)).unwrap();
            }
        }
        writer.finalize().unwrap();
    }

    #[test]
    fn decodes_stereo_and_resamples_with_exact_duration_and_channel_average() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("stereo.wav");
        wav(&path, 48_000, 48_000, 2, |_, channel| {
            if channel == 0 {
                0.8
            } else {
                -0.4
            }
        });
        let decoded = decode(&path).unwrap();
        assert_eq!(decoded.duration_ms(), 1000);
        let pcm = prepare(decoded).unwrap();
        assert_eq!(pcm.len(), 16_000);
        assert!(pcm[100..15_900].iter().all(|&s| (s - 0.2).abs() < 0.001));
    }

    #[test]
    fn antialias_filter_rejects_above_nyquist_energy() {
        let tone = |hz: f32| {
            (0..48_000)
                .map(|n| (std::f32::consts::TAU * hz * n as f32 / 48_000.0).sin())
                .collect::<Vec<_>>()
        };
        let rms = |x: &[f32]| (x.iter().map(|s| s * s).sum::<f32>() / x.len() as f32).sqrt();
        let passband = resample(&tone(1000.0), 48_000).unwrap();
        let stopband = resample(&tone(12_000.0), 48_000).unwrap();
        assert!(rms(&passband[100..15_900]) > 0.65);
        assert!(rms(&stopband[100..15_900]) < 0.01);
    }

    #[test]
    fn rejects_empty_long_nonfinite_and_malformed_audio() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.wav");
        wav(&path, 16_000, 0, 1, |_, _| 0.0);
        assert!(decode(&path).is_err());
        wav(&path, 16_000, 480_001, 1, |_, _| 0.0);
        assert!(decode(&path).is_err());
        wav(&path, 16_000, 1, 1, |_, _| f32::NAN);
        assert!(decode(&path).is_err());
        std::fs::write(&path, "not audio").unwrap();
        assert!(decode(&path).is_err());
    }

    #[test]
    fn short_and_boundary_clips_preserve_sample_count_and_clip_amplitude() {
        let short = prepare(DecodedAudio {
            mono: vec![0.0],
            rate: 48_000,
        })
        .unwrap();
        assert_eq!(short.len(), 1);
        let full = prepare(DecodedAudio {
            mono: vec![2.0; 30 * 16_000],
            rate: 16_000,
        })
        .unwrap();
        assert_eq!(full.len(), 480_000);
        assert!(full.iter().all(|&s| s == 1.0));
    }
}
