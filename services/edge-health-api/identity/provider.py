"""Configuration-backed node identity provider."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Mapping

import yaml

from .models import NodeCapabilities, NodeIdentity, NodeMetadata


class IdentityConfigError(ValueError):
    """Raised when node identity configuration is missing or invalid."""


def _required_string(mapping: Mapping[str, Any], field: str, section: str) -> str:
    value = mapping.get(field)
    if not isinstance(value, str) or not value.strip():
        raise IdentityConfigError(f"{section}.{field} must be a non-empty string")
    return value.strip()


def _optional_bool(mapping: Mapping[str, Any], field: str) -> bool:
    value = mapping.get(field, False)
    if not isinstance(value, bool):
        raise IdentityConfigError(f"capabilities.{field} must be a boolean")
    return value


class NodeIdentityProvider:
    """Load identity once from YAML; no identity value is hardcoded here."""

    def __init__(self, config_path: str | Path):
        self.config_path = Path(config_path)
        self._identity, self._capabilities, self._metadata = self._load()

    def _load(self) -> tuple[NodeIdentity, NodeCapabilities, NodeMetadata]:
        try:
            raw = yaml.safe_load(self.config_path.read_text(encoding="utf-8"))
        except FileNotFoundError as exc:
            raise IdentityConfigError(f"identity config not found: {self.config_path}") from exc
        except OSError as exc:
            raise IdentityConfigError(f"cannot read identity config {self.config_path}: {exc}") from exc
        except yaml.YAMLError as exc:
            raise IdentityConfigError(f"invalid YAML in identity config {self.config_path}: {exc}") from exc
        if not isinstance(raw, Mapping):
            raise IdentityConfigError("identity config root must be a mapping")

        identity = raw.get("identity")
        if not isinstance(identity, Mapping):
            raise IdentityConfigError("identity section is required")
        identity_model = NodeIdentity(
            node_id=_required_string(identity, "node_id", "identity"),
            region=_required_string(identity, "region", "identity"),
            provider=_required_string(identity, "provider", "identity"),
            version=_required_string(identity, "version", "identity"),
        )

        capabilities = raw.get("capabilities", {})
        if not isinstance(capabilities, Mapping):
            raise IdentityConfigError("capabilities must be a mapping")
        capabilities_model = NodeCapabilities(
            wireguard=_optional_bool(capabilities, "wireguard"),
            xray_reality=_optional_bool(capabilities, "xray_reality"),
            hysteria2=_optional_bool(capabilities, "hysteria2"),
        )

        metadata = raw.get("metadata")
        if not isinstance(metadata, Mapping):
            raise IdentityConfigError("metadata section is required")
        metadata_model = NodeMetadata(
            node_id=identity_model.node_id,
            runtime_version=_required_string(metadata, "runtime_version", "metadata"),
            api_version=_required_string(metadata, "api_version", "metadata"),
        )
        return identity_model, capabilities_model, metadata_model

    def identity(self) -> NodeIdentity:
        return self._identity

    def capabilities(self) -> NodeCapabilities:
        return self._capabilities

    def metadata(self) -> NodeMetadata:
        return self._metadata
