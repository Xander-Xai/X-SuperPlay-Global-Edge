//! Runtime binary provenance and integrity verification.
//!
//! The controller receives bytes from its caller and verifies them against a
//! reviewed manifest. This module performs no file I/O, starts no process, and
//! reads no network resource.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProvenanceManifest {
    pub name: String,
    pub version: String,
    pub sha256: String,
    pub source: String,
    pub license: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ProvenanceError {
    #[error("invalid sha256 digest")]
    InvalidDigest,
    #[error("binary digest does not match the manifest")]
    DigestMismatch,
    #[error("manifest name is empty")]
    EmptyName,
    #[error("manifest version is empty")]
    EmptyVersion,
    #[error("manifest source is empty")]
    EmptySource,
    #[error("manifest license is empty")]
    EmptyLicense,
}

impl ProvenanceManifest {
    pub fn validate(&self) -> Result<(), ProvenanceError> {
        if self.name.trim().is_empty() {
            return Err(ProvenanceError::EmptyName);
        }
        if self.version.trim().is_empty() {
            return Err(ProvenanceError::EmptyVersion);
        }
        if self.source.trim().is_empty() {
            return Err(ProvenanceError::EmptySource);
        }
        if self.license.trim().is_empty() {
            return Err(ProvenanceError::EmptyLicense);
        }
        normalize_digest(&self.sha256)?;
        Ok(())
    }

    pub fn verify_bytes(&self, bytes: &[u8]) -> Result<(), ProvenanceError> {
        self.validate()?;
        let expected = normalize_digest(&self.sha256)?;
        if sha256_hex(bytes) != expected {
            return Err(ProvenanceError::DigestMismatch);
        }
        Ok(())
    }
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    hex_lower(digest.as_ref())
}

fn normalize_digest(value: &str) -> Result<String, ProvenanceError> {
    let trimmed = value.trim();
    if trimmed.len() != 64
        || !trimmed
            .chars()
            .all(|character| character.is_ascii_hexdigit())
    {
        return Err(ProvenanceError::InvalidDigest);
    }
    Ok(trimmed.to_ascii_lowercase())
}

fn hex_lower(bytes: &[u8]) -> String {
    let mut value = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        value.push_str(&format!("{byte:02x}"));
    }
    value
}

#[cfg(test)]
mod tests {
    use super::*;

    const ABC_SHA256: &str = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    fn manifest() -> ProvenanceManifest {
        ProvenanceManifest {
            name: "edge-core".to_string(),
            version: "1.0.0".to_string(),
            sha256: ABC_SHA256.to_string(),
            source: "reviewed-release".to_string(),
            license: "MIT".to_string(),
        }
    }

    #[test]
    fn computes_a_known_sha256_vector() {
        assert_eq!(sha256_hex(b"abc"), ABC_SHA256);
    }

    #[test]
    fn verifies_matching_bytes_case_insensitively() {
        let mut value = manifest();
        value.sha256 = ABC_SHA256.to_ascii_uppercase();
        assert!(value.verify_bytes(b"abc").is_ok());
    }

    #[test]
    fn rejects_tampered_bytes() {
        assert_eq!(
            manifest().verify_bytes(b"abd"),
            Err(ProvenanceError::DigestMismatch)
        );
    }

    #[test]
    fn rejects_malformed_digests() {
        let mut value = manifest();
        value.sha256 = "abc".to_string();
        assert_eq!(value.validate(), Err(ProvenanceError::InvalidDigest));
        value.sha256 = "g".repeat(64);
        assert_eq!(value.validate(), Err(ProvenanceError::InvalidDigest));
    }

    #[test]
    fn rejects_empty_required_fields() {
        let mut value = manifest();
        value.name.clear();
        assert_eq!(value.validate(), Err(ProvenanceError::EmptyName));
        value = manifest();
        value.version.clear();
        assert_eq!(value.validate(), Err(ProvenanceError::EmptyVersion));
        value = manifest();
        value.source.clear();
        assert_eq!(value.validate(), Err(ProvenanceError::EmptySource));
        value = manifest();
        value.license.clear();
        assert_eq!(value.validate(), Err(ProvenanceError::EmptyLicense));
    }

    #[test]
    fn rejects_unknown_manifest_fields() {
        let parsed = serde_json::from_str::<ProvenanceManifest>(
            r#"{"name":"edge-core","version":"1","sha256":"00","source":"release","license":"MIT","extra":true}"#,
        );
        assert!(parsed.is_err());
    }
}
