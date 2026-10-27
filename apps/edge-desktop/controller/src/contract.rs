//! Wire contract shared with the desktop client.

use serde::{Deserialize, Serialize};

pub const CONTRACT_VERSION: &str = "1";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TransportState {
    Disabled,
    Starting,
    Ready,
    Degraded,
    Failed,
    Cooldown,
    Stopped,
}

impl TransportState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::Starting => "starting",
            Self::Ready => "ready",
            Self::Degraded => "degraded",
            Self::Failed => "failed",
            Self::Cooldown => "cooldown",
            Self::Stopped => "stopped",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    Unauthorized,
    InvalidRequest,
    NotFound,
    Conflict,
    Busy,
    Unsupported,
    Timeout,
    Internal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCategory {
    Auth,
    Request,
    Conflict,
    Timeout,
    Internal,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorBody {
    pub code: ErrorCode,
    pub category: ErrorCategory,
    pub retryable: bool,
    pub message: String,
}

impl ErrorBody {
    pub fn new(
        code: ErrorCode,
        category: ErrorCategory,
        retryable: bool,
        message: impl Into<String>,
    ) -> Self {
        Self {
            code,
            category,
            retryable,
            message: message.into(),
        }
    }

    pub fn unauthorized() -> Self {
        Self::new(
            ErrorCode::Unauthorized,
            ErrorCategory::Auth,
            false,
            "unauthorized",
        )
    }

    pub fn invalid_request(message: impl Into<String>) -> Self {
        Self::new(
            ErrorCode::InvalidRequest,
            ErrorCategory::Request,
            false,
            message,
        )
    }

    pub fn not_found(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::NotFound, ErrorCategory::Request, false, message)
    }

    pub fn conflict(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::Conflict, ErrorCategory::Conflict, false, message)
    }

    pub fn busy() -> Self {
        Self::new(
            ErrorCode::Busy,
            ErrorCategory::Conflict,
            true,
            "another transition is running",
        )
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::Internal, ErrorCategory::Internal, false, message)
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ConnectRequest {
    pub profile_id: String,
    pub operation_id: String,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(tag = "operation", rename_all = "snake_case")]
pub enum Request {
    Status,
    Connect(ConnectRequest),
    Disconnect,
    Transports,
    Diagnostics,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StatusResponse {
    pub controller_version: String,
    pub state: TransportState,
    pub active_transport: Option<String>,
    pub since: String,
    pub last_error_category: Option<ErrorCategory>,
    pub evidence_ref: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnectResponse {
    pub state: TransportState,
    pub operation_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DisconnectResponse {
    pub state: TransportState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TransportInfo {
    pub name: String,
    pub protocol: String,
    pub state: TransportState,
    pub version: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TransportsResponse {
    pub transports: Vec<TransportInfo>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiagnosticsResponse {
    pub requests: u64,
    pub state_transitions: u64,
    pub last_error_category: Option<ErrorCategory>,
    pub recent: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(untagged)]
pub enum ResponseBody {
    Status(StatusResponse),
    Connect(ConnectResponse),
    Disconnect(DisconnectResponse),
    Transports(TransportsResponse),
    Diagnostics(DiagnosticsResponse),
    Error(ErrorBody),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Response {
    pub contract_version: &'static str,
    #[serde(flatten)]
    pub body: ResponseBody,
}

impl Response {
    pub fn new(body: ResponseBody) -> Self {
        Self {
            contract_version: CONTRACT_VERSION,
            body,
        }
    }
}
