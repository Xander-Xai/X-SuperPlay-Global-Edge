# Optional self-hosted runner guidance

The public repository's ordinary validation runs on disposable GitHub-hosted
`ubuntu-latest` and `windows-latest` runners. A self-hosted runner is optional
and reserved for a separately reviewed private experiment that needs special
hardware; it is not required by public pull requests and is never a
production deployment target.

## Generic identity contract

Use repository-scoped values supplied at registration time:

```text
REPOSITORY_NAME=<REPOSITORY_NAME>
RUNNER_NAME=<RUNNER_NAME>
RUNNER_INSTALL_DIR=<RUNNER_INSTALL_DIR>
RUNNER_SERVICE=<RUNNER_SERVICE>
RUNNER_LABELS=self-hosted,<SPECIALIZED_LABELS>
```

Do not publish a real host name, service account, installation path, runner
token, SSH alias, or relationship to a production machine.

## Isolation requirements

- Use a dedicated installation directory, service unit, workspace, and (where
  practical) service account.
- Keep the runner separate from production infrastructure and credentials.
- Before registration, verify that the host has no production Compose project,
  WireGuard volume, or live service listeners.
- Any private experiment uses tracked templates, synthetic fixtures, and
  ephemeral state only.
- Serialize Docker lifecycle jobs that share the runner's local daemon.

## Dependencies and recovery

If a private experiment is approved, it needs Git, Bash, Python 3, PyYAML,
ShellCheck, PowerShell Core, Docker Compose v2, curl, and standard test
tooling. Never make the Docker socket world-writable. Keep registration
tokens, PATs, SSH keys, and runtime configuration outside the workspace.
Re-registration uses a short-lived operator-approved token and removes only
the intended repository runner.
