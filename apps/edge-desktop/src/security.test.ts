import { describe, expect, it } from 'vitest'
import tauriCapabilities from '../src-tauri/capabilities/default.json'
import tauriSource from '../src-tauri/src/lib.rs?raw'
import appSource from './App.tsx?raw'
import apiSource from './api/edge-api-client.ts?raw'
import mockSource from './api/mock-edge-api-client.ts?raw'

describe('desktop security boundary', () => {
  it('does not embed production hosts, credentials, or private key material', () => {
    const source = [appSource, apiSource, mockSource].join('\n')
    expect(source).not.toContain('198.51.100.253')
    expect(source).not.toMatch(/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/)
    expect(source).not.toMatch(/(?:private[_-]?key|ssh[_-]?credential|wireguard[_-]?secret)\s*[:=]/i)
  })

  it('keeps the Rust layer command-free and capabilities empty', () => {
    expect(tauriSource).not.toMatch(/Command::new|std::process|powershell|cmd\.exe|WireGuard|Xray|route|firewall|registry/i)
    expect(tauriCapabilities.permissions).toEqual([])
  })
})
