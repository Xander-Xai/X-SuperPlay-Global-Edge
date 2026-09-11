# Open-source readiness gate

The repository is maintained as a normal public software project. Readiness
is evaluated from the tracked tree and hosted CI, not from private runtime
state.

Required signals are:

- source package completeness and imports pass;
- secret and infrastructure privacy scans report zero findings;
- license and third-party provenance are present;
- shell, Python, frontend, Rust, Compose, and hosted desktop checks pass.

Run `bash scripts/open-source-readiness.sh` and `bash scripts/secret-scan.sh`
before publishing a change. A release candidate still requires an explicit
version audit and a human review; this gate does not create tags or releases.
