"""Vector / quaternion helpers (numpy, vectorised).

Quaternions are (w, x, y, z), Hamilton convention, and ``rotate(q, v) = q * v * q^-1``
exactly like ``Quat.rotate`` in BarPathKit (§3).
"""
from __future__ import annotations

import numpy as np

G = 9.80665


def normalize(v: np.ndarray, eps: float = 1e-12) -> np.ndarray:
    """Normalise along the last axis; vectors with norm < eps become zero (like Vec3.normalized)."""
    v = np.asarray(v, dtype=float)
    n = np.linalg.norm(v, axis=-1, keepdims=True)
    out = np.zeros_like(v)
    np.divide(v, n, out=out, where=n >= eps)
    return out


def quat_conj(q: np.ndarray) -> np.ndarray:
    q = np.asarray(q, dtype=float)
    return q * np.array([1.0, -1.0, -1.0, -1.0])


def quat_mul(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    a = np.asarray(a, dtype=float)
    b = np.asarray(b, dtype=float)
    aw, ax, ay, az = np.moveaxis(a, -1, 0)
    bw, bx, by, bz = np.moveaxis(b, -1, 0)
    return np.stack([
        aw * bw - ax * bx - ay * by - az * bz,
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
    ], axis=-1)


def quat_rotate(q: np.ndarray, v: np.ndarray) -> np.ndarray:
    """v' = q v q^-1 for (N,4) / (N,3) arrays (or single vectors)."""
    q = np.asarray(q, dtype=float)
    v = np.asarray(v, dtype=float)
    w = q[..., :1]
    u = q[..., 1:]
    t = 2.0 * np.cross(u, v)
    return v + w * t + np.cross(u, t)


def quat_to_matrix(q: np.ndarray) -> np.ndarray:
    """Rotation matrix R with R @ v == quat_rotate(q, v)."""
    q = np.asarray(q, dtype=float)
    w, x, y, z = np.moveaxis(q, -1, 0)
    R = np.stack([
        np.stack([1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)], axis=-1),
        np.stack([2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)], axis=-1),
        np.stack([2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)], axis=-1),
    ], axis=-2)
    return R


def matrix_to_quat(R: np.ndarray) -> np.ndarray:
    """Inverse of quat_to_matrix (w >= 0). Works on (..., 3, 3)."""
    R = np.asarray(R, dtype=float)
    shp = R.shape[:-2]
    R = R.reshape(-1, 3, 3)
    q = np.empty((R.shape[0], 4))
    tr = np.trace(R, axis1=1, axis2=2)
    for i in range(R.shape[0]):
        m = R[i]
        if tr[i] > 0:
            s = np.sqrt(tr[i] + 1.0) * 2
            q[i] = [0.25 * s, (m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s]
        elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
            s = np.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
            q[i] = [(m[2, 1] - m[1, 2]) / s, 0.25 * s, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s]
        elif m[1, 1] > m[2, 2]:
            s = np.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
            q[i] = [(m[0, 2] - m[2, 0]) / s, (m[0, 1] + m[1, 0]) / s, 0.25 * s, (m[1, 2] + m[2, 1]) / s]
        else:
            s = np.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
            q[i] = [(m[1, 0] - m[0, 1]) / s, (m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, 0.25 * s]
    q = normalize(q)
    q[q[:, 0] < 0] *= -1
    return q.reshape(shp + (4,))


def axis_angle_matrix(axis: np.ndarray, angle: np.ndarray) -> np.ndarray:
    """Rodrigues rotation matrices. axis (3,) or (N,3); angle scalar or (N,)."""
    axis = normalize(np.asarray(axis, dtype=float))
    angle = np.asarray(angle, dtype=float)
    axis, angle = np.broadcast_arrays(axis, angle[..., None])
    angle = angle[..., 0]
    x, y, z = np.moveaxis(axis, -1, 0)
    c, s = np.cos(angle), np.sin(angle)
    C = 1 - c
    return np.stack([
        np.stack([c + x * x * C, x * y * C - z * s, x * z * C + y * s], axis=-1),
        np.stack([y * x * C + z * s, c + y * y * C, y * z * C - x * s], axis=-1),
        np.stack([z * x * C - y * s, z * y * C + x * s, c + z * z * C], axis=-1),
    ], axis=-2)
