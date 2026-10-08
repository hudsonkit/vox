use crate::error;
use libloading::Library;
use serde::Deserialize;
use std::ffi::{c_char, c_int, CStr, CString};
use std::path::Path;
use vox_provider::{ProviderError, WordTiming};

// Exact ABI: vendor/needle.h, Cactus-Compute/needle3 revision
// 2ae11323dc000f5e70c49f7403efa6af12ba9e67/macos-arm64/needle.h.
type Load = unsafe extern "C" fn(*const u8, u64) -> c_int;
type Transcribe = unsafe extern "C" fn(
    *const f32,
    c_int,
    *const c_char,
    *const c_char,
    c_int,
    *mut c_char,
    c_int,
) -> c_int;
type LastError = unsafe extern "C" fn() -> *const c_char;

pub struct Options {
    language: Option<CString>,
    keywords: Option<CString>,
}

impl Options {
    pub fn from_env() -> Result<Self, ProviderError> {
        Self::parse(
            &std::env::var("VOX_WHISTLE_LANGUAGE").unwrap_or_default(),
            &std::env::var("VOX_WHISTLE_KEYWORDS").unwrap_or_default(),
        )
    }

    fn parse(language: &str, keywords: &str) -> Result<Self, ProviderError> {
        let language = language.trim().to_lowercase();
        if !language.is_empty()
            && !["en", "de", "fr", "es", "it", "nl", "pl"].contains(&language.as_str())
        {
            return Err(error(
                -32602,
                "VOX_WHISTLE_LANGUAGE must be en, de, fr, es, it, nl, or pl.",
            ));
        }
        let keywords = keywords
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join("\n");
        fn optional(value: String) -> Result<Option<CString>, ProviderError> {
            if value.is_empty() {
                return Ok(None);
            }
            CString::new(value)
                .map(Some)
                .map_err(|_| error(-32602, "Whistle options cannot contain NUL bytes."))
        }
        Ok(Self {
            language: optional(language)?,
            keywords: optional(keywords)?,
        })
    }
}

pub struct Engine {
    // The library outlives every function pointer. The host gives this singleton
    // one worker: Needle's model state is process-global and not thread-safe.
    _library: Library,
    _weights: Vec<u8>,
    transcribe: Transcribe,
    last_error: LastError,
}

impl Engine {
    pub fn load(library_path: &Path, model_path: &Path) -> Result<Self, ProviderError> {
        let weights = std::fs::read(model_path)
            .map_err(|e| error(12, format!("Could not read Whistle weights: {e}")))?;
        // SAFETY: caller verifies both files against compiled pinned checksums.
        // These symbols and signatures match the vendored C header exactly.
        let library = unsafe { Library::new(library_path) }
            .map_err(|e| error(12, format!("Could not load Needle runtime: {e}")))?;
        unsafe {
            let load: Load = *library.get(b"needle_load\0").map_err(symbol_error)?;
            let transcribe: Transcribe =
                *library.get(b"needle_transcribe\0").map_err(symbol_error)?;
            let last_error: LastError =
                *library.get(b"needle_last_error\0").map_err(symbol_error)?;
            let engine = Self {
                _library: library,
                _weights: weights,
                transcribe,
                last_error,
            };
            if load(engine._weights.as_ptr(), engine._weights.len() as u64) < 0 {
                return Err(engine.failure("Whistle model load failed"));
            }
            Ok(engine)
        }
    }

    fn failure(&self, context: &str) -> ProviderError {
        // SAFETY: runtime owns a NUL-terminated string until its next call.
        // We copy it immediately while holding the sole mutable engine owner.
        let pointer = unsafe { (self.last_error)() };
        let detail = if pointer.is_null() {
            "unknown native error".into()
        } else {
            unsafe { CStr::from_ptr(pointer) }
                .to_string_lossy()
                .into_owned()
        };
        error(12, format!("{context}: {detail}"))
    }

