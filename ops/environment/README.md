# Environment profiles

| Profile | Purpose | Provisioning boundary |
| --- | --- | --- |
| local | Developer feedback using synthetic data | Developer-managed non-production secrets outside Git |
| lab | Physical ESP32, PostgreSQL, Mosquitto and TLS validation | Lab owner-managed credentials and CA |
| ci | Reproducible build and contract checks | CI secret store and least-privilege service identities |

Document variable names only when the concrete component is introduced. Typical categories are database endpoint, broker endpoint, TLS trust location, session signing material, push provider identity and OTA verification key. Values, private keys, tokens, Wi-Fi passwords and PoP values must never enter this repository.

