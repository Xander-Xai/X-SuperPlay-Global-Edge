//! Deterministic runtime-supervisor skeleton over a fake core.
//!
//! The supervisor owns the lifecycle policy: readiness deadline, crash
//! detection, bounded restarts, cooldown, and clean stop. It drives a
//! [`CoreHandle`], which is an in-process fake in this milestone. No process is
//! spawned and no real time is read; callers pass a monotonic [`Duration`].

use std::collections::VecDeque;
use std::time::Duration;

use thiserror::Error;

use crate::contract::TransportState;
use crate::state::{StateMachine, TransitionError};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CoreEvent {
    Ready,
    Exited { code: i32 },
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum CoreError {
    #[error("core failed to start: {0}")]
    StartFailed(String),
}

pub trait CoreHandle {
    fn start(&mut self, profile: &str) -> Result<(), CoreError>;
    fn stop(&mut self);
    fn poll(&mut self) -> Option<CoreEvent>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RestartPolicy {
    pub max_restarts: u32,
    pub restart_window: Duration,
    pub cooldown: Duration,
    pub readiness_deadline: Duration,
}

impl Default for RestartPolicy {
    fn default() -> Self {
        Self {
            max_restarts: 3,
            restart_window: Duration::from_secs(60),
            cooldown: Duration::from_secs(5),
            readiness_deadline: Duration::from_secs(10),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SupervisorEvent {
    Ready,
    Exited { code: i32 },
    ReadinessTimeout,
    Restarted,
    RestartFailed,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum SupervisorError {
    #[error("supervisor is already running")]
    AlreadyRunning,
    #[error("invalid supervisor state transition")]
    InvalidTransition,
    #[error("core failed to start: {0}")]
    StartFailed(String),
}

pub struct Supervisor<C: CoreHandle> {
    core: C,
    state: StateMachine,
    policy: RestartPolicy,
    active_profile: Option<String>,
    started_at: Option<Duration>,
    cooldown_until: Option<Duration>,
    restarts: VecDeque<Duration>,
    last_error: Option<String>,
}

impl<C: CoreHandle> Supervisor<C> {
    pub fn new(core: C, policy: RestartPolicy) -> Self {
        Self {
            core,
            state: StateMachine::new("t+0s"),
            policy,
            active_profile: None,
            started_at: None,
            cooldown_until: None,
            restarts: VecDeque::new(),
            last_error: None,
        }
    }

    pub fn state(&self) -> TransportState {
        self.state.state()
    }

    pub fn active_profile(&self) -> Option<&str> {
        self.active_profile.as_deref()
    }

    pub fn last_error(&self) -> Option<&str> {
        self.last_error.as_deref()
    }

    pub fn start(&mut self, profile: &str, now: Duration) -> Result<(), SupervisorError> {
        if matches!(
            self.state.state(),
            TransportState::Starting
                | TransportState::Ready
                | TransportState::Degraded
                | TransportState::Cooldown
        ) {
            return Err(SupervisorError::AlreadyRunning);
        }
        self.transition(TransportState::Starting, now)?;
        self.active_profile = Some(profile.to_string());
        self.started_at = Some(now);
        match self.core.start(profile) {
            Ok(()) => Ok(()),
            Err(error) => {
                self.last_error = Some(error.to_string());
                self.handle_failure(now);
                Err(SupervisorError::StartFailed(error.to_string()))
            }
        }
    }

    pub fn tick(&mut self, now: Duration) -> Option<SupervisorEvent> {
        match self.state.state() {
            TransportState::Starting => self.tick_starting(now),
            TransportState::Ready | TransportState::Degraded => self.tick_running(now),
            TransportState::Cooldown => self.tick_cooldown(now),
            _ => None,
        }
    }

    pub fn stop(&mut self, now: Duration) -> Result<(), SupervisorError> {
        self.core.stop();
        self.active_profile = None;
        self.started_at = None;
        self.cooldown_until = None;
        self.transition(TransportState::Stopped, now)
    }

    fn tick_starting(&mut self, now: Duration) -> Option<SupervisorEvent> {
        if let Some(event) = self.core.poll() {
            return match event {
                CoreEvent::Ready => {
                    self.started_at = None;
                    self.transition(TransportState::Ready, now).ok()?;
                    Some(SupervisorEvent::Ready)
                }
                CoreEvent::Exited { code } => {
                    self.last_error = Some(format!("core exited before ready with code {code}"));
                    self.handle_failure(now);
                    Some(SupervisorEvent::Exited { code })
                }
            };
        }
        let deadline_exceeded = self
            .started_at
            .map(|started| now.saturating_sub(started) > self.policy.readiness_deadline)
            .unwrap_or(false);
        if deadline_exceeded {
            self.core.stop();
            self.started_at = None;
            self.last_error = Some("readiness deadline exceeded".to_string());
            self.handle_failure(now);
            return Some(SupervisorEvent::ReadinessTimeout);
        }
        None
    }

    fn tick_running(&mut self, now: Duration) -> Option<SupervisorEvent> {
        match self.core.poll()? {
            CoreEvent::Exited { code } => {
                self.last_error = Some(format!("core exited with code {code}"));
                self.handle_failure(now);
                Some(SupervisorEvent::Exited { code })
            }
            CoreEvent::Ready => None,
        }
    }

    fn tick_cooldown(&mut self, now: Duration) -> Option<SupervisorEvent> {
        if !self
            .cooldown_until
            .map(|until| now >= until)
            .unwrap_or(false)
        {
            return None;
        }
        let profile = self.active_profile.clone().unwrap_or_default();
        self.cooldown_until = None;
        if self.transition(TransportState::Starting, now).is_err() {
            return None;
        }
        self.started_at = Some(now);
        match self.core.start(&profile) {
            Ok(()) => Some(SupervisorEvent::Restarted),
            Err(error) => {
                self.last_error = Some(error.to_string());
                self.handle_failure(now);
                Some(SupervisorEvent::RestartFailed)
            }
        }
    }

    fn handle_failure(&mut self, now: Duration) {
        if self.transition(TransportState::Failed, now).is_err() {
            return;
        }
        while let Some(oldest) = self.restarts.front() {
            if now.saturating_sub(*oldest) > self.policy.restart_window {
                self.restarts.pop_front();
            } else {
                break;
            }
        }
        self.restarts.push_back(now);
        if self.restarts.len() as u32 > self.policy.max_restarts {
            self.cooldown_until = None;
            return;
        }
        if self.transition(TransportState::Cooldown, now).is_ok() {
            self.cooldown_until = Some(now + self.policy.cooldown);
        }
    }

    fn transition(&mut self, to: TransportState, now: Duration) -> Result<(), SupervisorError> {
        self.state
            .transition(to, format!("t+{now:?}"))
            .map_err(|_: TransitionError| SupervisorError::InvalidTransition)
    }
}

#[derive(Debug)]
pub struct FakeCore {
    events: VecDeque<CoreEvent>,
    start_failure: Option<String>,
    running: bool,
    starts: u32,
    stops: u32,
}

impl FakeCore {
    pub fn new(events: impl IntoIterator<Item = CoreEvent>) -> Self {
        Self {
            events: events.into_iter().collect(),
            start_failure: None,
            running: false,
            starts: 0,
            stops: 0,
        }
    }

    pub fn failing_start(message: impl Into<String>) -> Self {
        Self {
            events: VecDeque::new(),
            start_failure: Some(message.into()),
            running: false,
            starts: 0,
            stops: 0,
        }
    }

    pub fn push_event(&mut self, event: CoreEvent) {
        self.events.push_back(event);
    }

    pub fn starts(&self) -> u32 {
        self.starts
    }

    pub fn stops(&self) -> u32 {
        self.stops
    }
}

impl CoreHandle for FakeCore {
    fn start(&mut self, _profile: &str) -> Result<(), CoreError> {
        self.starts += 1;
        if let Some(message) = &self.start_failure {
            return Err(CoreError::StartFailed(message.clone()));
        }
        self.running = true;
        Ok(())
    }

    fn stop(&mut self) {
        if self.running {
            self.stops += 1;
        }
        self.running = false;
    }

    fn poll(&mut self) -> Option<CoreEvent> {
        if !self.running {
            return None;
        }
        let event = self.events.pop_front();
        if matches!(event, Some(CoreEvent::Exited { .. })) {
            self.running = false;
        }
        event
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn policy(max_restarts: u32) -> RestartPolicy {
        RestartPolicy {
            max_restarts,
            restart_window: Duration::from_secs(60),
            cooldown: Duration::from_secs(5),
            readiness_deadline: Duration::from_secs(10),
        }
    }

    fn secs(value: u64) -> Duration {
        Duration::from_secs(value)
    }

    #[test]
    fn reaches_ready_after_the_core_reports_ready() {
        let core = FakeCore::new([CoreEvent::Ready]);
        let mut supervisor = Supervisor::new(core, policy(2));
        supervisor.start("reality", secs(0)).unwrap();
        assert_eq!(supervisor.tick(secs(1)), Some(SupervisorEvent::Ready));
        assert_eq!(supervisor.state(), TransportState::Ready);
    }

    #[test]
    fn readiness_timeout_schedules_a_cooldown() {
        let core = FakeCore::new([]);
        let mut supervisor = Supervisor::new(core, policy(1));
        supervisor.start("reality", secs(0)).unwrap();
        assert_eq!(
            supervisor.tick(secs(11)),
            Some(SupervisorEvent::ReadinessTimeout)
        );
        assert_eq!(supervisor.state(), TransportState::Cooldown);
        assert_eq!(supervisor.last_error(), Some("readiness deadline exceeded"));
    }

    #[test]
    fn readiness_timeout_without_budget_fails() {
        let core = FakeCore::new([]);
        let mut supervisor = Supervisor::new(core, policy(0));
        supervisor.start("reality", secs(0)).unwrap();
        assert_eq!(
            supervisor.tick(secs(11)),
            Some(SupervisorEvent::ReadinessTimeout)
        );
        assert_eq!(supervisor.state(), TransportState::Failed);
    }

    #[test]
    fn crash_restarts_after_cooldown() {
        let core = FakeCore::new([
            CoreEvent::Ready,
            CoreEvent::Exited { code: 1 },
            CoreEvent::Ready,
        ]);
        let mut supervisor = Supervisor::new(core, policy(2));
        supervisor.start("reality", secs(0)).unwrap();
        assert_eq!(supervisor.tick(secs(1)), Some(SupervisorEvent::Ready));
        assert_eq!(
            supervisor.tick(secs(2)),
            Some(SupervisorEvent::Exited { code: 1 })
        );
        assert_eq!(supervisor.state(), TransportState::Cooldown);
        assert_eq!(supervisor.tick(secs(4)), None);
        assert_eq!(supervisor.tick(secs(7)), Some(SupervisorEvent::Restarted));
        assert_eq!(supervisor.tick(secs(8)), Some(SupervisorEvent::Ready));
    }

    #[test]
    fn restart_budget_is_bounded() {
        let core = FakeCore::new([CoreEvent::Ready, CoreEvent::Exited { code: 1 }]);
        let mut supervisor = Supervisor::new(core, policy(0));
        supervisor.start("reality", secs(0)).unwrap();
        assert_eq!(supervisor.tick(secs(1)), Some(SupervisorEvent::Ready));
        assert_eq!(
            supervisor.tick(secs(2)),
            Some(SupervisorEvent::Exited { code: 1 })
        );
        assert_eq!(supervisor.state(), TransportState::Failed);
    }

    #[test]
    fn stop_is_clean() {
        let core = FakeCore::new([CoreEvent::Ready]);
        let mut supervisor = Supervisor::new(core, policy(2));
        supervisor.start("reality", secs(0)).unwrap();
        assert_eq!(supervisor.tick(secs(1)), Some(SupervisorEvent::Ready));
        supervisor.stop(secs(2)).unwrap();
        assert_eq!(supervisor.state(), TransportState::Stopped);
    }

    #[test]
    fn start_failure_is_reported() {
        let core = FakeCore::failing_start("binary missing");
        let mut supervisor = Supervisor::new(core, policy(0));
        let result = supervisor.start("reality", secs(0));
        assert!(matches!(result, Err(SupervisorError::StartFailed(_))));
        assert_eq!(supervisor.state(), TransportState::Failed);
    }

    #[test]
    fn start_while_running_is_rejected() {
        let core = FakeCore::new([CoreEvent::Ready]);
        let mut supervisor = Supervisor::new(core, policy(2));
        supervisor.start("reality", secs(0)).unwrap();
        assert_eq!(supervisor.tick(secs(1)), Some(SupervisorEvent::Ready));
        assert_eq!(
            supervisor.start("reality", secs(2)),
            Err(SupervisorError::AlreadyRunning)
        );
    }
}