    pub fn transcribe(
        &mut self,
        pcm: &[f32],
        options: &Options,
    ) -> Result<EngineResult, ProviderError> {
        if pcm.is_empty()
            || pcm.len() > 30 * 16_000
            || pcm.iter().any(|s| !s.is_finite() || s.abs() > 1.0)
        {
            return Err(error(
                6,
                "Whistle needs finite mono 16 kHz PCM, up to 30 seconds.",
            ));
        }
        let mut output = vec![0u8; 1 << 18];
        let ptr = |s: &Option<CString>| s.as_ref().map_or(std::ptr::null(), |s| s.as_ptr());
        // SAFETY: buffers remain valid throughout this synchronous call, their
        // lengths fit c_int, and strings are NUL terminated or null.
        let code = unsafe {
            (self.transcribe)(
                pcm.as_ptr(),
                pcm.len() as c_int,
                ptr(&options.language),
                ptr(&options.keywords),
                1,
                output.as_mut_ptr().cast(),
                output.len() as c_int,
            )
        };
        if code < 0 {
            return Err(self.failure("Whistle transcription failed"));
        }
        let end = output
            .iter()
            .position(|&b| b == 0)
            .ok_or_else(|| error(12, "Needle returned an unterminated transcript."))?;
        parse_result(&output[..end])
    }
}

fn symbol_error(e: libloading::Error) -> ProviderError {
    error(12, format!("Incompatible Needle runtime: {e}"))
}

#[derive(Deserialize)]
struct NativeWord {
    word: String,
    start: f64,
    end: f64,
    probability: f32,
}
#[derive(Deserialize)]
struct NativeResult {
    text: String,
    #[serde(default)]
    words: Vec<NativeWord>,
}
pub struct EngineResult {
    pub text: String,
    pub words: Vec<WordTiming>,
}

fn parse_result(json: &[u8]) -> Result<EngineResult, ProviderError> {
    let raw: NativeResult = serde_json::from_slice(json)
        .map_err(|e| error(12, format!("Invalid Needle transcript: {e}")))?;
    let words = raw
        .words
        .into_iter()
        .map(|w| {
            if !w.start.is_finite()
                || !w.end.is_finite()
                || !w.probability.is_finite()
                || w.start < 0.0
                || w.end < w.start
                || !(0.0..=1.0).contains(&w.probability)
            {
                return Err(error(12, "Needle returned invalid word timing/confidence."));
            }
            Ok(WordTiming {
                word: w.word,
                start: w.start,
                end: w.end,
                confidence: w.probability,
            })
        })
        .collect::<Result<Vec<_>, ProviderError>>()?;
    Ok(EngineResult {
        text: raw.text,
        words,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_transcript_and_maps_probability_to_confidence() {
        let result = parse_result(br#"{"text":"hello","words":[{"word":"hello","start":0.1,"end":0.5,"probability":0.95}]}"#).unwrap();
        assert_eq!(result.text, "hello");
        assert_eq!(result.words[0].word, "hello");
        assert_eq!(result.words[0].start, 0.1);
        assert_eq!(result.words[0].end, 0.5);
        assert_eq!(result.words[0].confidence, 0.95);
        assert!(parse_result(br#"{"text":"","words":[]}"#)
            .unwrap()
            .words
            .is_empty());
    }

    #[test]
    fn rejects_invalid_native_results() {
        for data in [
            r#"{"words":[]}"#,
            r#"{"text":7}"#,
            r#"{"text":"x","words":[{"word":"x","start":1,"end":0,"probability":0.5}]}"#,
            r#"{"text":"x","words":[{"word":"x","start":0,"end":1,"probability":1.1}]}"#,
            r#"{"text":"x","words":[{"word":"x","start":0,"end":1e999,"probability":0.5}]}"#,
        ] {
            assert!(parse_result(data.as_bytes()).is_err(), "{data}");
        }
    }

    #[test]
    fn validates_language_and_keyword_c_strings() {
        let options = Options::parse(" FR ", "Vox, Siobhan, ").unwrap();
        assert_eq!(options.language.unwrap().to_bytes(), b"fr");
        assert_eq!(options.keywords.unwrap().to_bytes(), b"Vox\nSiobhan");
        let automatic = Options::parse("", "").unwrap();
        assert!(automatic.language.is_none() && automatic.keywords.is_none());
        assert!(Options::parse("zh", "").is_err());
        assert!(Options::parse("", "bad\0word").is_err());
    }
}
