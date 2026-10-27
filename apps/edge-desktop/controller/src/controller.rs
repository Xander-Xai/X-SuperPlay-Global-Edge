//! In-process controller skeleton backed by a fake core.

use std::collections::{HashMap, HashSet, VecDeque};

use crate::authentication::Authenticator;
use crate::contract::{
    ConnectRequest, ConnectResponse, DiagnosticsResponse, DisconnectResponse, ErrorBody,
    ErrorCategory, Request, Response, ResponseBody, StatusResponse, TransportInfo, TransportState,
    TransportsResponse,
};
use crate::state::{StateMachine, TransitionError};
use crate::time::iso8601_now;

const RECENT_LIMIT: usize = 20;

pub struct Controller {
    authenticator: Authenticator,
    state: StateMachine,
    active_transport: Option<String>,
    pending_profile: Option<String>,
    profiles: HashSet<String>,
    operations: HashMap<String, ConnectResponse>,
    requests: u64,
    transitions: u64,
    last_error_category: Option<ErrorCategory>,
    recent: VecDeque<String>,
    fake_ready: bool,
}

impl Controller {
    pub fn new(authenticator: Authenticator, profiles: impl IntoIterator<Item = String>) -> Self {
        Self::with_fake_core(authenticator, profiles, true)
    }

    /// `fake_ready = false` leaves a connect attempt in `starting` until
    /// [`Controller::mark_ready`] is called. This exists to exercise the busy
    /// and readiness paths without a real core.
    pub fn with_fake_core(
        authenticator: Authenticator,
        profiles: impl IntoIterator<Item = String>,
        fake_ready: bool,
    ) -> Self {
        Self {
            authenticator,
            state: StateMachine::new(iso8601_now()),
            active_transport: None,
            pending_profile: None,
            profiles: profiles.into_iter().collect(),
            operations: HashMap::new(),
            requests: 0,
            transitions: 0,
            last_error_category: None,
            recent: VecDeque::new(),
            fake_ready,
        }
    }

    pub fn handle(&mut self, request: Request, credential: Option<&str>) -> Response {
        self.requests += 1;
        if let Err(error) = self.authenticator.authenticate(credential) {
            return self.error(error.to_error_body());
        }
        match request {
            Request::Status => Response::new(ResponseBody::Status(self.status())),
            Request::Connect(request) => self.connect(request),
            Request::Disconnect => self.disconnect(),
            Request::Transports => Response::new(ResponseBody::Transports(self.transports())),
            Request::Diagnostics => Response::new(ResponseBody::Diagnostics(self.diagnostics())),
        }
    }

    /// Completes a pending connect attempt once the fake core reports ready.
    pub fn mark_ready(&mut self) -> Result<(), TransitionError> {
        self.transition(TransportState::Ready)?;
        self.active_transport = self.pending_profile.take();
        Ok(())
    }

    fn status(&self) -> StatusResponse {
        StatusResponse {
            controller_version: env!("CARGO_PKG_VERSION").to_string(),
            state: self.state.state(),
            active_transport: self.active_transport.clone(),
            since: self.state.since().to_string(),
            last_error_category: self.last_error_category,
            evidence_ref: None,
        }
    }

    fn connect(&mut self, request: ConnectRequest) -> Response {
        if let Some(cached) = self.operations.get(&request.operation_id) {
            return Response::new(ResponseBody::Connect(cached.clone()));
        }
        if !self.profiles.contains(&request.profile_id) {
            return self.error(ErrorBody::not_found("unknown profile"));
        }
        match self.state.state() {
            TransportState::Starting => return self.error(ErrorBody::busy()),
            TransportState::Ready | TransportState::Degraded => {
                return self.error(ErrorBody::conflict("already connected"))
            }
            _ => {}
        }
        if self.transition(TransportState::Starting).is_err() {
            return self.error(ErrorBody::internal("invalid state transition"));
        }
        self.pending_profile = Some(request.profile_id.clone());
        if self.fake_ready && self.mark_ready().is_err() {
            return self.error(ErrorBody::internal("invalid state transition"));
        }
        let response = ConnectResponse {
            state: self.state.state(),
            operation_id: request.operation_id.clone(),
        };
        self.operations
            .insert(request.operation_id, response.clone());
        Response::new(ResponseBody::Connect(response))
    }

