//! Copy this provider when starting an adapter. The host handles the wire
//! protocol; this implementation owns readiness, audio validation, and metrics.

use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;
use vox_provider::{
    AsrProvider, ModelInfo, Progress, ProviderError, Transcription, TranscriptionMetrics,
};

const MODEL_ID: &str = "template:echo";
static TRACE: AtomicU64 = AtomicU64::new(1);

/// A dependency-free model lifecycle with WAV inspection in place of inference.
/// State intentionally lasts for this process only. A real provider persists
/// downloaded assets, loads its native runtime during preload, and reuses it.
#[derive(Default)]
pub struct EchoProvider {
    installed: bool,
    preloaded: bool,
}

impl EchoProvider {
    fn validate_model(&self, id: &str) -> Result<(), ProviderError> {
        if id != MODEL_ID {
            return Err(ProviderError::new(-32602, format!("Unknown model: {id}")));
        }
        Ok(())
    }

    fn model(&self) -> ModelInfo {
        ModelInfo {
            id: MODEL_ID.into(),
            name: "Rust Echo Example".into(),
            backend: "template".into(),
            installed: self.installed,
            preloaded: self.preloaded,
            available: true,
        }
    }
}

fn elapsed_ms(start: Instant) -> u64 {
    start.elapsed().as_millis() as u64
}

impl AsrProvider for EchoProvider {
    fn models(&mut self) -> Result<Vec<ModelInfo>, ProviderError> {
        Ok(vec![self.model()])
    }

    fn install(
        &mut self,
        model_id: &str,
        progress: &mut Progress<'_>,
    ) -> Result<ModelInfo, ProviderError> {
        self.validate_model(model_id)?;
        self.installed = true;
        progress(1.0, "installed")?;
        Ok(self.model())
    }

    fn preload(
        &mut self,
        model_id: &str,
        progress: &mut Progress<'_>,
    ) -> Result<ModelInfo, ProviderError> {
        self.validate_model(model_id)?;
        if !self.installed {
            return Err(ProviderError::new(12, "Install the model before preload"));
        }
        self.preloaded = true;
        progress(1.0, "ready")?;
        Ok(self.model())
    }

    fn transcribe(&mut self, path: &Path, model_id: &str) -> Result<Transcription, ProviderError> {
        let start = Instant::now();
        let model_start = Instant::now();
        self.validate_model(model_id)?;
        if !self.preloaded {
            return Err(ProviderError::new(
                12,
                "Preload the model before transcription",
            ));
        }
        let model_check_ms = elapsed_ms(model_start);
        let file_start = Instant::now();
        let metadata = std::fs::metadata(path)
            .map_err(|error| ProviderError::new(6, format!("Cannot read audio: {error}")))?;
        if !metadata.is_file() {
            return Err(ProviderError::new(6, "Audio path must be a regular file"));
        }
        let file_check_ms = elapsed_ms(file_start);
        let audio_start = Instant::now();
        let mut reader = hound::WavReader::open(path)
            .map_err(|error| ProviderError::new(6, format!("Invalid WAV: {error}")))?;
        let spec = reader.spec();
        if spec.sample_format != hound::SampleFormat::Int
            || spec.channels == 0
            || spec.sample_rate == 0
        {
            return Err(ProviderError::new(
                6,
                "Expected an integer PCM WAV with a valid sample rate and channels",
            ));
        }
        let expected_samples = u64::from(reader.len());
        let mut samples = 0_u64;
        for sample in reader.samples::<i32>() {
            sample.map_err(|error| ProviderError::new(6, format!("Invalid PCM data: {error}")))?;
            samples += 1;
        }
        if samples != expected_samples || !samples.is_multiple_of(u64::from(spec.channels)) {
            return Err(ProviderError::new(
                6,
                "WAV contains incomplete audio frames",
            ));
        }
        let audio_duration_ms =
            samples / u64::from(spec.channels) * 1000 / u64::from(spec.sample_rate);
        let audio_load_ms = elapsed_ms(audio_start);
        let inference_start = Instant::now();
        let text = format!("[echo] {}", path.display());
        let inference_ms = elapsed_ms(inference_start);
        let total_ms = elapsed_ms(start);
        Ok(Transcription {
            model_id: model_id.into(),
            text,
            elapsed_ms: total_ms,
            words: Vec::new(),
            metrics: TranscriptionMetrics {
                trace_id: format!(
                    "echo-{}-{}",
                    std::process::id(),
                    TRACE.fetch_add(1, Ordering::Relaxed)
                ),
                audio_duration_ms,
                input_bytes: metadata.len(),
                was_preloaded: true,
                model_check_ms,
                file_check_ms,
                audio_load_ms,
                inference_ms,
                total_ms,
                ..Default::default()
            },
        })
    }
}
