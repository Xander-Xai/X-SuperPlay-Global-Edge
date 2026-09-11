"""Node runtime state API route handlers."""

from __future__ import annotations

from typing import Any

from identity.provider import NodeIdentityProvider
from models import EvidenceRepository
from runtime.collector import RuntimeStateCollector


def _collector(repository: EvidenceRepository, identity_provider: NodeIdentityProvider | None):
    node_id = identity_provider.identity().node_id if identity_provider else "edge-current"
    return RuntimeStateCollector(repository, node_id=node_id)


def get_status(
    repository: EvidenceRepository, identity_provider: NodeIdentityProvider | None = None
) -> dict[str, Any]:
    return _collector(repository, identity_provider).collect().status_payload()


def get_services(
    repository: EvidenceRepository, identity_provider: NodeIdentityProvider | None = None
) -> dict[str, Any]:
    return _collector(repository, identity_provider).collect().services_payload()


def get_connection(
    repository: EvidenceRepository, identity_provider: NodeIdentityProvider | None = None
) -> dict[str, Any]:
    return _collector(repository, identity_provider).collect().connection_payload()


def get_identity(identity_provider: NodeIdentityProvider) -> dict[str, str]:
    return identity_provider.identity().to_dict()


def get_capabilities(identity_provider: NodeIdentityProvider) -> dict[str, bool]:
    return identity_provider.capabilities().to_dict()


def get_metadata(identity_provider: NodeIdentityProvider) -> dict[str, str]:
    return identity_provider.metadata().to_dict()
