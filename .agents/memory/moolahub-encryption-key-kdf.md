---
name: MoolaHub encryption key derivation
description: How APP_ENCRYPTION_KEY is turned into the AES-256-GCM key used for wallet private keys and 2FA seeds
---

`artifacts/api-server/src/lib/crypto.ts` derives the AES-256-GCM key from `APP_ENCRYPTION_KEY`:

- If the value is a 64-char hex string (32 random bytes, e.g. from `openssl rand -hex 32`), it is used directly as the key. This is the recommended/expected format and is what the current deployment uses.
- Any other value is treated as a human-chosen passphrase. It must be at least 20 chars or the app throws at first use. It is stretched via `scryptSync` (N=2^17, r=8, p=1, ~128MB memory) with a fixed app-context salt, not a single fast hash.
- The derived key is memoized in-process so the scrypt cost is only paid once per process lifetime, not per encrypt/decrypt call.

**Why:** the previous implementation reduced any arbitrary string to a single `sha256` pass — fast enough to brute-force offline in a DB-leak scenario, exposing every server-custodied wallet private key (recognizable by `0x` + 64 hex format) and every encrypted 2FA seed. scrypt raises that cost by orders of magnitude; it does not fix a genuinely weak passphrase, so operators should still prefer the 64-hex-char format.

**How to apply:** if you touch `crypto.ts`, preserve the two-path behavior (hex-as-is vs. scrypt-stretched passphrase) and keep the key memoized — recomputing scrypt per call would add ~300-400ms to every encrypt/decrypt. Don't reintroduce a fast hash (md5/sha*) as the sole KDF for non-hex input.
