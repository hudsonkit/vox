//! Controlled provider used only by the subprocess protocol tests.
use std::path::Path;
use std::time::{Duration, Instant};
use vox_provider::{
    AsrProvider, ModelInfo, Progress, ProviderError, Transcription, TranscriptionMetrics,
    WordTiming,
};

#[derive(Default)]
struct Fixture {
    ready: bool,
}

impl Fixture {
    fn model(&self) -> ModelInfo {
        ModelInfo {
            id: "fixture".into(),
            name: "Fixture".into(),
            backend: "test".into(),
            installed: true,
            preloaded: self.ready,
            available: true,
        }
    }
}

impl AsrProvider for Fixture {
    fn models(&mut self) -> Result<Vec<ModelInfo>, ProviderError> {
        println!("rust diagnostic");
        #[cfg(unix)]
        unsafe {
            let log = b"native diagnostic\n";
            libc::write(1, log.as_ptr().cast(), log.len());
            libc::printf(c"buffered native diagnostic\n".as_ptr());
        }
        Ok(vec![self.model()])
    }

    fn install(
        &mut self,
        _model_id: &str,
        _progress: &mut Progress<'_>,
    ) -> Result<ModelInfo, ProviderError> {
        Err(ProviderError::new(12, "fixture install failure"))
    }

    fn preload(
        &mut self,
        _model_id: &str,
        progress: &mut Progress<'_>,
    ) -> Result<ModelInfo, ProviderError> {
        progress(0.25, "waiting")?;
        let path = std::env::var_os("VOX_TEST_RELEASE_FILE").expect("test release file");
        let start = Instant::now();
        while !Path::new(&path).exists() {
            if start.elapsed() > Duration::from_secs(10) {
                return Err(ProviderError::new(12, "test release timed out"));
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        self.ready = true;
        progress(1.0, "ready")?;
        Ok(self.model())
    }

    fn transcribe(&mut self, path: &Path, model_id: &str) -> Result<Transcription, ProviderError> {
        if path == Path::new("panic") {
            panic!("fixture panic");
        }
        if path == Path::new("error") {
            return Err(ProviderError::new(6, "fixture audio failure"));
        }
        let words = if path == Path::new("nonfinite") {
            vec![WordTiming {
                word: "word".into(),
                start: f64::NAN,
                end: 1.0,
                confidence: 1.0,
            }]
        } else {
            Vec::new()
        };
        Ok(Transcription {
            model_id: model_id.into(),
            text: "fixture".into(),
            elapsed_ms: 0,
            words,
            metrics: TranscriptionMetrics::default(),
        })
    }

    fn shutdown(&mut self) -> Result<(), ProviderError> {
        println!("fixture shutdown");
        Ok(())
    }
}

fn main() -> std::io::Result<()> {
    vox_provider::serve(Fixture::default())
}