    fn disconnect(&mut self) -> Response {
        if self.state.state() != TransportState::Stopped
            && self.transition(TransportState::Stopped).is_err()
        {
            return self.error(ErrorBody::internal("invalid state transition"));
        }
        self.active_transport = None;
        self.pending_profile = None;
        self.operations.clear();
        Response::new(ResponseBody::Disconnect(DisconnectResponse {
            state: TransportState::Stopped,
        }))
    }

    fn transports(&self) -> TransportsResponse {
        let active = self.active_transport.as_deref();
        let ready = self.state.state() == TransportState::Ready;
        let transport = |name: &str, protocol: &str| TransportInfo {
            name: name.to_string(),
            protocol: protocol.to_string(),
            state: if ready && active == Some(name) {
                TransportState::Ready
            } else {
                TransportState::Disabled
            },
            version: "unmanaged".to_string(),
        };
        TransportsResponse {
            transports: vec![
                transport("reality", "vless"),
                transport("hysteria2", "hysteria2"),
                transport("wireguard", "wireguard"),
            ],
        }
    }

    fn diagnostics(&self) -> DiagnosticsResponse {
        DiagnosticsResponse {
            requests: self.requests,
            state_transitions: self.transitions,
            last_error_category: self.last_error_category,
            recent: self.recent.iter().cloned().collect(),
        }
    }

    fn transition(&mut self, to: TransportState) -> Result<(), TransitionError> {
        let now = iso8601_now();
        self.state.transition(to, now.clone())?;
        self.transitions += 1;
        self.recent.push_back(format!("{now}:{}", to.as_str()));
        while self.recent.len() > RECENT_LIMIT {
            self.recent.pop_front();
        }
        Ok(())
    }

