mod assets;
mod audio;
mod engine;

use std::path::{Path, PathBuf};
use std::time::Instant;
use vox_provider::{
    AsrProvider, ModelInfo, Progress, ProviderError, Transcription, TranscriptionMetrics,
};

const MODEL_ID: &str = "whistle";

fn error(code: i64, message: impl Into<String>) -> ProviderError {
    ProviderError::new(code, message)
}

fn milliseconds(start: Instant) -> u64 {
    start.elapsed().as_millis().try_into().unwrap_or(u64::MAX)
}

struct WhistleProvider {
    assets: assets::Assets,
    engine: Option<engine::Engine>,
}

impl WhistleProvider {
    fn new(home: PathBuf) -> Self {
        Self {
            assets: assets::Assets::new(home.join("models/whistle")),
            engine: None,
        }
    }

    fn validate_id(model_id: &str) -> Result<(), ProviderError> {
        if model_id != MODEL_ID {
            return Err(error(-32602, "Unknown Whistle model. Use 'whistle'."));
        }
        Ok(())
    }

    fn supported() -> bool {
        cfg!(all(target_os = "macos", target_arch = "aarch64"))
    }

    fn info(&self) -> ModelInfo {
        let installed = Self::supported() && self.assets.installed();
        ModelInfo {
            id: MODEL_ID.into(),
            name: "Cactus Whistle".into(),
            backend: "whistle".into(),
            installed,
            preloaded: installed && self.engine.is_some(),
            available: Self::supported(),
        }
    }

    fn require_installed(&self) -> Result<(), ProviderError> {
        if !Self::supported() {
            return Err(error(12, "Whistle currently supports Apple Silicon macOS."));
        }
        if !self.assets.installed() {
            return Err(error(
                12,
                "Whistle model/runtime is missing or corrupt. Run 'vox models install whistle'.",
            ));
        }
        Ok(())
    }

    fn load(&mut self) -> Result<(), ProviderError> {
        if self.engine.is_none() {
            self.engine = Some(engine::Engine::load(
                &self.assets.library_path(),
                &self.assets.model_path(),
            )?);
        }
        Ok(())
    }
}

impl AsrProvider for WhistleProvider {
    fn models(&mut self) -> Result<Vec<ModelInfo>, ProviderError> {
        Ok(vec![self.info()])
    }

    fn install(
        &mut self,
        model_id: &str,
        progress: &mut Progress<'_>,
    ) -> Result<ModelInfo, ProviderError> {
        Self::validate_id(model_id)?;
        if !Self::supported() {
            return Err(error(12, "Whistle currently supports Apple Silicon macOS."));
        }
        if self.assets.installed() {
            progress(1.0, "installed")?;
        } else {
            if self.engine.is_some() {
                return Err(error(
                    12,
                    "Restart the Whistle provider before repairing its resident runtime.",
                ));
            }
            self.assets.install(progress)?;
        }
        Ok(self.info())
    }

    fn preload(
        &mut self,
        model_id: &str,
        progress: &mut Progress<'_>,
    ) -> Result<ModelInfo, ProviderError> {
        Self::validate_id(model_id)?;
        self.require_installed()?;
        progress(0.1, "loading Whistle")?;
        self.load()?;
        progress(1.0, "ready")?;
        Ok(self.info())
    }

    fn transcribe(&mut self, path: &Path, model_id: &str) -> Result<Transcription, ProviderError> {
        let total = Instant::now();
        Self::validate_id(model_id)?;
        let options = engine::Options::from_env()?;
        let mut metrics = TranscriptionMetrics {
            trace_id: uuid::Uuid::new_v4().simple().to_string()[..12].into(),
            was_preloaded: self.engine.is_some(),
            ..Default::default()
        };
        let stage = Instant::now();
        let metadata = path
            .metadata()
            .map_err(|e| error(6, format!("Audio file is unavailable: {e}")))?;
        if !metadata.is_file() {
            return Err(error(6, "Audio path is not a regular file."));
        }
        metrics.input_bytes = metadata.len();
        metrics.file_check_ms = milliseconds(stage);
        let stage = Instant::now();
        self.require_installed()?;
        metrics.model_check_ms = milliseconds(stage);
        let stage = Instant::now();
        let decoded = audio::decode(path)?;
        metrics.audio_duration_ms = decoded.duration_ms();
        metrics.audio_load_ms = milliseconds(stage);
        let stage = Instant::now();
        let pcm = audio::prepare(decoded)?;
        metrics.audio_prepare_ms = milliseconds(stage);
        let stage = Instant::now();
        self.load()?;
        metrics.model_load_ms = milliseconds(stage);
        let stage = Instant::now();
        let result = self
            .engine
            .as_mut()
            .expect("load installed engine")
            .transcribe(&pcm, &options)?;
        metrics.inference_ms = milliseconds(stage);
        metrics.total_ms = milliseconds(total);
        Ok(Transcription {
            model_id: MODEL_ID.into(),
            text: result.text,
            elapsed_ms: metrics.total_ms,
            metrics,
            words: result.words,
        })
    }
}

fn main() -> std::io::Result<()> {
    let home = std::env::var_os("VOX_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".vox")
        });
    vox_provider::serve(WhistleProvider::new(home))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn discovery_and_missing_install_are_offline_and_do_not_create_directories() {
        let dir = tempfile::tempdir().unwrap();
        let mut provider = WhistleProvider::new(dir.path().join("new"));
        let models = provider.models().unwrap();
        assert!(!models[0].installed);
        assert!(!models[0].preloaded);
        assert!(provider.preload("whistle", &mut |_, _| Ok(())).is_err());
        assert!(!dir.path().join("new").exists());
    }

    #[test]
    fn unknown_model_never_loads_or_downloads() {
        let dir = tempfile::tempdir().unwrap();
        let mut provider = WhistleProvider::new(dir.path().join("new"));
        assert!(provider.install("wrong", &mut |_, _| Ok(())).is_err());
        assert!(provider.preload("wrong", &mut |_, _| Ok(())).is_err());
        assert!(provider
            .transcribe(Path::new("missing.wav"), "wrong")
            .is_err());
        assert!(!dir.path().join("new").exists());
    }
}
