"""Serializable node identity models."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class NodeIdentity:
    node_id: str
    region: str
    provider: str
    version: str

    def to_dict(self) -> dict[str, str]:
        return {
            "node_id": self.node_id,
            "region": self.region,
            "provider": self.provider,
            "version": self.version,
        }

@dataclass(frozen=True)
class NodeCapabilities:
    wireguard: bool = False
    xray_reality: bool = False
    hysteria2: bool = False

    def to_dict(self) -> dict[str, bool]:
        return {
            "wireguard": self.wireguard,
            "xray_reality": self.xray_reality,
            "hysteria2": self.hysteria2,
        }
@dataclass(frozen=True)
class NodeMetadata:
    node_id: str
    runtime_version: str
    api_version: str

    def to_dict(self) -> dict[str, str]:
        return {
            "node_id": self.node_id,
            "runtime_version": self.runtime_version,
            "api_version": self.api_version,
        }
