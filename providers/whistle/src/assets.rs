use crate::error;
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;
use vox_provider::{Progress, ProviderError};

const HF_BASE_URL: &str = "https://huggingface.co";
pub const MODEL_REVISION: &str = "b358ddadd89b7a713b5aa131f23032d3cca1b251";
pub const RUNTIME_REVISION: &str = "2ae11323dc000f5e70c49f7403efa6af12ba9e67";
const WHEEL_PATH: &str = "python/cactus_needle-3.2.0-py3-none-macosx_11_0_arm64.whl";

struct Artifact {
    name: &'static str,
    size: u64,
    sha256: &'static str,
}

// Sizes and model/archive hashes come from the pinned repositories' LFS objects.
// The dylib hash is verified from the exact, hash-checked archive member.
const MODEL: Artifact = Artifact {
    name: "whistle.cact",
    size: 16_919_407,
    sha256: "b6e02f048568ac5d01a2042556c658061e699acbc0aa2a1439f52f3d461dffeb",
};
const LIBRARY: Artifact = Artifact {
    name: "libneedle3.dylib",
    size: 1_070_448,
    sha256: "6794ef011da58f6138a2c1e7103dcb73b401ddfb9aa67cc28b31fadded7ff780",
};
const WHEEL: Artifact = Artifact {
    name: "runtime.whl",
    size: 535_559,
    sha256: "3b0887a43cd6e9a99009fabf35b231c11bb3a978ab8af94b8119b2eb76e19832",
};

fn sha256(path: &Path) -> std::io::Result<String> {
    let mut source = File::open(path)?;
    let mut hash = Sha256::new();
    let mut buffer = [0; 64 * 1024];
    loop {
        let count = source.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    Ok(format!("{:x}", hash.finalize()))
}

fn verify(path: &Path, artifact: &Artifact) -> bool {
    path.metadata()
        .is_ok_and(|m| m.is_file() && m.len() == artifact.size)
        && sha256(path).is_ok_and(|digest| digest == artifact.sha256)
}

fn download(url: &str, target: &Path, artifact: &Artifact) -> Result<(), ProviderError> {
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(20))
        .timeout_read(Duration::from_secs(120))
        .timeout_write(Duration::from_secs(20))
        .build();
    let response = agent
        .get(url)
        .call()
        .map_err(|e| error(12, format!("Whistle download failed: {e}")))?;
    let mut reader = response.into_reader().take(artifact.size + 1);
    let mut file = File::create(target).map_err(install_error)?;
    std::io::copy(&mut reader, &mut file).map_err(install_error)?;
    file.sync_all().map_err(install_error)?;
    if !verify(target, artifact) {
        return Err(error(
            12,
            format!("Whistle download checksum mismatch: {}", artifact.name),
        ));
    }
    Ok(())
}

fn install_error(e: impl std::fmt::Display) -> ProviderError {
    error(12, format!("Whistle install failed: {e}"))
}

fn extract_library(archive: &Path, target: &Path) -> Result<(), ProviderError> {
    let mut archive =
        zip::ZipArchive::new(File::open(archive).map_err(install_error)?).map_err(install_error)?;
    let mut member = archive
        .by_name("needle/libneedle3.dylib")
        .map_err(install_error)?;
    if member.size() != LIBRARY.size {
        return Err(error(12, "Unexpected Needle runtime size."));
    }
    let mut target_file = File::create(target).map_err(install_error)?;
    std::io::copy(&mut member, &mut target_file).map_err(install_error)?;
    target_file.sync_all().map_err(install_error)?;
    if !verify(target, &LIBRARY) {
        return Err(error(12, "Needle runtime checksum mismatch."));
    }
    Ok(())
}

pub struct Assets {
    directory: PathBuf,
}

impl Assets {
    pub fn new(directory: PathBuf) -> Self {
        Self { directory }
    }
    pub fn model_path(&self) -> PathBuf {
        self.directory.join(MODEL.name)
    }
    pub fn library_path(&self) -> PathBuf {
        self.directory.join(LIBRARY.name)
    }

