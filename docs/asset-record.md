# Asset record template

This template documents non-secret infrastructure metadata. Keep completed
records outside a public repository. Never record private keys, credentials,
client profiles, account identifiers, or a real endpoint here.

```yaml
asset:
  provider: <CLOUD_PROVIDER>
  product: <PRODUCT>
  product_class: <VPS_OR_CLOUD_VM>
  region: <APPROVED_REGION>
  os: <SUPPORTED_LINUX>
  cpu_vcpu: <VCPU>
  memory_gb: <MEMORY_GB>
  system_disk_gb: <DISK_GB>
  public_ipv4: <EXTERNAL_SECRET_STORE>
  ssh_key_label: <KEY_LABEL_ONLY>
  admin_ui_tunnel: 127.0.0.1:<LOOPBACK_PORT>
  env_label: <EXTERNAL_ENV_LABEL>
  instance_id: <EXTERNAL_ACCOUNT_RECORD>
  repository_sha: <DEPLOYED_COMMIT>
  runtime_image: <TAG_AND_DIGEST>

verification:
  control_plane: <PASS_OR_PENDING>
  data_plane: <PASS_OR_PENDING>
  recovery_path: <PASS_OR_PENDING>
  off_host_backup: <PASS_OR_PENDING>
```

Use a private operations ledger for values that identify a real provider,
host, account, region-to-node mapping, or production run.
