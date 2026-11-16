import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

const [file, algorithm, expected] = process.argv.slice(2);
if (!file || !algorithm || !expected) {
  console.error('usage: verify-file.mjs <file> <sha256|sha512> <expected>');
  process.exit(1);
}

const encoding = algorithm === 'sha512' ? 'base64' : 'hex';
const digest = createHash(algorithm).update(readFileSync(file)).digest(encoding);
if (digest !== expected) {
  console.error(`${file}: ${algorithm} ${digest}`);
  console.error(`expected ${expected}`);
  process.exit(1);
}
