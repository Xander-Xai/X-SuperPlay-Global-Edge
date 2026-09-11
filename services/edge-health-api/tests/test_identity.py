import json
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from jsonschema import validate

SERVICE_ROOT = Path(__file__).parents[1]
AGENT_ROOT = SERVICE_ROOT.parents[1] / "tools" / "edge-health-agent"
sys.path.insert(0, str(SERVICE_ROOT))
sys.path.insert(0, str(AGENT_ROOT))

from app import create_server
from identity.provider import IdentityConfigError, NodeIdentityProvider


IDENTITY_SCHEMA = {
    "type": "object",
    "required": ["node_id", "region", "provider", "version"],
    "additionalProperties": False,
    "properties": {field: {"type": "string", "minLength": 1} for field in ("node_id", "region", "provider", "version")},
}

CAPABILITIES_SCHEMA = {
    "type": "object",
    "required": ["wireguard", "xray_reality", "hysteria2"],
    "additionalProperties": False,
    "properties": {field: {"type": "boolean"} for field in ("wireguard", "xray_reality", "hysteria2")},
}

METADATA_SCHEMA = {
    "type": "object",
    "required": ["node_id", "runtime_version", "api_version"],
    "additionalProperties": False,
    "properties": {field: {"type": "string", "minLength": 1} for field in ("node_id", "runtime_version", "api_version")},
}


def write_config(path: Path, capabilities=True):
    content = """
identity:
  node_id: node-test-01
  region: test-region
  provider: test-provider
  version: v-test
"""
    if capabilities:
        content += """
capabilities:
  wireguard: true
  xray_reality: false
  hysteria2: true
"""
    content += """
metadata:
  runtime_version: runtime-test
  api_version: v1
"""
    path.write_text(content, encoding="utf-8")


class IdentityTests(unittest.TestCase):
    def test_valid_identity_is_loaded_from_config(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "node.yaml"
            write_config(path)
            provider = NodeIdentityProvider(path)
            self.assertEqual(provider.identity().to_dict()["node_id"], "node-test-01")
            self.assertEqual(provider.identity().to_dict()["region"], "test-region")
            self.assertEqual(provider.capabilities().to_dict(), {"wireguard": True, "xray_reality": False, "hysteria2": True})
            self.assertEqual(provider.metadata().to_dict()["runtime_version"], "runtime-test")

    def test_missing_config_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(IdentityConfigError):
                NodeIdentityProvider(Path(directory) / "missing.yaml")

    def test_invalid_yaml_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "node.yaml"
            path.write_text("identity: [broken", encoding="utf-8")
            with self.assertRaises(IdentityConfigError):
                NodeIdentityProvider(path)

    def test_missing_capabilities_default_to_false(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "node.yaml"
            write_config(path, capabilities=False)
            self.assertEqual(NodeIdentityProvider(path).capabilities().to_dict(), {"wireguard": False, "xray_reality": False, "hysteria2": False})

    def test_identity_api_responses_match_schema_and_are_read_only(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "node.yaml"
            write_config(config)
            server = create_server("127.0.0.1", 0, Path(directory) / "evidence", config)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f"http://127.0.0.1:{server.server_address[1]}"
            try:
                with urlopen(base + "/api/v1/node/identity", timeout=2) as response:
                    identity = json.loads(response.read().decode("utf-8"))
                with urlopen(base + "/api/v1/node/capabilities", timeout=2) as response:
                    capabilities = json.loads(response.read().decode("utf-8"))
                with urlopen(base + "/api/v1/node/metadata", timeout=2) as response:
                    metadata = json.loads(response.read().decode("utf-8"))
                validate(identity, IDENTITY_SCHEMA)
                validate(capabilities, CAPABILITIES_SCHEMA)
                validate(metadata, METADATA_SCHEMA)
                self.assertEqual(identity["node_id"], "node-test-01")
                self.assertEqual(capabilities["wireguard"], True)
                self.assertEqual(metadata["api_version"], "v1")

                request = Request(base + "/api/v1/node/identity", method="POST")
                with self.assertRaises(HTTPError) as raised:
                    urlopen(request, timeout=2)
                self.assertEqual(raised.exception.code, 405)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
