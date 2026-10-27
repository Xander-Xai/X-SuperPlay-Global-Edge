//! Transport state machine shared by the controller and its tests.

use crate::contract::TransportState;
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum TransitionError {
    #[error("invalid transition from {from:?} to {to:?}")]
    Invalid {
        from: TransportState,
        to: TransportState,
    },
}

#[derive(Debug, Clone)]
pub struct StateMachine {
    state: TransportState,
    since: String,
}

impl StateMachine {
    pub fn new(since: impl Into<String>) -> Self {
        Self {
            state: TransportState::Disabled,
            since: since.into(),
        }
    }

    pub fn state(&self) -> TransportState {
        self.state
    }

    pub fn since(&self) -> &str {
        &self.since
    }

    pub fn transition(
        &mut self,
        to: TransportState,
        now: impl Into<String>,
    ) -> Result<(), TransitionError> {
        if to == self.state {
            return Ok(());
        }
        if !allowed(self.state, to) {
            return Err(TransitionError::Invalid {
                from: self.state,
                to,
            });
        }
        self.state = to;
        self.since = now.into();
        Ok(())
    }
}

fn allowed(from: TransportState, to: TransportState) -> bool {
    use TransportState::{Cooldown, Degraded, Disabled, Failed, Ready, Starting, Stopped};
    matches!(
        (from, to),
        (Disabled, Starting)
            | (Disabled, Stopped)
            | (Starting, Ready)
            | (Starting, Failed)
            | (Starting, Stopped)
            | (Ready, Degraded)
            | (Ready, Failed)
            | (Ready, Stopped)
            | (Degraded, Ready)
            | (Degraded, Failed)
            | (Degraded, Stopped)
            | (Failed, Cooldown)
            | (Failed, Starting)
            | (Failed, Stopped)
            | (Cooldown, Starting)
            | (Cooldown, Stopped)
            | (Stopped, Starting)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn machine() -> StateMachine {
        StateMachine::new("2026-10-27T00:00:00Z")
    }

    #[test]
    fn starts_disabled() {
        assert_eq!(machine().state(), TransportState::Disabled);
    }

    #[test]
    fn allows_the_normal_connect_and_disconnect_path() {
        let mut machine = machine();
        machine
            .transition(TransportState::Starting, "2026-10-27T00:00:01Z")
            .unwrap();
        machine
            .transition(TransportState::Ready, "2026-10-27T00:00:02Z")
            .unwrap();
        assert_eq!(machine.state(), TransportState::Ready);
        assert_eq!(machine.since(), "2026-10-27T00:00:02Z");
        machine
            .transition(TransportState::Stopped, "2026-10-27T00:00:03Z")
            .unwrap();
        assert_eq!(machine.state(), TransportState::Stopped);
    }

    #[test]
    fn rejects_invalid_transitions() {
        let mut machine = machine();
        assert!(machine
            .transition(TransportState::Ready, "2026-10-27T00:00:01Z")
            .is_err());
        assert_eq!(machine.state(), TransportState::Disabled);
    }

    #[test]
    fn treats_a_repeated_state_as_idempotent() {
        let mut machine = machine();
        machine
            .transition(TransportState::Starting, "2026-10-27T00:00:01Z")
            .unwrap();
        machine
            .transition(TransportState::Starting, "2026-10-27T00:00:02Z")
            .unwrap();
        assert_eq!(machine.since(), "2026-10-27T00:00:01Z");
    }
}
