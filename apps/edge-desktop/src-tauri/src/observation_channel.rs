//! Local proof of the future authenticated observation boundary.
//!
//! This module is deliberately not exposed as a Tauri command. It accepts a
//! typed resource enum, performs one bounded GET over mutually authenticated
//! TLS, and returns only a bounded response. The test-only fixture below binds
//! to `127.0.0.1:0` and creates all certificates in memory.

use std::fmt;
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::Arc;
use std::time::Duration;

use rustls::pki_types::{CertificateDer, PrivatePkcs8KeyDer, ServerName};
use rustls::{ClientConfig, ClientConnection, RootCertStore, StreamOwned};
#[cfg(test)]
use sha2::{Digest, Sha256};

pub const REQUEST_TIMEOUT_MS: u64 = 5_000;
pub const MAX_RESPONSE_BYTES: usize = 1_048_576;
pub const NATIVE_MAX_ATTEMPTS: usize = 1;
pub const NATIVE_METHOD_POLICY: &str = "GET_ONLY";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ObservationResource {
    NodeStatus,
    NodeIdentity,
    NodeCapabilities,
    NodeServices,
    NodeConnection,
    NodeMetadata,
    HealthCurrent,
    HealthHistory,
    Events,
    Metrics,
}

impl ObservationResource {
    pub const ALL: [Self; 10] = [
        Self::NodeStatus,
        Self::NodeIdentity,
        Self::NodeCapabilities,
        Self::NodeServices,
        Self::NodeConnection,
        Self::NodeMetadata,
        Self::HealthCurrent,
        Self::HealthHistory,
        Self::Events,
        Self::Metrics,
    ];

    pub const fn path(self) -> &'static str {
        match self {
            Self::NodeStatus => "/api/v1/node/status",
            Self::NodeIdentity => "/api/v1/node/identity",
            Self::NodeCapabilities => "/api/v1/node/capabilities",
            Self::NodeServices => "/api/v1/node/services",
            Self::NodeConnection => "/api/v1/node/connection",
            Self::NodeMetadata => "/api/v1/node/metadata",
            Self::HealthCurrent => "/api/v1/health/current",
            Self::HealthHistory => "/api/v1/health/history",
            Self::Events => "/api/v1/events",
            Self::Metrics => "/metrics",
        }
    }
}

#[derive(Debug, Eq, PartialEq)]
pub enum ChannelError {
    InvalidConfiguration(&'static str),
    InvalidResource,
    Timeout,
    TlsHandshake,
    Transport,
    ResponseTooLarge,
    MalformedResponse,
    HttpStatus(u16),
}

impl fmt::Display for ChannelError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidConfiguration(message) => f.write_str(message),
            Self::InvalidResource => f.write_str("observation resource is not allowlisted"),
            Self::Timeout => f.write_str("observation request timed out"),
            Self::TlsHandshake => f.write_str("observation TLS handshake failed"),
            Self::Transport => f.write_str("observation transport failed"),
            Self::ResponseTooLarge => f.write_str("observation response exceeded the size limit"),
            Self::MalformedResponse => f.write_str("observation response was malformed"),
            Self::HttpStatus(status) => write!(f, "observation HTTP status {status}"),
        }
    }
}

impl std::error::Error for ChannelError {}

#[derive(Debug, Eq, PartialEq)]
pub struct ObservationResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

/// Native-only client surface. No URL, method, filesystem path, certificate,
/// or private key is accepted from the renderer.
pub struct SecureObservationClient {
    config: Arc<ClientConfig>,
    server_name: ServerName<'static>,
    timeout: Duration,
}

impl SecureObservationClient {
    pub fn from_credentials(
        ca_certificate_der: Vec<u8>,
        client_certificate_der: Vec<u8>,
        client_private_key_der: Vec<u8>,
    ) -> Result<Self, ChannelError> {
        ensure_crypto_provider();
        let mut roots = RootCertStore::empty();
        roots
            .add(CertificateDer::from(ca_certificate_der))
            .map_err(|_| ChannelError::InvalidConfiguration("invalid test trust anchor"))?;
        let cert_chain = vec![CertificateDer::from(client_certificate_der)];
        let key = PrivatePkcs8KeyDer::from(client_private_key_der);
        let config = ClientConfig::builder()
            .with_root_certificates(roots)
            .with_client_auth_cert(cert_chain, key.into())
            .map_err(|_| ChannelError::InvalidConfiguration("invalid client identity"))?;
        Ok(Self {
            config: Arc::new(config),
            server_name: ServerName::try_from("localhost".to_owned())
                .map_err(|_| ChannelError::InvalidConfiguration("invalid local server name"))?,
            timeout: Duration::from_millis(REQUEST_TIMEOUT_MS),
        })
    }

