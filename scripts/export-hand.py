#!/usr/bin/env python3
"""Export the WebXR hand for the native illustration, with its skeleton.

Usage: python3 scripts/export-hand.py ../neural-band-poc/dashboard/static/models/right-hand.glb

Writes Sources/Kinesis/Resources/hand.json: the rest-pose mesh in the app's own
space, the fingertip locations, and the rig (joint rest transforms, a parent for
each joint, and four bone indices and weights per vertex). The model stores its
25 joints flat, so the finger chains are rebuilt here from the WebXR joint names.
"""
import json
import struct
import sys
from pathlib import Path

import numpy as np

COMPONENTS = {5120: ('b', 1), 5121: ('B', 1), 5122: ('h', 2), 5123: ('H', 2), 5125: ('I', 4), 5126: ('f', 4)}
WIDTHS = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}


def load(path):
    data = Path(path).read_bytes()
    magic, _, length = struct.unpack('<4sII', data[:12])
    assert magic == b'glTF'
    offset, chunks = 12, []
    while offset < length:
        size, kind = struct.unpack('<I4s', data[offset:offset + 8])
        chunks.append(data[offset + 8:offset + 8 + size])
        offset += 8 + size
    return json.loads(chunks[0]), chunks[1]


def accessor(gltf, binary, index):
    spec = gltf['accessors'][index]
    view = gltf['bufferViews'][spec['bufferView']]
    code, size = COMPONENTS[spec['componentType']]
    width = WIDTHS[spec['type']]
    start = view.get('byteOffset', 0) + spec.get('byteOffset', 0)
    stride = view.get('byteStride') or size * width
    rows = [struct.unpack_from('<' + code * width, binary, start + i * stride) for i in range(spec['count'])]
    return np.array(rows, dtype=np.float64 if code == 'f' else np.int64)


def local_matrix(node):
    if 'matrix' in node:
        return np.array(node['matrix'], dtype=np.float64).reshape(4, 4).T
    x, y, z, w = node.get('rotation', [0, 0, 0, 1])
    rotation = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                         [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                         [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])
    matrix = np.eye(4)
    matrix[:3, :3] = rotation * np.array(node.get('scale', [1, 1, 1]))
    matrix[:3, 3] = node.get('translation', [0, 0, 0])
    return matrix


def main(source):
    gltf, binary = load(source)
    parents = {child: index for index, node in enumerate(gltf['nodes']) for child in node.get('children', [])}

    def world(index):
        matrix = local_matrix(gltf['nodes'][index])
        return world(parents[index]) @ matrix if index in parents else matrix

    skin = gltf['skins'][0]
    names = [gltf['nodes'][j]['name'] for j in skin['joints']]
    joints = [world(j) for j in skin['joints']]
    inverse_bind = accessor(gltf, binary, skin['inverseBindMatrices']).reshape(-1, 4, 4).transpose(0, 2, 1)
    mesh_node = next(i for i, node in enumerate(gltf['nodes']) if 'mesh' in node)
    primitive = gltf['meshes'][gltf['nodes'][mesh_node]['mesh']]['primitives'][0]
    raw = accessor(gltf, binary, primitive['attributes']['POSITION'])
    bone_indices = accessor(gltf, binary, primitive['attributes']['JOINTS_0'])
    bone_weights = accessor(gltf, binary, primitive['attributes']['WEIGHTS_0'])
    bone_weights = bone_weights / bone_weights.sum(axis=1, keepdims=True)
    indices = accessor(gltf, binary, primitive['indices']).reshape(-1)

    # Rest pose in world space, the way three.js skins an attached mesh.
    bound = (world(mesh_node) @ np.c_[raw, np.ones(len(raw))].T).T
    skinning = np.einsum('vk,vkab->vab', bone_weights,
                         np.array([joints[j] @ inverse_bind[j] for j in range(len(joints))])[bone_indices])
    rest = np.einsum('vab,vb->va', skinning, bound)[:, :3]

    # The app's space: the wrist at the origin, the fingers along +y, 18 units to the metre.
    wrist = joints[names.index('wrist')][:3, 3]
    basis = np.array([[0, 0, 18, 0], [0, -18, 0, 0], [18, 0, 0, 0], [0, 0, 0, 1.0]])
    basis = basis @ np.array([[1, 0, 0, -wrist[0]], [0, 1, 0, -wrist[1]], [0, 0, 1, -wrist[2]], [0, 0, 0, 1.0]])
    positions = (basis @ np.c_[rest, np.ones(len(rest))].T).T[:, :3]
    rig = [basis @ joint for joint in joints]

    normals = np.zeros_like(positions)
    triangles = indices.reshape(-1, 3)
    faces = np.cross(positions[triangles[:, 1]] - positions[triangles[:, 0]],
                     positions[triangles[:, 2]] - positions[triangles[:, 0]])
    for corner in range(3):
        np.add.at(normals, triangles[:, corner], faces)
    normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-12)

    def parent(name):
        if name == 'wrist':
            return -1
        finger, _, part = name.rpartition('-')
        if name.endswith('metacarpal'):
            return names.index('wrist')
        order = ['metacarpal', 'phalanx-proximal', 'phalanx-intermediate', 'phalanx-distal', 'tip']
        prefix = name
        for suffix in order:
            if name.endswith(suffix):
                prefix = name[:-len(suffix)]
                at = order.index(suffix)
                break
        for back in range(at - 1, -1, -1):
            candidate = prefix + order[back]
            if candidate in names:
                return names.index(candidate)
        raise ValueError(name)

    tips = {finger: rig[names.index(joint)][:3, 3].tolist()
            for finger, joint in [('thumb', 'thumb-tip'), ('index', 'index-finger-tip'), ('middle', 'middle-finger-tip')]}
    output = {
        'indices': indices.tolist(), 'positions': positions.reshape(-1).tolist(), 'normals': normals.reshape(-1).tolist(),
        'tips': tips,
        'joints': [{'name': name, 'parent': parent(name), 'rest': rig[i].T.reshape(-1).tolist()} for i, name in enumerate(names)],
        'boneIndices': bone_indices.reshape(-1).tolist(), 'boneWeights': bone_weights.reshape(-1).tolist(),
    }
    target = Path(__file__).resolve().parent.parent / 'Sources/Kinesis/Resources/hand.json'
    previous = json.loads(target.read_text()) if target.exists() else None
    target.write_text(json.dumps(output, separators=(',', ':'), default=float,
                                 ).replace('e-', 'e-'))  # numbers rounded below
    rounded = json.loads(target.read_text(), parse_float=lambda text: round(float(text), 6))
    target.write_text(json.dumps(rounded, separators=(',', ':')))
    print(f'Exported {len(positions)} vertices, {len(names)} joints')
    if previous:
        drift = np.abs(np.array(previous['positions']) - positions.reshape(-1)).max()
        print(f'Largest difference from the previous mesh: {drift:.6f}')
    residual = max(np.abs(joints[j] @ inverse_bind[j] - np.eye(4)).max() for j in range(len(joints)))
    print(f'Rest pose differs from the bind pose by at most {residual:.6f}')


if __name__ == '__main__':
    main(sys.argv[1])