    fn error(&mut self, body: ErrorBody) -> Response {
        self.last_error_category = Some(body.category);
        Response::new(ResponseBody::Error(body))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::authentication::AuthCredential;
    use crate::contract::{ErrorCode, CONTRACT_VERSION};

    fn credential() -> String {
        "ab".repeat(32)
    }

    fn controller(fake_ready: bool) -> Controller {
        Controller::with_fake_core(
            Authenticator::new(AuthCredential::from_hex(credential())),
            ["reality".to_string(), "hysteria2".to_string()],
            fake_ready,
        )
    }

    fn connect(profile: &str, operation: &str) -> Request {
        Request::Connect(ConnectRequest {
            profile_id: profile.to_string(),
            operation_id: operation.to_string(),
        })
    }

    fn error_body(response: &Response) -> &ErrorBody {
        match &response.body {
            ResponseBody::Error(body) => body,
            other => panic!("expected an error response, got {other:?}"),
        }
    }

    fn connect_state(response: &Response) -> TransportState {
        match &response.body {
            ResponseBody::Connect(body) => body.state,
            other => panic!("expected a connect response, got {other:?}"),
        }
    }

    #[test]
    fn rejects_unauthorized_requests_without_changing_state() {
        let mut controller = controller(true);
        let response = controller.handle(Request::Status, Some("wrong"));
        assert_eq!(error_body(&response).code, ErrorCode::Unauthorized);
        let status = controller.handle(Request::Status, Some(&credential()));
        match status.body {
            ResponseBody::Status(body) => assert_eq!(body.state, TransportState::Disabled),
            other => panic!("expected status, got {other:?}"),
        }
    }

    #[test]
    fn status_is_available_from_the_start() {
        let mut controller = controller(true);
        let response = controller.handle(Request::Status, Some(&credential()));
        assert_eq!(response.contract_version, CONTRACT_VERSION);
        match response.body {
            ResponseBody::Status(body) => {
                assert_eq!(body.state, TransportState::Disabled);
                assert_eq!(body.active_transport, None);
                assert_eq!(body.controller_version, env!("CARGO_PKG_VERSION"));
            }
            other => panic!("expected status, got {other:?}"),
        }
    }

    #[test]
    fn connect_reaches_ready_and_is_idempotent() {
        let mut controller = controller(true);
        let first = controller.handle(connect("reality", "op-1"), Some(&credential()));
        assert_eq!(connect_state(&first), TransportState::Ready);

        let second = controller.handle(connect("reality", "op-1"), Some(&credential()));
        assert_eq!(first, second);

        let diagnostics = controller.handle(Request::Diagnostics, Some(&credential()));
        match diagnostics.body {
            ResponseBody::Diagnostics(body) => assert_eq!(body.state_transitions, 2),
            other => panic!("expected diagnostics, got {other:?}"),
        }
    }

    #[test]
    fn connect_rejects_unknown_profiles() {
        let mut controller = controller(true);
        let response = controller.handle(connect("missing", "op-1"), Some(&credential()));
        assert_eq!(error_body(&response).code, ErrorCode::NotFound);
    }

    #[test]
    fn connect_is_busy_until_the_core_reports_ready() {
        let mut controller = controller(false);
        let first = controller.handle(connect("reality", "op-1"), Some(&credential()));
        assert_eq!(connect_state(&first), TransportState::Starting);

        let second = controller.handle(connect("reality", "op-2"), Some(&credential()));
        assert_eq!(error_body(&second).code, ErrorCode::Busy);

        controller.mark_ready().unwrap();
        let status = controller.handle(Request::Status, Some(&credential()));
        match status.body {
            ResponseBody::Status(body) => {
                assert_eq!(body.state, TransportState::Ready);
                assert_eq!(body.active_transport.as_deref(), Some("reality"));
            }
            other => panic!("expected status, got {other:?}"),
        }
    }

    #[test]
    fn connect_conflicts_when_already_connected() {
        let mut controller = controller(true);
        controller.handle(connect("reality", "op-1"), Some(&credential()));
        let response = controller.handle(connect("hysteria2", "op-2"), Some(&credential()));
        assert_eq!(error_body(&response).code, ErrorCode::Conflict);
    }

    #[test]
    fn disconnect_is_idempotent_and_clears_the_active_transport() {
        let mut controller = controller(true);
        controller.handle(connect("reality", "op-1"), Some(&credential()));

        for _ in 0..2 {
            let response = controller.handle(Request::Disconnect, Some(&credential()));
            match response.body {
                ResponseBody::Disconnect(body) => {
                    assert_eq!(body.state, TransportState::Stopped)
                }
                other => panic!("expected disconnect, got {other:?}"),
            }
        }

        let status = controller.handle(Request::Status, Some(&credential()));
        match status.body {
            ResponseBody::Status(body) => {
                assert_eq!(body.state, TransportState::Stopped);
                assert_eq!(body.active_transport, None);
            }
            other => panic!("expected status, got {other:?}"),
        }
    }

    #[test]
    fn transports_reflect_the_active_transport_only() {
        let mut controller = controller(true);
        controller.handle(connect("reality", "op-1"), Some(&credential()));
        let response = controller.handle(Request::Transports, Some(&credential()));
        match response.body {
            ResponseBody::Transports(body) => {
                let reality = body
                    .transports
                    .iter()
                    .find(|transport| transport.name == "reality")
                    .unwrap();
                let hysteria = body
                    .transports
                    .iter()
                    .find(|transport| transport.name == "hysteria2")
                    .unwrap();
                assert_eq!(reality.state, TransportState::Ready);
                assert_eq!(hysteria.state, TransportState::Disabled);
            }
            other => panic!("expected transports, got {other:?}"),
        }
    }

    #[test]
    fn diagnostics_do_not_contain_the_credential() {
        let mut controller = controller(true);
        controller.handle(connect("reality", "op-1"), Some(&credential()));
        let response = controller.handle(Request::Diagnostics, Some(&credential()));
        let serialized = serde_json::to_string(&response).unwrap();
        assert!(!serialized.contains(&credential()));
        assert!(!serialized.contains("profile_id"));
    }

    #[test]
    fn rejects_unknown_operations_and_unexpected_fields() {
        assert!(serde_json::from_str::<Request>(r#"{"operation":"unknown"}"#).is_err());
        assert!(serde_json::from_str::<Request>(
            r#"{"operation":"connect","profile_id":"reality","operation_id":"op-1","extra":true}"#
        )
        .is_err());
    }
}