    #[cfg(test)]
    fn without_client_certificate(ca_certificate_der: Vec<u8>) -> Result<Self, ChannelError> {
        ensure_crypto_provider();
        let mut roots = RootCertStore::empty();
        roots
            .add(CertificateDer::from(ca_certificate_der))
            .map_err(|_| ChannelError::InvalidConfiguration("invalid test trust anchor"))?;
        let config = ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        Ok(Self {
            config: Arc::new(config),
            server_name: ServerName::try_from("localhost".to_owned())
                .map_err(|_| ChannelError::InvalidConfiguration("invalid local server name"))?,
            timeout: Duration::from_millis(REQUEST_TIMEOUT_MS),
        })
    }

    #[cfg(test)]
    fn with_test_server_name(mut self, name: &str) -> Self {
        self.server_name = ServerName::try_from(name.to_owned()).expect("test server name");
        self
    }

    #[cfg(test)]
    fn with_test_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    pub fn get(
        &self,
        endpoint: SocketAddr,
        resource: ObservationResource,
    ) -> Result<ObservationResponse, ChannelError> {
        let stream = TcpStream::connect_timeout(&endpoint, self.timeout).map_err(map_io_error)?;
        stream
            .set_read_timeout(Some(self.timeout))
            .map_err(map_io_error)?;
        stream
            .set_write_timeout(Some(self.timeout))
            .map_err(map_io_error)?;
        let connection = ClientConnection::new(self.config.clone(), self.server_name.clone())
            .map_err(|_| ChannelError::TlsHandshake)?;
        let mut stream = StreamOwned::new(connection, stream);
        let request = format!(
            "GET {} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
            resource.path()
        );
        stream.write_all(request.as_bytes()).map_err(map_io_error)?;
        stream.flush().map_err(map_io_error)?;
        read_response(&mut stream)
    }
}

fn ensure_crypto_provider() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

fn map_io_error(error: io::Error) -> ChannelError {
    match error.kind() {
        io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock => ChannelError::Timeout,
        _ => ChannelError::Transport,
    }
}

fn read_response(stream: &mut impl Read) -> Result<ObservationResponse, ChannelError> {
    let mut bytes = Vec::new();
    let mut buffer = [0_u8; 4096];
    let header_end = loop {
        let count = stream.read(&mut buffer).map_err(map_io_error)?;
        if count == 0 {
            return Err(ChannelError::MalformedResponse);
        }
        bytes.extend_from_slice(&buffer[..count]);
        if bytes.len() > MAX_RESPONSE_BYTES + 8192 {
            return Err(ChannelError::ResponseTooLarge);
        }
        if let Some(index) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
            break index + 4;
        }
    };
    let header =
        std::str::from_utf8(&bytes[..header_end]).map_err(|_| ChannelError::MalformedResponse)?;
    let mut lines = header.split("\r\n");
    let status = lines
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|value| value.parse::<u16>().ok())
        .ok_or(ChannelError::MalformedResponse)?;
    let content_length = lines
        .filter_map(|line| line.split_once(':'))
        .find(|(name, _)| name.eq_ignore_ascii_case("content-length"))
        .map(|(_, value)| value.trim().parse::<usize>())
        .transpose()
        .map_err(|_| ChannelError::MalformedResponse)?;
    if content_length.is_some_and(|length| length > MAX_RESPONSE_BYTES) {
        return Err(ChannelError::ResponseTooLarge);
    }
    let expected_body = content_length.unwrap_or(0);
    while bytes.len() < header_end + expected_body {
        let count = stream.read(&mut buffer).map_err(map_io_error)?;
        if count == 0 {
            return Err(ChannelError::MalformedResponse);
        }
        bytes.extend_from_slice(&buffer[..count]);
        if bytes.len() - header_end > MAX_RESPONSE_BYTES {
            return Err(ChannelError::ResponseTooLarge);
        }
    }
    let body_end = header_end + expected_body;
    let body = bytes[header_end..body_end].to_vec();
    if status >= 300 {
        return Err(ChannelError::HttpStatus(status));
    }
    Ok(ObservationResponse { status, body })
}

