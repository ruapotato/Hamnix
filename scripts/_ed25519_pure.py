#!/usr/bin/env python3
# scripts/_ed25519_pure.py — pure-Python Ed25519 (RFC 8032) fallback.
#
# hpm_sign.py prefers the audited host `cryptography` library. When that
# wheel is absent (a stripped Debian python, an offline build box, a CI
# image without it), the index signer used to hard-fail with
# ModuleNotFoundError and take the WHOLE installer-image build down with
# it. Ed25519 is deterministic (RFC 8032), so a pure-Python signer emits
# byte-identical signatures and public keys to `cryptography` — the
# on-image trust root (etc/hpm/local-trusted.pub) is unchanged and hpm
# still verifies every index it stamps. This module is the fallback.
#
# This is the classic djb reference implementation (public domain),
# reshaped to extended (x,y,z,t) coordinates so scalar-mult over the
# handful of indices a build produces is not painfully slow. It is NOT
# constant-time and is NOT for secret material that crosses a trust
# boundary — the only secret it ever touches is the COMMITTED local
# on-image key, which is trusted-by-construction (see local-trusted.pub).

import hashlib

_q = 2 ** 255 - 19
_L = 2 ** 252 + 27742317777372353535851937790883648493


def _H(m: bytes) -> bytes:
    return hashlib.sha512(m).digest()


def _inv(x: int) -> int:
    return pow(x, _q - 2, _q)


_d = (-121665 * _inv(121666)) % _q
_I = pow(2, (_q - 1) // 4, _q)


def _xrecover(y: int) -> int:
    xx = (y * y - 1) * _inv(_d * y * y + 1)
    x = pow(xx, (_q + 3) // 8, _q)
    if (x * x - xx) % _q != 0:
        x = (x * _I) % _q
    if x % 2 != 0:
        x = _q - x
    return x


_By = (4 * _inv(5)) % _q
_Bx = _xrecover(_By)
# Base point in extended coordinates (x, y, z, t) with t = x*y.
_B = (_Bx % _q, _By % _q, 1, (_Bx * _By) % _q)


def _edwards_add(P, Q):
    (x1, y1, z1, t1) = P
    (x2, y2, z2, t2) = Q
    a = ((y1 - x1) * (y2 - x2)) % _q
    b = ((y1 + x1) * (y2 + x2)) % _q
    c = (t1 * 2 * _d * t2) % _q
    dd = (z1 * 2 * z2) % _q
    e = b - a
    f = dd - c
    g = dd + c
    h = b + a
    return ((e * f) % _q, (g * h) % _q, (f * g) % _q, (e * h) % _q)


def _scalarmult(P, e: int):
    # Iterative double-and-add (avoids deep recursion for 253-bit scalars).
    Q = (0, 1, 1, 0)  # neutral element
    bits = []
    while e > 0:
        bits.append(e & 1)
        e >>= 1
    for bit in reversed(bits):
        Q = _edwards_add(Q, Q)
        if bit:
            Q = _edwards_add(Q, P)
    return Q


def _bit(h: bytes, i: int) -> int:
    return (h[i // 8] >> (i % 8)) & 1


def _clamp_scalar(h: bytes) -> int:
    return 2 ** 254 + sum(2 ** i * _bit(h, i) for i in range(3, 254))


def _encodepoint(P) -> bytes:
    (x, y, z, t) = P
    zi = _inv(z)
    x = (x * zi) % _q
    y = (y * zi) % _q
    bits = [(y >> i) & 1 for i in range(255)] + [x & 1]
    return bytes(
        sum(bits[i * 8 + j] << j for j in range(8)) for i in range(32)
    )


def _Hint(m: bytes) -> int:
    h = _H(m)
    return sum(2 ** i * _bit(h, i) for i in range(512))


def publickey(seed: bytes) -> bytes:
    """32-byte raw Ed25519 public key for a 32-byte seed."""
    h = _H(seed)
    a = _clamp_scalar(h)
    return _encodepoint(_scalarmult(_B, a))


def signature(msg: bytes, seed: bytes, pub: bytes = None) -> bytes:
    """64-byte raw Ed25519 signature over msg for a 32-byte seed."""
    h = _H(seed)
    a = _clamp_scalar(h)
    if pub is None:
        pub = _encodepoint(_scalarmult(_B, a))
    r = _Hint(h[32:64] + msg)
    R = _scalarmult(_B, r)
    Renc = _encodepoint(R)
    k = _Hint(Renc + pub + msg)
    S = (r + k * a) % _L
    return Renc + S.to_bytes(32, "little")


def _decodepoint(s: bytes):
    y = sum(2 ** i * _bit(s, i) for i in range(255))
    x = _xrecover(y)
    if (x & 1) != _bit(s, 255):
        x = _q - x
    return (x, y, 1, (x * y) % _q)


def _to_affine(P):
    (x, y, z, t) = P
    zi = _inv(z)
    return ((x * zi) % _q, (y * zi) % _q)


def checkvalid(sig: bytes, msg: bytes, pub: bytes) -> bool:
    """Verify a 64-byte raw Ed25519 signature. Returns True/False."""
    if len(sig) != 64 or len(pub) != 32:
        return False
    try:
        R = _decodepoint(sig[:32])
        A = _decodepoint(pub)
    except Exception:
        return False
    S = int.from_bytes(sig[32:64], "little")
    h = _Hint(sig[:32] + pub + msg)
    lhs = _to_affine(_scalarmult(_B, S))
    rhs = _to_affine(_edwards_add(R, _scalarmult(A, h)))
    return lhs == rhs
