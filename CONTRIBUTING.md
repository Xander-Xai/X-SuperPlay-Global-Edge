# Contributing

Thanks for helping improve X-SuperPlay Global Edge. Keep changes small,
reviewable, and safe for a public repository.

## Development setup

```bash
git clone https://github.com/yandexuanxuan/X-SuperPlay-Global-Edge.git
cd X-SuperPlay-Global-Edge
python -m pip install -r services/edge-health-api/requirements.txt \
  -r tools/edge-health-agent/requirements.txt
cd apps/edge-desktop && pnpm install --frozen-lockfile
```

Use `.env.example` and the `*.example` client/config files. Never copy a
production environment file into this checkout.

## Tests and checks

From the repository root, run the checks relevant to your change:

```bash
bash scripts/secret-scan.sh
bash scripts/open-source-readiness.sh
bash scripts/self-test.sh
python -m unittest discover -s services/edge-health-api/tests -v
python -m unittest discover -s tools/edge-health-agent/tests -v
cd apps/edge-desktop
pnpm typecheck
pnpm test
pnpm build
cd src-tauri && cargo check && cargo test
```

The pull request CI runs the complete repository, Docker, and Windows desktop
checks. A change is ready to merge only when the applicable required checks
are green and the diff has been reviewed.

## Pull requests

Create a short-lived branch, explain what and why you changed, and include
test evidence. Prefer a squash merge for focused changes. Do not rewrite
public history or force-push `main`; ordinary fixes use branch → commit → PR
→ CI → merge.

## Security and privacy boundary

The public repository must not contain:

- real production IP addresses or domains;
- credentials, tokens, private keys, or real VPN peer configuration;
- production evidence, operator records, or personal machine paths.

Use RFC 5737 documentation addresses, synthetic credentials, placeholder
hostnames, and unpopulated example files. See [`SECURITY.md`](SECURITY.md)
before reporting a suspected exposure.
