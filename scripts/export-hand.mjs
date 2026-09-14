// Export a neutral WebXR hand and fingertip locations for the native illustration.
// Usage: node scripts/export-hand.mjs ../neural-band-poc/dashboard/static
import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

if (!process.argv[2]) throw new Error('Pass the neural-band-poc dashboard/static directory');
const source = resolve(process.argv[2]);
const load = path => import(pathToFileURL(resolve(source, path)));
const THREE = await load('vendor/three.module.js');
const { GLTFLoader } = await load('vendor/GLTFLoader.js');
const bytes = await readFile(resolve(source, 'models/right-hand.glb'));
const { scene } = await new GLTFLoader().parseAsync(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength), '');
const joints = {};
let mesh;
scene.traverse(object => {
  if (object.isSkinnedMesh) mesh = object;
  if (object.isBone) joints[object.name] = object;
});
if (!mesh || !joints.wrist) throw new Error('Hand mesh or wrist missing');
scene.updateMatrixWorld(true);
mesh.skeleton.update();
const wrist = joints.wrist.getWorldPosition(new THREE.Vector3());
const basis = new THREE.Matrix4().set(0,0,18,0, 0,-18,0,0, 18,0,0,0, 0,0,0,1)
  .multiply(new THREE.Matrix4().makeTranslation(-wrist.x, -wrist.y, -wrist.z));
const positions = [];
const point = new THREE.Vector3();
for (let i = 0; i < mesh.geometry.attributes.position.count; i++) {
  mesh.getVertexPosition(i, point).applyMatrix4(mesh.matrixWorld).applyMatrix4(basis);
  positions.push(point.x, point.y, point.z);
}
const indices = Array.from(mesh.geometry.index.array);
const geometry = new THREE.BufferGeometry();
geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
geometry.setIndex(indices);
geometry.computeVertexNormals();
const tips = {};
for (const [finger, joint] of [['thumb', 'thumb-tip'], ['index', 'index-finger-tip'], ['middle', 'middle-finger-tip']]) {
  tips[finger] = joints[joint].getWorldPosition(new THREE.Vector3()).applyMatrix4(basis).toArray();
}
await writeFile(new URL('../Sources/Kinesis/Resources/hand.json', import.meta.url),
  JSON.stringify({indices, positions, normals: Array.from(geometry.attributes.normal.array), tips},
    (_, value) => typeof value === 'number' ? +value.toFixed(6) : value));
console.log(`Exported neutral hand: ${positions.length / 3} vertices`);