    pub fn installed(&self) -> bool {
        // Trust exact pinned bytes, not a writable marker. This also reuses the
        // matching files installed by the previous Python adapter safely.
        verify(&self.model_path(), &MODEL) && verify(&self.library_path(), &LIBRARY)
    }

    pub fn install(&self, progress: &mut Progress<'_>) -> Result<(), ProviderError> {
        fs::create_dir_all(&self.directory).map_err(install_error)?;
        let stage = tempfile::tempdir_in(&self.directory).map_err(install_error)?;
        let model = stage.path().join(MODEL.name);
        let library = stage.path().join(LIBRARY.name);
        if !verify(&self.model_path(), &MODEL) {
            progress(0.05, "downloading Whistle model")?;
            let url = format!(
                "{HF_BASE_URL}/Cactus-Compute/whistle/resolve/{MODEL_REVISION}/{}",
                MODEL.name
            );
            download(&url, &model, &MODEL)?;
        }
        if !verify(&self.library_path(), &LIBRARY) {
            progress(0.6, "downloading Needle runtime")?;
            let archive = stage.path().join(WHEEL.name);
            let url = format!(
                "{HF_BASE_URL}/Cactus-Compute/needle3/resolve/{RUNTIME_REVISION}/{WHEEL_PATH}"
            );
            download(&url, &archive, &WHEEL)?;
            extract_library(&archive, &library)?;
        }
        // No destination is touched until every newly downloaded artifact passes.
        if model.exists() {
            fs::rename(model, self.model_path()).map_err(install_error)?;
        }
        if library.exists() {
            fs::rename(library, self.library_path()).map_err(install_error)?;
        }
        let metadata = serde_json::json!({
            "provider": "vox-whistle", "engineVersion": "3.2.0",
            "modelRevision": MODEL_REVISION, "runtimeRevision": RUNTIME_REVISION,
            "platform": "macos-arm64",
            "files": {
                MODEL.name: {"size": MODEL.size, "sha256": MODEL.sha256},
                LIBRARY.name: {"size": LIBRARY.size, "sha256": LIBRARY.sha256}
            }
        });
        let marker = stage.path().join("installed.json");
        File::create(&marker)
            .and_then(|mut f| f.write_all(metadata.to_string().as_bytes()))
            .map_err(install_error)?;
        fs::rename(marker, self.directory.join("installed.json")).map_err(install_error)?;
        progress(1.0, "installed")?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_bytes_even_when_size_and_metadata_look_correct() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("artifact");
        let artifact = Artifact {
            name: "artifact",
            size: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        };
        fs::write(&file, "abc").unwrap();
        assert!(verify(&file, &artifact));
        fs::write(&file, "Abc").unwrap();
        assert!(!verify(&file, &artifact));
        fs::write(&file, "abcd").unwrap();
        assert!(!verify(&file, &artifact));
    }

    #[test]
    fn mutable_or_invalid_markers_cannot_claim_installed() {
        let dir = tempfile::tempdir().unwrap();
        let assets = Assets::new(dir.path().into());
        for marker in ["[]", "null", "{\"installed\":true}"] {
            fs::write(dir.path().join("installed.json"), marker).unwrap();
            assert!(!assets.installed());
        }
        fs::write(assets.model_path(), b"fake model").unwrap();
        fs::write(assets.library_path(), b"fake library").unwrap();
        assert!(!assets.installed());
    }

    #[test]
    fn archive_cannot_extract_arbitrary_paths_or_wrong_runtime_size() {
        let dir = tempfile::tempdir().unwrap();
        let archive_path = dir.path().join("runtime.zip");
        let mut writer = zip::ZipWriter::new(File::create(&archive_path).unwrap());
        writer
            .start_file("../escaped", zip::write::SimpleFileOptions::default())
            .unwrap();
        writer.write_all(b"bad").unwrap();
        writer.finish().unwrap();
        assert!(extract_library(&archive_path, &dir.path().join("runtime")).is_err());
        assert!(!dir.path().join("runtime").exists());
    }
}
