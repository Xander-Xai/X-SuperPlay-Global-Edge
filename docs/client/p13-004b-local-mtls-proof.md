# P13-004B Local mTLS Observation Channel Proof

Status: local, non-production security proof only.

## Scope and identity

- Branch: `p13-004b-local-mtls-proof`
- Design base: `p13-004-secure-observation-channel`
- Design base head: `ab7ce3259e294c213bcd3b8bfcff36ffa313f2a8`
- Expected main head at preflight: `691aaf02ce4ee96a7d2be0e18c378e77418c8008`
- Final proof head: recorded by the final commit and exact-head CI report

P13-004B proves a future native observation boundary against disposable
localhost fixtures. It does not integrate the channel into the Desktop UI and
does not deploy SSH forwarding or the product mTLS endpoint.

No production mutation occurred. No SSH session, firewall change, certificate,
credential, public API exposure, route/DNS/proxy change, or runtime control was
performed. All fixture listeners bind to `127.0.0.1:0` and terminate after each
test.

## Proof topology

```text
Rust unit test
    |
    | disposable 127.0.0.1:ephemeral HTTPS + mutual TLS
    v
DisposableLocalMtlsFixture
    |
    | typed ObservationResource, one bounded GET
    v
SecureObservationClient (native Rust module)
    |
    v
sanitized status/body result
```

There is no renderer call path in this proof. No `#[tauri::command]` was added;
the existing Tauri command count remains zero and the capability file remains
empty. The renderer cannot provide a URL, HTTP method, filesystem path,
certificate PEM, private key, or key path.

## Current native boundary before this proof

The pre-proof native boundary contained only the Tauri window bootstrap. It
had no privileged commands and no native network client. Renderer secret
storage was absent. The new `observation_channel` module is an internal Rust
proof surface and is not registered with Tauri.

## Native surface and resource allowlist

`ObservationResource` is an enum, not a caller-provided path string. It maps
only to the existing read-only contract:

```text
/api/v1/node/status
/api/v1/node/identity
/api/v1/node/capabilities
/api/v1/node/services
/api/v1/node/connection
/api/v1/node/metadata
/api/v1/health/current
/api/v1/health/history
/api/v1/events
/metrics
```

`NATIVE_METHOD_POLICY=GET_ONLY`. The client has no POST, PUT, PATCH, or DELETE
method. The fixture nevertheless tests every mutating method and returns 405,
while an unknown GET returns 404.

## Disposable certificate and identity model

Every certificate and private key is generated in memory by `rcgen` during the
Rust test. Nothing is written as PEM, KEY, PFX, or P12. The fixture creates:

- a disposable test CA;
- a `localhost` server certificate signed by that CA;
- a trusted observer certificate;
- a trusted wrong-scope certificate;
- an unknown-CA client certificate;
- an expired client certificate;
- a separate unknown server CA for server-trust rejection.

The client uses an explicit in-memory root trust anchor and validates the
server certificate identity as `localhost`. Certificate validation is not
disabled. Wrong hostname and unknown server CA fail the TLS connection. The
server requires a client certificate signed by the trusted test CA.

Authentication is separated from authorization. The fixture uses a narrow
in-memory SHA-256 certificate fingerprint allowlist for the observer scope.
The wrong-scope certificate is trusted by the CA but is not allowlisted and is
rejected with HTTP 403. It has no SSH, administrator, WireGuard, Reality,
Hysteria2, service-manager, or runtime role.

`REVOCATION_IMPLEMENTATION=LOCAL_PROOF_ONLY`: one fixture and one observer
client first complete a successful GET (`200`), then that same observer
certificate fingerprint is added to the in-memory revoked set and the same
client against the same fixture receives `403`. The fixture is then joined and
its loopback address is rebound to prove listener release. This is not the
production CRL/OCSP or certificate lifecycle design.

## Request bounds and read-only behavior

- `REQUEST_TIMEOUT_MS=5000` default, using bounded TCP connect/read/write
  timeouts.
- `MAX_RESPONSE_BYTES=1048576` response body limit, checked incrementally and
  against declared `Content-Length` before buffering the body.
