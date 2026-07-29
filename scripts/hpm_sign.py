#!/usr/bin/env python3
# scripts/hpm_sign.py — Ed25519 signing helper for the hpm package repo.
#
# The hpm package index (index.json, per channel) is the root of trust:
# it records every package's sha256. hpm already verifies each fetched
# tarball against that hash, but an UNSIGNED index lets a MITM or a
# compromised mirror swap in a malicious index with matching hashes.
# This helper produces a DETACHED Ed25519 signature (index.json.sig)
# over the exact index.json bytes, signed with the repo's secret key;
# hpm verifies it against the trusted public key (etc/hpm/trusted.pub,
# also compiled into the binary) before trusting any hash inside.
#
# Signature file format: 128 lowercase hex chars (the 64-byte raw
# Ed25519 signature) + newline. Public-key file format: 64 hex chars
# (the 32-byte raw key); lines beginning with '#' are comments.
#
# Scheme: Ed25519 (RFC 8032) — small, modern, deterministic, no
# parameter choices to get wrong. The native verifier is lib/ed25519.ad
# (a TweetNaCl port); this signer uses the host `cryptography` library
# so the build side never hand-rolls crypto either.
#
# Usage:
#   python3 scripts/hpm_sign.py keygen [--out-pub F] [--out-sec F]
#   python3 scripts/hpm_sign.py sign <index.json> <secret-hex-file> <out.sig>
#   python3 scripts/hpm_sign.py pubof <secret-hex-file>
#   python3 scripts/hpm_sign.py verify <index.json> <sig-file> <pub-file>
#
# The secret key is a 32-byte Ed25519 seed in hex. It is NEVER committed
# to the tree — the repo operator holds it out of band and passes its
# path to `build_packages.py` via HPM_REPO_SECKEY.

import os
import sys
from pathlib import Path

# Prefer the audited host `cryptography` library. When it is absent (a
# stripped Debian python, an offline build box, a CI image without the
# wheel), fall back to a pure-Python RFC 8032 Ed25519 signer. Ed25519 is
# deterministic, so the fallback emits byte-identical signatures and public
# keys — the on-image trust root is unchanged and the native TweetNaCl
# verifier (lib/ed25519.ad) still accepts every index we stamp. The build
# must NEVER die just because the wheel is missing.
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey, Ed25519PublicKey)
    from cryptography.hazmat.primitives import serialization as _ser
    _HAVE_CRYPTOGRAPHY = True
except ImportError:
    _HAVE_CRYPTOGRAPHY = False
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import _ed25519_pure as _pure

_RAW_PRIV = dict()
_RAW_PUB = dict()
if _HAVE_CRYPTOGRAPHY:
    _RAW_PRIV = dict(encoding=_ser.Encoding.Raw,
                     format=_ser.PrivateFormat.Raw,
                     encryption_algorithm=_ser.NoEncryption())
    _RAW_PUB = dict(encoding=_ser.Encoding.Raw,
                    format=_ser.PublicFormat.Raw)


def _seed_bytes(seed_hex: str) -> bytes:
    seed = bytes.fromhex(seed_hex.strip())
    if len(seed) != 32:
        raise ValueError(f"secret seed must be 32 bytes, got {len(seed)}")
    return seed


def keygen() -> tuple[str, str]:
    """Return (secret_seed_hex, public_key_hex)."""
    if _HAVE_CRYPTOGRAPHY:
        sk = Ed25519PrivateKey.generate()
        seed = sk.private_bytes(**_RAW_PRIV)
        pub = sk.public_key().public_bytes(**_RAW_PUB)
        return seed.hex(), pub.hex()
    seed = os.urandom(32)
    return seed.hex(), _pure.publickey(seed).hex()


def _load_secret(seed_hex: str):
    seed = _seed_bytes(seed_hex)
    return Ed25519PrivateKey.from_private_bytes(seed)


def pub_of(seed_hex: str) -> str:
    if _HAVE_CRYPTOGRAPHY:
        return _load_secret(seed_hex).public_key().public_bytes(
            **_RAW_PUB).hex()
    return _pure.publickey(_seed_bytes(seed_hex)).hex()


def sign_bytes(data: bytes, seed_hex: str) -> str:
    """Return the detached signature as 128 hex chars."""
    if _HAVE_CRYPTOGRAPHY:
        return _load_secret(seed_hex).sign(data).hex()
    return _pure.signature(data, _seed_bytes(seed_hex)).hex()


def sign_file(index_path: str, seed_hex: str) -> str:
    return sign_bytes(Path(index_path).read_bytes(), seed_hex)


def parse_pubfile(path: str) -> bytes:
    """Read a trusted.pub file (skip '#' comment lines) -> 32 raw bytes."""
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        return bytes.fromhex(line)
    raise ValueError(f"no public key found in {path}")


def verify_file(index_path: str, sig_path: str, pub_path: str) -> bool:
    pub_raw = parse_pubfile(pub_path)
    sig = bytes.fromhex(Path(sig_path).read_text().strip())
    data = Path(index_path).read_bytes()
    if _HAVE_CRYPTOGRAPHY:
        pub = Ed25519PublicKey.from_public_bytes(pub_raw)
        try:
            pub.verify(sig, data)
            return True
        except Exception:
            return False
    return _pure.checkvalid(sig, data, pub_raw)


def _main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    cmd = argv[0]
    if cmd == "keygen":
        seed, pub = keygen()
        out_pub = out_sec = None
        i = 1
        while i < len(argv) - 1:
            if argv[i] == "--out-pub":
                out_pub = argv[i + 1]
            elif argv[i] == "--out-sec":
                out_sec = argv[i + 1]
            i += 2
        if out_pub:
            Path(out_pub).write_text(
                "# Hamnix hpm repo trust root (Ed25519 public key, hex)\n"
                f"{pub}\n")
        if out_sec:
            Path(out_sec).write_text(seed + "\n")
            Path(out_sec).chmod(0o600)
        print(f"secret {seed}")
        print(f"public {pub}")
        return 0
    if cmd == "pubof":
        print(pub_of(Path(argv[1]).read_text()))
        return 0
    if cmd == "sign":
        index_path, sec_path, out_path = argv[1], argv[2], argv[3]
        sig = sign_file(index_path, Path(sec_path).read_text())
        Path(out_path).write_text(sig + "\n")
        return 0
    if cmd == "verify":
        ok = verify_file(argv[1], argv[2], argv[3])
        print("OK" if ok else "BAD")
        return 0 if ok else 1
    print(f"hpm_sign: unknown command {cmd!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