#[cfg(test)]
mod tests {
    use super::*;
    use rcgen::{BasicConstraints, Certificate, CertificateParams, IsCa, KeyPair};
    use std::collections::HashSet;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};
    use std::thread;
    use time::{Duration as TimeDuration, OffsetDateTime};

    struct Identity {
        cert_der: Vec<u8>,
        key_der: Vec<u8>,
        fingerprint: String,
    }

    struct Material {
        ca_cert_der: Vec<u8>,
        server: Identity,
        observer: Identity,
        wrong_scope: Identity,
        unknown_client_ca: Identity,
        unknown_server_ca: Vec<u8>,
        expired: Identity,
    }

    struct Fixture {
        address: SocketAddr,
        revoked: Arc<Mutex<HashSet<String>>>,
        join: Option<thread::JoinHandle<()>>,
    }

    #[derive(Clone)]
    enum ResponseMode {
        Normal,
        Sleep(Duration),
        Oversized,
    }

    impl Fixture {
        fn start(material: &Material, response: ResponseMode) -> Self {
            Self::start_with_connections(material, response, 1)
        }

        fn start_with_connections(
            material: &Material,
            response: ResponseMode,
            connection_count: usize,
        ) -> Self {
            assert!(
                connection_count > 0,
                "fixture needs at least one connection"
            );
            let listener = TcpListener::bind(("127.0.0.1", 0)).expect("loopback fixture bind");
            let address = listener.local_addr().expect("fixture address");
            let config = server_config(&material.ca_cert_der, &material.server);
            let allowed = Arc::new(Mutex::new(HashSet::from([material
                .observer
                .fingerprint
                .clone()])));
            let revoked = Arc::new(Mutex::new(HashSet::new()));
            let allowed_for_thread = Arc::clone(&allowed);
            let revoked_for_thread = Arc::clone(&revoked);
            let join = thread::spawn(move || {
                for _ in 0..connection_count {
                    if let Ok((stream, _)) = listener.accept() {
                        handle_connection(
                            stream,
                            Arc::clone(&config),
                            Arc::clone(&allowed_for_thread),
                            Arc::clone(&revoked_for_thread),
                            response.clone(),
                        );
                    } else {
                        break;
                    }
                }
            });
            Self {
                address,
                revoked,
                join: Some(join),
            }
        }

        fn revoke(&self, fingerprint: &str) {
            self.revoked
                .lock()
                .expect("revocation lock")
                .insert(fingerprint.to_owned());
        }

        fn join(mut self) {
            if let Some(join) = self.join.take() {
                let _ = join.join();
            }
            assert!(
                TcpListener::bind(self.address).is_ok(),
                "fixture listener remained"
            );
        }
    }

    fn server_config(ca_der: &[u8], server: &Identity) -> Arc<rustls::ServerConfig> {
        ensure_crypto_provider();
        let mut roots = RootCertStore::empty();
        roots
            .add(CertificateDer::from(ca_der.to_vec()))
            .expect("server client CA");
        let verifier = rustls::server::WebPkiClientVerifier::builder(Arc::new(roots))
            .build()
            .expect("client verifier");
        let config = rustls::ServerConfig::builder()
            .with_client_cert_verifier(verifier)
            .with_single_cert(
                vec![CertificateDer::from(server.cert_der.clone())],
                PrivatePkcs8KeyDer::from(server.key_der.clone()).into(),
            )
            .expect("server config");
        Arc::new(config)
    }

    fn handle_connection(
        stream: TcpStream,
        config: Arc<rustls::ServerConfig>,
        allowed: Arc<Mutex<HashSet<String>>>,
        revoked: Arc<Mutex<HashSet<String>>>,
        response: ResponseMode,
    ) {
        let connection = match rustls::ServerConnection::new(config) {
            Ok(connection) => connection,
            Err(_) => return,
        };
        let mut stream = StreamOwned::new(connection, stream);
        let mut request = Vec::new();
        let mut buffer = [0_u8; 2048];
        loop {
            match stream.read(&mut buffer) {
                Ok(0) | Err(_) => return,
                Ok(count) => {
                    request.extend_from_slice(&buffer[..count]);
                    if request.windows(4).any(|window| window == b"\r\n\r\n") {
                        break;
                    }
                }
            }
        }
        let request_line = String::from_utf8_lossy(&request)
            .lines()
            .next()
            .unwrap_or_default()
            .to_owned();
        let mut parts = request_line.split_whitespace();
        let method = parts.next().unwrap_or_default();
        let path = parts.next().unwrap_or_default();
        let fingerprint = stream
            .conn
            .peer_certificates()
            .and_then(|certificates| certificates.first())
            .map(|certificate| fingerprint(certificate.as_ref()));
        let authorized = fingerprint
            .as_ref()
            .is_some_and(|value| allowed.lock().expect("allowlist lock").contains(value))
            && fingerprint
                .as_ref()
                .is_some_and(|value| !revoked.lock().expect("revocation lock").contains(value));
        let (status, body) = if !authorized {
            (403, b"forbidden".to_vec())
        } else if method != "GET" {
            (405, b"read_only".to_vec())
        } else if !ObservationResource::ALL
            .iter()
            .any(|resource| resource.path() == path)
        {
            (404, b"not_found".to_vec())
        } else {
            match response {
                ResponseMode::Normal => (200, b"{\"observation\":true}".to_vec()),
                ResponseMode::Sleep(duration) => {
                    thread::sleep(duration);
                    (200, b"{\"observation\":true}".to_vec())
                }
                ResponseMode::Oversized => (200, vec![b'x'; MAX_RESPONSE_BYTES + 1]),
            }
        };
        let response = format!(
            "HTTP/1.1 {status} test\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        );
        if stream.write_all(response.as_bytes()).is_ok() {
            let _ = stream.write_all(&body);
            let _ = stream.flush();
        }
    }

    fn raw_request(
        material: &Material,
        address: SocketAddr,
        method: &str,
        path: &str,
        identity: &Identity,
    ) -> Result<u16, ChannelError> {
        let client = client(material, identity);
        let stream = TcpStream::connect_timeout(&address, client.timeout).map_err(map_io_error)?;
        stream
            .set_read_timeout(Some(client.timeout))
            .map_err(map_io_error)?;
        stream
            .set_write_timeout(Some(client.timeout))
            .map_err(map_io_error)?;
        let connection = ClientConnection::new(client.config.clone(), client.server_name.clone())
            .map_err(|_| ChannelError::TlsHandshake)?;
        let mut stream = StreamOwned::new(connection, stream);
        let request =
            format!("{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        stream.write_all(request.as_bytes()).map_err(map_io_error)?;
        stream.flush().map_err(map_io_error)?;
        let mut response = Vec::new();
        let mut buffer = [0_u8; 1024];
        while !response.windows(4).any(|window| window == b"\r\n\r\n") {
            let count = stream.read(&mut buffer).map_err(map_io_error)?;
            if count == 0 || response.len() > 8192 {
                return Err(ChannelError::MalformedResponse);
            }
            response.extend_from_slice(&buffer[..count]);
        }
        String::from_utf8_lossy(&response)
            .lines()
            .next()
            .and_then(|line| line.split_whitespace().nth(1))
            .and_then(|status| status.parse().ok())
            .ok_or(ChannelError::MalformedResponse)
    }

    fn material() -> Material {
        ensure_crypto_provider();
        let ca_key = KeyPair::generate().expect("CA key");
        let mut ca_params = CertificateParams::default();
        ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        let ca = ca_params.self_signed(&ca_key).expect("CA cert");
        let unknown_ca_key = KeyPair::generate().expect("unknown CA key");
        let unknown_ca = CertificateParams::default()
            .self_signed(&unknown_ca_key)
            .expect("unknown CA cert");
        let server = issue(&ca, &ca_key, vec!["localhost".to_owned()], None);
        let observer = issue(&ca, &ca_key, vec!["observer".to_owned()], None);
        let wrong_scope = issue(&ca, &ca_key, vec!["wrong-scope".to_owned()], None);
        let unknown_client_ca = issue(
            &unknown_ca,
            &unknown_ca_key,
            vec!["unknown".to_owned()],
            None,
        );
        let expired = issue(
            &ca,
            &ca_key,
            vec!["expired".to_owned()],
            Some((
                OffsetDateTime::now_utc() - TimeDuration::days(2),
                OffsetDateTime::now_utc() - TimeDuration::days(1),
            )),
        );
        Material {
            ca_cert_der: ca.der().to_vec(),
            server,
            observer,
            wrong_scope,
            unknown_client_ca,
            unknown_server_ca: unknown_ca.der().to_vec(),
            expired,
        }
    }

    fn issue(
        ca: &Certificate,
        ca_key: &KeyPair,
        names: Vec<String>,
        validity: Option<(OffsetDateTime, OffsetDateTime)>,
    ) -> Identity {
        let key = KeyPair::generate().expect("identity key");
        let mut params = CertificateParams::new(names).expect("identity params");
        if let Some((not_before, not_after)) = validity {
            params.not_before = not_before;
            params.not_after = not_after;
        }
        let cert = params.signed_by(&key, ca, ca_key).expect("identity cert");
        let cert_der = cert.der().to_vec();
        Identity {
            fingerprint: fingerprint(&cert_der),
            cert_der,
            key_der: key.serialize_der(),
        }
    }

    fn fingerprint(certificate_der: &[u8]) -> String {
        let digest = Sha256::digest(certificate_der);
        digest.iter().map(|byte| format!("{byte:02x}")).collect()
    }

    fn client(material: &Material, identity: &Identity) -> SecureObservationClient {
        SecureObservationClient::from_credentials(
            material.ca_cert_der.clone(),
            identity.cert_der.clone(),
            identity.key_der.clone(),
        )
        .expect("client config")
    }

    #[test]
    fn resource_surface_is_allowlisted_get_only() {
        assert_eq!(NATIVE_METHOD_POLICY, "GET_ONLY");
        assert_eq!(ObservationResource::ALL.len(), 10);
        assert!(ObservationResource::ALL
            .iter()
            .all(|resource| resource.path().starts_with('/')));
    }

    #[test]
    fn valid_server_identity_and_observer_are_accepted() {
        let material = material();
        let fixture = Fixture::start(&material, ResponseMode::Normal);
        let result = client(&material, &material.observer)
            .get(fixture.address, ObservationResource::NodeStatus);
        assert_eq!(result.expect("valid observer").status, 200);
        fixture.join();
    }

    #[test]
    fn wrong_server_hostname_is_rejected() {
        let material = material();
        let fixture = Fixture::start(&material, ResponseMode::Normal);
        let result = client(&material, &material.observer)
            .with_test_server_name("wronghost")
            .get(fixture.address, ObservationResource::NodeStatus);
        assert!(matches!(
            result,
            Err(ChannelError::TlsHandshake | ChannelError::Transport)
        ));
        fixture.join();
    }

    #[test]
    fn untrusted_server_ca_is_rejected() {
        let material = material();
        let fixture = Fixture::start(&material, ResponseMode::Normal);
        let result = SecureObservationClient::from_credentials(
            material.unknown_server_ca.clone(),
            material.observer.cert_der.clone(),
            material.observer.key_der.clone(),
        )
        .expect("client config")
        .get(fixture.address, ObservationResource::NodeStatus);
        assert!(matches!(
            result,
            Err(ChannelError::TlsHandshake | ChannelError::Transport)
        ));
        fixture.join();
    }

    #[test]
    fn missing_client_certificate_is_rejected() {
        let material = material();
        let fixture = Fixture::start(&material, ResponseMode::Normal);
        let result =
            SecureObservationClient::without_client_certificate(material.ca_cert_der.clone())
                .expect("client config")
                .get(fixture.address, ObservationResource::NodeStatus);
        assert!(matches!(
            result,
            Err(ChannelError::TlsHandshake | ChannelError::Transport)
        ));
        fixture.join();
    }

    #[test]
    fn unknown_client_ca_is_rejected() {
        let material = material();
        let fixture = Fixture::start(&material, ResponseMode::Normal);
        let result = client(&material, &material.unknown_client_ca)
            .get(fixture.address, ObservationResource::NodeStatus);
        assert!(matches!(
            result,
            Err(ChannelError::TlsHandshake | ChannelError::Transport)
        ));
        fixture.join();
    }

    #[test]
    fn expired_client_certificate_is_rejected() {
        let material = material();
        let fixture = Fixture::start(&material, ResponseMode::Normal);
        let result = client(&material, &material.expired)
            .get(fixture.address, ObservationResource::NodeStatus);
        assert!(matches!(
            result,
            Err(ChannelError::TlsHandshake | ChannelError::Transport)
        ));
        fixture.join();
    }

    #[test]
    fn trusted_wrong_scope_is_rejected() {
        let material = material();
        let fixture = Fixture::start(&material, ResponseMode::Normal);
        let result = client(&material, &material.wrong_scope)
            .get(fixture.address, ObservationResource::NodeStatus);
        assert_eq!(result, Err(ChannelError::HttpStatus(403)));
        fixture.join();
    }

    #[test]
    fn same_observer_transitions_from_allowed_to_revoked() {
        let material = material();
        let fixture = Fixture::start_with_connections(&material, ResponseMode::Normal, 2);
        let observer = client(&material, &material.observer);
        let pre_revoke = observer
            .get(fixture.address, ObservationResource::NodeStatus)
            .expect("same observer accepted before revocation");
        assert_eq!(pre_revoke.status, 200);
        fixture.revoke(&material.observer.fingerprint);
        let post_revoke = observer.get(fixture.address, ObservationResource::NodeStatus);
        assert_eq!(post_revoke, Err(ChannelError::HttpStatus(403)));
        fixture.join();
    }

    #[test]
    fn timeout_is_bounded_and_has_no_retry_tree() {
        let material = material();
        let fixture = Fixture::start(&material, ResponseMode::Sleep(Duration::from_millis(100)));
        let result = client(&material, &material.observer)
            .with_test_timeout(Duration::from_millis(20))
            .get(fixture.address, ObservationResource::NodeStatus);
        assert_eq!(result, Err(ChannelError::Timeout));
        assert_eq!(NATIVE_MAX_ATTEMPTS, 1);
        fixture.join();
    }

    #[test]
    fn oversized_response_is_rejected_incrementally() {
        let material = material();
        let fixture = Fixture::start(&material, ResponseMode::Oversized);
        let result = client(&material, &material.observer)
            .get(fixture.address, ObservationResource::NodeStatus);
        assert_eq!(result, Err(ChannelError::ResponseTooLarge));
        fixture.join();
    }

    #[test]
    fn unknown_get_and_mutating_methods_are_rejected() {
        for (method, expected) in [
            ("GET", 404),
            ("POST", 405),
            ("PUT", 405),
            ("PATCH", 405),
            ("DELETE", 405),
        ] {
            let material = material();
            let fixture = Fixture::start(&material, ResponseMode::Normal);
            let path = if method == "GET" {
                "/not-allowlisted"
            } else {
                "/api/v1/node/status"
            };
            assert_eq!(
                raw_request(&material, fixture.address, method, path, &material.observer)
                    .expect("method response"),
                expected
            );
            fixture.join();
        }
    }

    #[test]
    fn non_success_status_does_not_create_a_retry_loop() {
        let material = material();
        let fixture = Fixture::start(&material, ResponseMode::Normal);
        assert_eq!(
            raw_request(
                &material,
                fixture.address,
                "GET",
                "/not-allowlisted",
                &material.observer
            )
            .expect("404 response"),
            404
        );
        assert_eq!(NATIVE_MAX_ATTEMPTS, 1);
        fixture.join();
    }

    #[test]
    fn errors_are_sanitized_without_identity_material() {
        let material = material();
        let fixture = Fixture::start(&material, ResponseMode::Normal);
        let error = client(&material, &material.observer)
            .with_test_server_name("wronghost")
            .get(fixture.address, ObservationResource::NodeStatus)
            .expect_err("wrong identity");
        let formatted = format!("{error:?} {error}");
        let begin_marker = "-----BEGIN ";
        let key_marker = "PRIVATE KEY-----";
        let private_marker = [begin_marker, key_marker].concat();
        let certificate_marker = [begin_marker, "CERTIFICATE-----"].concat();
        assert!(!formatted.contains(private_marker.as_str()));
        assert!(!formatted.contains(certificate_marker.as_str()));
        fixture.join();
    }

    #[test]
    fn all_resource_paths_are_exactly_the_existing_read_only_contract() {
        let expected = [
            "/api/v1/node/status",
            "/api/v1/node/identity",
            "/api/v1/node/capabilities",
            "/api/v1/node/services",
            "/api/v1/node/connection",
            "/api/v1/node/metadata",
            "/api/v1/health/current",
            "/api/v1/health/history",
            "/api/v1/events",
            "/metrics",
        ];
        assert_eq!(
            ObservationResource::ALL.map(ObservationResource::path),
            expected
        );
    }
}