- `NATIVE_MAX_ATTEMPTS=1`; the native proof adds no retry tree to the existing
  P13-003 renderer policy.
- Non-success statuses are returned as errors and never retried.
- Error values are sanitized enum variants and contain no certificate or key
  bytes.

The fixture has no runtime mutation handler. The tested boundary is:

| Request | Result |
|---|---|
| Approved GET resource | 200 |
| Unknown GET | 404 |
| POST | 405 |
| PUT | 405 |
| PATCH | 405 |
| DELETE | 405 |

## Security proof results

The Rust proof tests cover:

- valid `localhost` server identity accepted;
- wrong server hostname rejected;
- untrusted server CA rejected;
- valid observer accepted;
- missing client certificate rejected;
- unknown client CA rejected;
- expired client certificate rejected;
- trusted wrong-scope client rejected;
- same observer certificate accepted before local revocation and rejected after
  revocation against the same fixture/server instance;
- approved resource allowlist and exact path mapping;
- unknown GET and all mutating methods rejected;
- timeout enforcement;
- oversized response rejection;
- 404/non-success without a retry loop;
- private-key and certificate PEM markers absent from formatted errors.

Each fixture joins its server thread and verifies its loopback address can be
bound again. `FIXTURE_LISTENERS_LEFT=0` is therefore part of the local proof.

## Dependencies

| Direct dependency | Purpose | License metadata |
|---|---|---|
| `rustls` | TLS client/server, certificate validation, mTLS | Apache-2.0 OR ISC OR MIT |
| `rcgen` | Disposable in-memory test certificate generation (dev-dependency) | MIT OR Apache-2.0 |
| `sha2` | Deterministic local fingerprint allowlist/revocation proof (dev-dependency) | MIT OR Apache-2.0 |
| `time` | Expired test certificate validity window (dev-dependency) | MIT OR Apache-2.0 |

`rustls` is the only P13-004B production direct dependency. `rcgen`, `sha2`,
and `time` are test-only direct dev-dependencies. Cargo metadata was inspected
for provenance and license fields. No GPL/AGPL dependency was added and no
source was vendored.

## Secret and renderer boundary

- Private keys are consumed only while constructing native test/client TLS
  configuration.
- There is no private-key getter, serialization response, Debug output, or
  logging of identity material.
- No `localStorage`, IndexedDB, plaintext credential config, Windows
  Credential Manager, or DPAPI integration was added.
- No frontend source, `VITE_*` environment contract, capability, or Tauri
  command was changed.
- Renderer source is forbidden from private-key ownership or credential
  storage. Native Rust may handle in-memory credential material for the proof.
- Both source policies reject embedded literal private-key PEM blocks,
  production credentials, forbidden process/control patterns, and tracked
  application credential files with `.pem`, `.key`, `.pfx`, or `.p12`
  extensions.
- The security scan therefore detects secret material rather than rejecting an
  honest native identifier such as `client_private_key_der`. The sanitized
  error test constructs PEM marker text dynamically so the test does not embed
  a credential block.

`RENDERER_PRIVATE_KEY_EXPOSURE=NONE`.

## CI and known limitations

The existing Edge Desktop CI did not run Rust unit tests, so one minimal step
was added to run `cargo test --locked --offline` in the existing Rust job
sequence. The security check keeps renderer secret ownership protection,
allows semantically honest native credential handling, and separately rejects
actual embedded/tracked secret material. Runner labels, artifact identity, and
deployment behavior were not redesigned.

This proof does not mean:

- mTLS is deployed or that a production endpoint is available;
- a production CA, port, certificate lifetime, revocation service, or native
  credential boundary is finalized;
- Windows Credential Manager or DPAPI is implemented;
- the Tauri renderer command is integrated;
- the VPS, WireGuard, Xray Reality, Hysteria2, firewall, DNS, or routes were
  touched;
- the Desktop is connected to a real production API.

`P13-004C STILL REQUIRED`: a separate read-only VPS preflight must reconfirm
listeners, port ownership, server identity, firewall policy, and rollback
evidence before any founder-authorized production canary.
