//! Local controller contract skeleton for milestone 0.2.
//!
//! This crate implements the contract types, authentication, state machine,
//! idempotency, and diagnostics over an in-process fake core. It does not
//! start a network listener, spawn a process, or touch host network state.

pub mod authentication;
pub mod contract;
pub mod controller;
pub mod state;
pub mod supervisor;
pub mod time;

pub use authentication::{AuthCredential, Authenticator};
pub use contract::{
    ConnectRequest, ConnectResponse, DiagnosticsResponse, DisconnectResponse, ErrorBody,
    ErrorCategory, ErrorCode, Request, Response, ResponseBody, StatusResponse, TransportInfo,
    TransportState, TransportsResponse, CONTRACT_VERSION,
};
pub use controller::Controller;
pub use state::{StateMachine, TransitionError};
pub use supervisor::{
    CoreError, CoreEvent, CoreHandle, FakeCore, RestartPolicy, Supervisor, SupervisorError,
    SupervisorEvent,
};
