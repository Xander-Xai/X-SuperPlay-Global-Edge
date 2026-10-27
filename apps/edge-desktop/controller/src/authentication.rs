//! Token authentication for the local controller channel.

use crate::contract::ErrorBody;
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum AuthError {
    #[error("unauthorized")]
    Unauthorized,
    #[error("token generation failed")]
    Generation,
}

impl AuthError {
    pub fn to_error_body(&self) -> ErrorBody {
        match self {
            Self::Unauthorized => ErrorBody::unauthorized(),
            Self::Generation => ErrorBody::internal("token generation failed"),
        }
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct AuthCredential(String);

impl AuthCredential {
    /// Generates 32 random bytes and stores them as lowercase hex.
    pub fn generate() -> Result<Self, AuthError> {
        let mut bytes = [0u8; 32];
        getrandom::getrandom(&mut bytes).map_err(|_| AuthError::Generation)?;
        let mut value = String::with_capacity(bytes.len() * 2);
        for byte in bytes {
            value.push_str(&format!("{byte:02x}"));
        }
        Ok(Self(value))
    }

    pub fn from_hex(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for AuthCredential {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("AuthCredential([redacted])")
    }
}

pub struct Authenticator {
    credential: AuthCredential,
}

impl Authenticator {
    pub fn new(credential: AuthCredential) -> Self {
        Self { credential }
    }

    pub fn authenticate(&self, presented: Option<&str>) -> Result<(), AuthError> {
        match presented {
            Some(value)
                if constant_time_eq(value.as_bytes(), self.credential.as_str().as_bytes()) =>
            {
                Ok(())
            }
            _ => Err(AuthError::Unauthorized),
        }
    }
}

/// Compares two byte slices without an early exit on the first mismatch.
pub fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    let mut difference = 0u8;
    for (left_byte, right_byte) in left.iter().zip(right.iter()) {
        difference |= left_byte ^ right_byte;
    }
    difference == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn credential() -> AuthCredential {
        AuthCredential::from_hex("ab".repeat(32))
    }

    #[test]
    fn accepts_the_exact_token() {
        let authenticator = Authenticator::new(credential());
        assert!(authenticator
            .authenticate(Some(credential().as_str()))
            .is_ok());
    }

    #[test]
    fn rejects_wrong_missing_and_empty_tokens() {
        let authenticator = Authenticator::new(credential());
        assert_eq!(
            authenticator.authenticate(Some("00")),
            Err(AuthError::Unauthorized)
        );
        assert_eq!(
            authenticator.authenticate(None),
            Err(AuthError::Unauthorized)
        );
        assert_eq!(
            authenticator.authenticate(Some("")),
            Err(AuthError::Unauthorized)
        );
    }

    #[test]
    fn compares_without_length_side_channel() {
        assert!(constant_time_eq(b"abcd", b"abcd"));
        assert!(!constant_time_eq(b"abcd", b"abce"));
        assert!(!constant_time_eq(b"abc", b"abcd"));
    }

    #[test]
    fn generated_tokens_are_hex_and_redacted_in_debug() {
        let generated = AuthCredential::generate().unwrap();
        assert_eq!(generated.as_str().len(), 64);
        assert!(generated
            .as_str()
            .chars()
            .all(|value| value.is_ascii_hexdigit()));
        assert_eq!(format!("{generated:?}"), "AuthCredential([redacted])");
    }
}
