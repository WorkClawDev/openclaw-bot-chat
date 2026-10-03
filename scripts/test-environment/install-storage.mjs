import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { chmod, mkdir, mkdtemp, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { state, reportFailure } from './lib.mjs';

const execute = promisify(execFile);
const version = '4.48';
const archiveDigest = '4a7d108384d044d95212d1342cdda9533fa55842c1c9b41f606ca3c8a9561124';
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

try {
  if (process.platform !== 'linux' || process.arch !== 'x64') {
    throw new Error('This test environment currently requires Linux x86_64 for its pinned storage binary');
  }
  const folder = join(state, 'seaweedfs');
  const binary = join(folder, 'weed');
  const marker = join(folder, 'verified.json');
  await mkdir(folder, { recursive: true, mode: 0o700 });
  try {
    const installed = JSON.parse(await readFile(marker, 'utf8'));
    if (installed.archiveDigest === archiveDigest && installed.binaryDigest === digest(await readFile(binary))) {
      console.log(`SeaweedFS ${version} verified`);
      process.exit(0);
    }
  } catch { /* Download or validate the pinned archive below. */ }
  const archive = join(folder, 'linux_amd64.tar.gz');
  let bytes;
  try { bytes = await readFile(archive); } catch { /* Download below. */ }
  if (!bytes || digest(bytes) !== archiveDigest) {
    const temporary = `${archive}.${process.pid}.tmp`;
    try {
      await execute('curl', ['--fail', '--location', '--silent', '--show-error', '--retry', '2', '--max-time', '180',
        '--output', temporary, `https://github.com/seaweedfs/seaweedfs/releases/download/${version}/linux_amd64.tar.gz`]);
      bytes = await readFile(temporary);
      if (digest(bytes) !== archiveDigest) throw new Error('SeaweedFS archive SHA-256 verification failed');
      await rename(temporary, archive);
    } finally {
      await rm(temporary, { force: true });
    }
  }
  const extraction = await mkdtemp(join(folder, 'extract-'));
  try {
    await execute('tar', ['-xzf', archive, '-C', extraction, 'weed']);
    const extracted = join(extraction, 'weed');
    await chmod(extracted, 0o755);
    const binaryDigest = digest(await readFile(extracted));
    await rename(extracted, binary);
    await writeFile(marker, JSON.stringify({ version, archiveDigest, binaryDigest }) + '\n', { mode: 0o600 });
  } finally {
    await rm(extraction, { recursive: true, force: true });
  }
  console.log(`SeaweedFS ${version} installed with verified SHA-256`);
} catch (error) {
  reportFailure(error);
}
