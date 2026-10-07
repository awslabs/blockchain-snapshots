#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""
snapshot-extract.py - frame-parallel download + decode + write extractor.

The producer publishes snapshot.tar.zst (independent zstd frames) and
download-manifest.json, which lists frames[] (each frame's compressed and
uncompressed byte range) and members[] (each tar member's data range in the
decoded stream). This tool splits the frames into contiguous GROUPS and hands
each to a worker process. The worker reads the group's compressed span, decodes
it, and pwrites the file bytes straight to their offsets in pre-created output
files. Tar headers and padding are dropped by intersecting each decoded chunk
with the member table, so the result is byte-identical to a serial `tar -x`:
a decoded byte at global offset U is written iff some member M has
M.data_uoff <= U < M.data_uend, at file offset U - M.data_uoff.

Usage:
  snapshot-extract.py --index download-manifest.json --out /data/extract \\
      (--local FILE | --s3 BUCKET KEY [--region R] | --cmd TEMPLATE) \\
      [--workers 0] [--o-direct auto|on|off] [--retries 5] [--verbose]

Sources:
  --local  a file path, e.g. the artifact inside a mount-s3 mount
  --s3     ranged GETs with boto3 (no FUSE needed, so it works in containers)
  --cmd    run a download command per group and read its stdout

Debugging: decisions, warnings and progress go to stderr as JSON lines
({"status": "info"|"warn", "note": ...}); the result is one JSON line on
stdout. --verbose logs every finished group. A failure names the group, its
compressed byte span, and a hint.

Sections: 1 errors and logging, 2 manifest, 3 host resources, 4 output device
and O_DIRECT, 5 writers, 6 sources, 7 worker, 8 dispatch and main.
"""
import argparse
import bisect
import contextlib
import errno
import json
import math
import mmap
import os
import random
import sys
import tempfile
import time
import warnings

warnings.filterwarnings('ignore')  # silence boto3 py3.9 deprecation spam (1/worker)

try:
    import zstandard as zstd
except ImportError:
    sys.exit("ERROR: python 'zstandard' is required but not installed. "
             "Ubuntu 24.04: sudo apt-get install -y python3-zstandard; "
             "Ubuntu 22.04 / Amazon Linux: pip3 install 'zstandard>=0.22'.")


# ── 1. Errors and logging ────────────────────────────────────────────────────

class ExtractError(Exception):
    """An error with an operator-facing message. Not retried."""


class ManifestError(ExtractError):
    """The manifest is malformed or does not match the artifact."""


class WriteError(ExtractError):
    """Writing the output failed (disk full, I/O error, permissions)."""


class SourceError(ExtractError):
    """Reading the compressed bytes failed or ended early. Retried."""


class TruncatedGroup(SourceError):
    """The source ended before the group's frames were fully decoded."""


class GroupFailed(ExtractError):
    """A worker gave up on a group; the message says which, why, and what to do."""


def _log(note):
    """One JSON line on stderr. Notes starting with 'WARNING:' are tagged 'warn'."""
    status = 'warn' if note.startswith('WARNING:') else 'info'
    print(json.dumps({'status': status, 'note': note}), file=sys.stderr, flush=True)


def _gib(n):
    return 'unknown' if n is None else f'{n / 1024 ** 3:.1f} GiB'


# ── 2. Manifest: load, validate, plan groups ─────────────────────────────────

FRAME_KEYS = ('coff', 'clen', 'uoff', 'ulen')
MEMBER_KEYS = ('path', 'type', 'size', 'data_uoff', 'data_uend')


def load_manifest(path):
    """Parse download-manifest.json and check everything the workers rely on,
    so a bad manifest fails here with a clear message instead of as a KeyError
    or silently wrong output deep inside a worker."""
    try:
        with open(path) as f:
            manifest = json.load(f)
    except OSError as e:
        sys.exit(f"ERROR: cannot read manifest {path}: {e.strerror}")
    except ValueError as e:
        sys.exit(f"ERROR: manifest {path} is not valid JSON ({e}). Re-download it.")
    if not isinstance(manifest, dict):
        sys.exit(f"ERROR: manifest {path} is not a JSON object.")
    missing = [k for k in ('frames', 'members') if k not in manifest]
    if missing:
        sys.exit(f"ERROR: manifest {path} is missing required key(s): "
                 f"{', '.join(missing)}. It may be truncated or from an "
                 "incompatible producer version.")
    try:
        validate_manifest_layout(manifest['frames'], manifest['members'])
    except ManifestError as e:
        sys.exit(f"ERROR: manifest {path}: {e}")
    return manifest


def _require_keys(obj, keys, what):
    if not isinstance(obj, dict):
        raise ManifestError(f'{what} is not an object')
    missing = [k for k in keys if k not in obj]
    if missing:
        raise ManifestError(f'{what} is missing key(s): {", ".join(missing)}')


def validate_manifest_layout(frames, members):
    """Check the invariants the decode loop depends on (raises ManifestError):
      * consecutive frames are contiguous in compressed AND uncompressed space,
        so a run of frames is one byte span that decodes to exactly [uoff, uend);
      * member data ranges are in archive order and do not overlap (workers
        bisect on them), and lie inside the decoded stream (a member past the
        end would silently keep a zero-filled tail)."""
    for i, fr in enumerate(frames):
        _require_keys(fr, FRAME_KEYS, f'frame {i}')
        if fr['clen'] < 0 or fr['ulen'] < 0:
            raise ManifestError(f'frame {i} has a negative length')
        if i and (fr['coff'], fr['uoff']) != (frames[i - 1]['coff'] + frames[i - 1]['clen'],
                                              frames[i - 1]['uoff'] + frames[i - 1]['ulen']):
            raise ManifestError(f'frame {i} is not contiguous with frame {i - 1}')
    stream_end = frames[-1]['uoff'] + frames[-1]['ulen'] if frames else 0
    prev_end = 0
    for i, m in enumerate(members):
        _require_keys(m, MEMBER_KEYS, f'member {i}')
        ds, de = m['data_uoff'], m['data_uend']
        if de < ds or ds < prev_end:
            raise ManifestError(f'member {i} ({m["path"]!r}) has data range '
                                f'[{ds}, {de}) that is out of order or overlaps '
                                'the previous member')
        if de > stream_end:
            raise ManifestError(f'member {i} ({m["path"]!r}) ends at {de}, past the '
                                f'end of the decoded stream ({stream_end}); the '
                                'manifest does not match the artifact')
        prev_end = de


def _inside_output(out_root, candidate):
    """Return whether candidate resolves to out_root or one of its descendants."""
    try:
        return os.path.commonpath([out_root, candidate]) == out_root
    except ValueError:
        return False


def validate_manifest_members(members, out_root):
    """Reject member paths and symlink targets that escape the output root."""
    for member in members:
        path = member['path']
        if os.path.isabs(path):
            sys.exit(f"ERROR: manifest member has absolute path (refusing): {path!r}")
        resolved = os.path.realpath(os.path.join(out_root, path))
        if not _inside_output(out_root, resolved):
            sys.exit(f"ERROR: manifest member escapes output dir (refusing): {path!r}")

        if member.get('type') == '2':
            linkname = member.get('linkname', '')
            if os.path.isabs(linkname):
                sys.exit(
                    "ERROR: manifest symlink has absolute target "
                    f"(refusing): {linkname!r}"
                )
            symlink_parent = os.path.dirname(os.path.join(out_root, path))
            link_resolved = os.path.realpath(os.path.join(symlink_parent, linkname))
            if not _inside_output(out_root, link_resolved):
                sys.exit(
                    "ERROR: manifest symlink target escapes output dir "
                    f"(refusing): {linkname!r}"
                )


def build_groups(frames, n_groups):
    """Split frames into n_groups CONTIGUOUS runs of near-UNIFORM size.
    Each run is one contiguous compressed byte-span (frames are adjacent in the
    file), so a worker streams it as ONE sequential range read - no seeking.

    Balance target = UNCOMPRESSED bytes (the real decode+write work), not
    compressed, since zstd ratio varies per frame. Frame i goes to group
    floor(cum_before_i / total * n_groups): this spreads the remainder evenly
    across ALL groups instead of the greedy "overshoot-then-cut" that dumped a
    tiny leftover into the last group (measured 74% span imbalance, an 18%
    straggler). With one group per worker and no work-stealing, the slowest
    group IS the wall clock, so uniformity matters."""
    total_u = sum(fr['ulen'] for fr in frames) or 1
    n_groups = max(1, min(n_groups, len(frames)))
    buckets = [[] for _ in range(n_groups)]
    cum = 0
    for fr in frames:
        gi = min((cum * n_groups) // total_u, n_groups - 1)  # where this frame STARTS
        buckets[gi].append(fr)
        cum += fr['ulen']
    out = []
    for g in (b for b in buckets if b):  # drop empty buckets (tiny tail cases)
        coff = g[0]['coff']
        cend = g[-1]['coff'] + g[-1]['clen']
        out.append({'coff': coff, 'clen': cend - coff,
                    'uoff': g[0]['uoff'], 'uend': g[-1]['uoff'] + g[-1]['ulen']})
    return out


S3_SPAN_BYTES = 1 << 30  # --s3: compressed bytes per ranged GET (one group)


def plan_group_count(requested, workers, frames, source):
    """How many contiguous spans to cut.
    Default: one per worker - one long sequential read each, the measured
    optimum with mountpoint-s3 (smaller spans reset its prefetch).
    --s3: also cap spans at ~1 GiB. A dropped connection then costs at most
    ~1 GiB of re-download, and workers that finish early take the remaining
    spans instead of idling."""
    if requested > 0:
        return requested
    if source == 's3':
        total_c = sum(fr['clen'] for fr in frames)
        return max(workers, math.ceil(total_c / S3_SPAN_BYTES))
    return workers


def _is_regular(member):
    return member['type'] in ('0', '\0', '')


def prepare_output_tree(members, out_dir, out_root):
    """Create directories and symlinks, and every regular file at its final
    size (posix_fallocate where available), so workers can pwrite into place."""
    skipped, failed_links = [], []
    for m in members:
        path, t = m['path'], m['type']
        full = os.path.join(out_dir, path)
        # Directory if: dir typeflag, trailing slash, or the archive's "./"
        # entry (some tar variants store it with typeflag '0'/'' instead of '5').
        if t == '5' or path.endswith('/') or os.path.realpath(full) == out_root:
            os.makedirs(os.path.normpath(full), exist_ok=True)
            continue
        os.makedirs(os.path.dirname(full), exist_ok=True)
        if _is_regular(m):
            _create_sized_file(full, m)
        elif t == '2':
            try:
                if not os.path.lexists(full):
                    os.symlink(m['linkname'], full)
            except OSError as e:
                failed_links.append(f'{path}: {e.strerror}')
        else:
            skipped.append(path)  # hardlink, device, fifo
    if skipped:
        _log(f'WARNING: skipped {len(skipped)} member(s) of unsupported type '
             f'(hardlink/device/fifo), e.g. {skipped[0]!r}')
    if failed_links:
        _log(f'WARNING: could not create {len(failed_links)} symlink(s), '
             f'e.g. {failed_links[0]}')


def _create_sized_file(full, m):
    if os.path.isdir(full):  # never open an existing directory as a file
        return
    # Always owner-writable while extracting: workers reopen the file to write
    # (a read-only member would fail for non-root). restore_modes() fixes it.
    mode = (m.get('mode', 0o644) or 0o644) | 0o200
    try:
        fd = os.open(full, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
        try:
            if m['size'] > 0:
                # posix_fallocate reserves blocks (Linux); ftruncate sets the
                # size everywhere else. Either gives pwrite a sized file.
                if hasattr(os, 'posix_fallocate'):
                    os.posix_fallocate(fd, 0, m['size'])
                else:
                    os.ftruncate(fd, m['size'])
        finally:
            os.close(fd)
    except OSError as e:
        sys.exit(f"ERROR: cannot create {full} ({m['size']} bytes): {e.strerror}. "
                 "Check free space and permissions of --out.")


def restore_modes(members, out_dir):
    """Give read-only members their archive mode (umask applied, as tar -x
    does for non-root) now that all bytes are written."""
    umask = os.umask(0)
    os.umask(umask)
    for m in members:
        mode = m.get('mode', 0o644) or 0o644
        full = os.path.join(out_dir, m['path'])
        if (_is_regular(m) and not mode & 0o200
                and os.path.isfile(full) and not os.path.islink(full)):
            os.chmod(full, mode & ~umask)


# ── 3. Host resources: CPUs and memory, container-aware ──────────────────────
#
# os.cpu_count() and /proc/meminfo describe the whole HOST. In a container
# (docker --cpus/--memory, Kubernetes limits, ECS task sizes) the process gets
# much less, and sizing from host numbers is how an extract gets OOM-killed or
# throttled. Both readers take the minimum of the host view and the cgroup
# limits (v2, with a v1 fallback).

CGROUP_ROOT = '/sys/fs/cgroup'
PROC_CGROUP = '/proc/self/cgroup'
_V1_UNLIMITED = 1 << 60  # cgroup v1 reports "no limit" as a huge number


def _read_text(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def _read_int(path):
    try:
        return int(_read_text(path))
    except (TypeError, ValueError):  # missing, or "max"
        return None


def _cgroup_dirs(root=CGROUP_ROOT, proc_cgroup=PROC_CGROUP):
    """This process's cgroup v2 directory and its ancestors, most specific
    first (a limit set on any ancestor applies too). In a container with its
    own cgroup namespace this is just the root."""
    rel = '/'
    for line in (_read_text(proc_cgroup) or '').splitlines():
        if line.startswith('0::'):
            rel = line[3:] or '/'
            break
    d = os.path.normpath(os.path.join(root, rel.lstrip('/')))
    dirs = [d]
    while d != root and d.startswith(root + os.sep):
        d = os.path.dirname(d)
        dirs.append(d)
    return dirs


def _cgroup_cpu_limit(root=CGROUP_ROOT, proc_cgroup=PROC_CGROUP):
    """CPU quota in CPUs (2.5 for --cpus=2.5), or None when unlimited."""
    limits = []
    for d in _cgroup_dirs(root, proc_cgroup):
        quota, _, period = (_read_text(os.path.join(d, 'cpu.max')) or '').partition(' ')
        if quota.isdigit() and period.isdigit() and int(period):
            limits.append(int(quota) / int(period))
    for v1 in ('cpu', 'cpu,cpuacct'):
        quota = _read_int(os.path.join(root, v1, 'cpu.cfs_quota_us'))  # -1 = none
        period = _read_int(os.path.join(root, v1, 'cpu.cfs_period_us'))
        if quota and quota > 0 and period:
            limits.append(quota / period)
    return min(limits) if limits else None


def _cgroup_mem_headroom(root=CGROUP_ROOT, proc_cgroup=PROC_CGROUP):
    """Bytes left under the tightest cgroup memory limit (limit - usage), or
    None when no limit applies. Conservative: page cache counts as used."""
    room = []
    for d in _cgroup_dirs(root, proc_cgroup):
        limit = _read_int(os.path.join(d, 'memory.max'))
        usage = _read_int(os.path.join(d, 'memory.current'))
        if limit is not None and usage is not None:
            room.append(max(0, limit - usage))
    limit = _read_int(os.path.join(root, 'memory', 'memory.limit_in_bytes'))
    usage = _read_int(os.path.join(root, 'memory', 'memory.usage_in_bytes'))
    if limit is not None and usage is not None and limit < _V1_UNLIMITED:
        room.append(max(0, limit - usage))
    return min(room) if room else None


def _host_mem_available():
    """MemAvailable from /proc/meminfo in bytes, or None (not Linux)."""
    for line in (_read_text('/proc/meminfo') or '').splitlines():
        if line.startswith('MemAvailable:'):
            return int(line.split()[1]) * 1024  # kB -> B
    return None


def _mem_available_bytes():
    """Memory this process can still use: min(host MemAvailable, cgroup
    headroom). None when unknown (e.g. macOS)."""
    known = [v for v in (_host_mem_available(), _cgroup_mem_headroom()) if v is not None]
    return min(known) if known else None


def _available_cpus():
    """CPUs this process may use: its affinity mask (taskset, cpusets), cut
    further by a cgroup CPU quota (docker --cpus). Else os.cpu_count()."""
    try:
        cpus = len(os.sched_getaffinity(0))
    except (AttributeError, OSError):  # not Linux
        cpus = os.cpu_count() or 1
    quota = _cgroup_cpu_limit()
    if quota:
        cpus = min(cpus, max(1, math.ceil(quota)))
    return cpus


MAX_AUTO_WORKERS = 96  # measured mountpoint-s3 sweet spot: 128 and 192 halved net

# Peak memory of one worker, rounded up about 2x for headroom:
#   16 MiB decoded chunk (segments are memoryviews into it, not copies)
#   128 MiB zstd window (artifacts are compressed with --long=27)
#   2 x 8 MiB O_DIRECT staging buffers (a writer is released when its file ends)
#   ~60-80 MiB interpreter + boto3
# The earlier 8 GiB/worker figure came from a leak, not real need: each
# O_DIRECT writer kept its 8 MiB buffer until the GROUP ended, so ~1,700 files
# per worker held the 19-20 GB of shmem seen before the OOM kill.
WORKER_MEM_BYTES = 512 * 1024 ** 2
MEM_BUDGET_FRACTION = 0.75  # the rest is for mount-s3 prefetch and page cache


def choose_workers(requested):
    """Resolve the worker count -> (workers, note).
    0/negative = auto = min(available CPUs, 96). Any count, auto or explicit,
    is then capped so workers x WORKER_MEM_BYTES fits in 75% of the memory
    this process can use (container limits included)."""
    cpus = _available_cpus()
    workers = requested if requested and requested > 0 else min(cpus, MAX_AUTO_WORKERS)
    note = None
    avail = _mem_available_bytes()
    if avail:
        mem_cap = max(1, int(avail * MEM_BUDGET_FRACTION // WORKER_MEM_BYTES))
        if mem_cap < workers:
            note = (f'capped {workers}->{mem_cap} workers to fit memory '
                    f'({_gib(avail)} available, ~{WORKER_MEM_BYTES // 1024 ** 2} MiB '
                    'per worker)')
            workers = mem_cap
    return workers, note


# ── 4. Output device and O_DIRECT ────────────────────────────────────────────

ALIGN = 4096  # O_DIRECT needs offset, length and buffer address aligned to this
_O_DIRECT = getattr(os, 'O_DIRECT', 0)  # 0 where the platform lacks it (macOS)


def _is_rotational_or_ebs(out_dir):
    """Best-effort: is out_dir NOT on local instance-store NVMe? True for EBS
    and for anything we cannot classify (the safe default: buffered writes).

    findmnt gives the backing device; lsblk -s lists the models of it and of
    every disk under it (md RAID-0 and partitions have no model of their own).
    Instance store reports 'Amazon EC2 NVMe Instance Storage', EBS 'Amazon
    Elastic Block Store'. A container usually cannot see the host's block
    devices, so this returns True there; pass --o-direct on if you know better."""
    import subprocess
    try:
        src = subprocess.run(['findmnt', '-no', 'SOURCE', '--target', out_dir],
                             capture_output=True, text=True, timeout=10)
        words = src.stdout.split()
        dev = words[0].split('[', 1)[0] if words else ''  # bind mount: /dev/md0[/sub]
        if not dev.startswith('/dev/'):
            return True  # overlay, tmpfs, nfs, ...
        info = subprocess.run(['lsblk', '-s', '-no', 'MODEL', dev],
                              capture_output=True, text=True, timeout=10)
        models = info.stdout.lower()
        return not ('instance storage' in models and 'elastic block store' not in models)
    except (OSError, subprocess.SubprocessError):
        return True


def probe_o_direct(out_dir):
    """Try one aligned O_DIRECT write in out_dir: None if it works, else why.
    Filesystems without O_DIRECT (ramfs; tmpfs before Linux 6.6) fail with
    EINVAL at open or at the first write. macOS has no O_DIRECT at all."""
    if not _O_DIRECT:
        return 'this platform has no O_DIRECT'
    path = fd = buf = None
    try:
        tmp_fd, path = tempfile.mkstemp(prefix='.odirect-probe-', dir=out_dir)
        os.close(tmp_fd)
        fd = os.open(path, os.O_WRONLY | _O_DIRECT)
        buf = mmap.mmap(-1, ALIGN, flags=mmap.MAP_PRIVATE)  # page-aligned
        os.pwrite(fd, buf, 0)
        return None
    except OSError as e:
        return f'{errno.errorcode.get(e.errno, e.errno)}: {e.strerror}'
    finally:
        if buf is not None:
            buf.close()
        if fd is not None:
            os.close(fd)
        if path is not None:
            with contextlib.suppress(OSError):
                os.unlink(path)


def resolve_o_direct(mode, out_dir):
    """mode 'on' | 'off' | 'auto' -> (enabled, note).
    auto = on only for instance-store NVMe, where many workers writing one big
    file gain from skipping the per-inode buffered-write lock. On EBS the volume
    throughput is the cap and buffered writes already reach it.
    When O_DIRECT is wanted but the output filesystem rejects it, fall back to
    buffered writes with a WARNING rather than failing mid-extract."""
    if mode == 'off':
        return False, 'O_DIRECT forced off (buffered writes)'
    if mode == 'on':
        why = 'O_DIRECT forced on'
    elif _is_rotational_or_ebs(out_dir):
        return False, 'auto: buffered writes (output is EBS/unknown; O_DIRECT off)'
    else:
        why = 'auto: O_DIRECT on (output is instance-store NVMe)'
    problem = probe_o_direct(out_dir)
    if problem:
        return False, (f'WARNING: {why}, but {out_dir} does not support O_DIRECT '
                       f'({problem}); falling back to buffered writes')
    return True, why


# ── 5. Writers ───────────────────────────────────────────────────────────────
#
# One writer per output file per group, all with the same interface:
#   write(file_off, data)   segments arrive in order and contiguous
#   finish() -> [(offset, bytes)]   flush; return edge fragments for the parent
#   abort()                 release without writing more (used on errors)
# A worker releases a writer as soon as its file's last byte is written, so it
# holds at most a couple at a time however many files a group covers.

WRITER_BUF_BYTES = 8 * 1024 * 1024  # O_DIRECT staging buffer, multiple of ALIGN


def _open_for_write(path, flags=0):
    try:
        return os.open(path, os.O_WRONLY | flags)
    except OSError as e:
        raise WriteError(f'cannot open {path} for writing: {e.strerror}') from e


def _pwrite_all(fd, data, offset, path):
    """pwrite every byte of data at offset (pwrite may write less than asked)."""
    view = memoryview(data)
    try:
        while view:
            n = os.pwrite(fd, view, offset)
            if n <= 0:
                raise OSError(errno.EIO, 'pwrite wrote nothing')
            view, offset = view[n:], offset + n
    except OSError as e:
        raise WriteError(f'writing {path} at offset {offset}: {e.strerror}') from e


class BufferedWriter:
    """Plain pwrite() through the page cache (the default)."""

    def __init__(self, path):
        self.path = path
        self.fd = _open_for_write(path)

    def write(self, file_off, data):
        _pwrite_all(self.fd, data, file_off, self.path)

    def finish(self):
        self.abort()
        return []

    def abort(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


class DirectWriter:
    """O_DIRECT writer. O_DIRECT needs the file offset, the length and the
    buffer address aligned to ALIGN, so the bytes are split three ways:
      head  bytes before the first ALIGN boundary  -> edge fragment
      body  whole blocks, staged in a page-aligned buffer and written with
            O_DIRECT (XFS then takes the inode lock SHARED, so many workers
            writing one big file such as mdbx.dat scale)
      tail  bytes after the last ALIGN boundary    -> edge fragment
    Edge fragments go back to the parent, which writes them one at a time
    after every worker is done: two groups that meet inside one block would
    otherwise race on it (buffered read-modify-write -> torn block). Body
    blocks never overlap edge blocks, so the two kinds of write never touch
    the same block."""

    def __init__(self, path, buf_bytes=WRITER_BUF_BYTES):
        self.path = path
        self.fd = _open_for_write(path, _O_DIRECT)
        # Anonymous PRIVATE mapping: page-aligned as O_DIRECT needs, counted as
        # ordinary anonymous memory, and returned to the OS by abort().
        self.buf = mmap.mmap(-1, buf_bytes, flags=mmap.MAP_PRIVATE)
        self.view = memoryview(self.buf)
        self.cap = buf_bytes
        self.fill = 0          # bytes staged in buf
        self.buf_off = None    # file offset of buf[0]; ALIGN-aligned once set
        self.cursor = None     # file offset the next write must start at
        self.head_off = None   # file offset of the head fragment
        self.head = bytearray()

    def write(self, file_off, data):
        if self.cursor is None:
            self.cursor = file_off
        if file_off != self.cursor:
            raise ExtractError(f'internal error: non-contiguous write to {self.path} '
                               f'(offset {file_off}, expected {self.cursor})')
        mv = memoryview(data)
        if self.buf_off is None and self.cursor % ALIGN:  # still in the head block
            if self.head_off is None:
                self.head_off = self.cursor
            take = min(ALIGN - self.cursor % ALIGN, len(mv))
            self.head += mv[:take]
            self.cursor += take
            mv = mv[take:]
        while mv:  # from here on the body starts on an ALIGN boundary
            if self.buf_off is None:
                self.buf_off = self.cursor
            take = min(self.cap - self.fill, len(mv))
            self.view[self.fill:self.fill + take] = mv[:take]
            self.fill += take
            self.cursor += take
            mv = mv[take:]
            if self.fill == self.cap:
                _pwrite_all(self.fd, self.view, self.buf_off, self.path)
                self.buf_off += self.cap
                self.fill = 0

    def finish(self):
        """Write the staged whole blocks; return the edge fragments."""
        frags = []
        if self.head:
            frags.append((self.head_off, bytes(self.head)))
        whole = self.fill - self.fill % ALIGN
        if whole:
            _pwrite_all(self.fd, self.view[:whole], self.buf_off, self.path)
        if self.fill > whole:
            frags.append((self.buf_off + whole, bytes(self.view[whole:self.fill])))
        self.abort()
        return frags

    def abort(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
            self.view.release()
            self.buf.close()


def write_edge_fragments(results):
    """O_DIRECT only: write the head/tail pieces the workers returned, one file
    at a time (open, write, fsync, close), so a snapshot with thousands of
    files never runs into the open-files limit (1024 in many containers).
    Returns how many pieces were written."""
    by_path = {}
    for r in results:
        for path, off, data in r['edge_frags']:
            by_path.setdefault(path, []).append((off, data))
    count = 0
    for path, frags in by_path.items():
        try:
            fd = _open_for_write(path)
            try:
                for off, data in frags:
                    _pwrite_all(fd, data, off, path)
                os.fsync(fd)
            finally:
                os.close(fd)
        except (WriteError, OSError) as e:
            sys.exit(f"ERROR: writing O_DIRECT edge fragments failed: {e}")
        count += len(frags)
    return count


# ── 6. Sources: where a group's compressed bytes come from ───────────────────

class _Bounded:
    """Read-only wrapper that stops after n bytes (a group's span of a stream)."""

    def __init__(self, f, n):
        self.f = f
        self.left = n

    def read(self, size=-1):
        if self.left <= 0:
            return b''
        if size < 0 or size > self.left:
            size = self.left
        data = self.f.read(size)
        self.left -= len(data)
        return data


@contextlib.contextmanager
def _open_group_source(grp):
    """Yield a reader of exactly the group's compressed span [coff, coff+clen):
    a ranged S3 GET, a slice of a local (or mount-s3) file, or the stdout of a
    download command. Whether ALL bytes arrived is checked by the caller."""
    job = _W['job']
    coff, clen = grp['coff'], grp['clen']
    if job['source'] == 's3':
        body = _W['s3'].get_object(Bucket=job['bucket'], Key=job['key'],
                                   Range=f'bytes={coff}-{coff + clen - 1}')['Body']
        try:
            yield body
        finally:
            body.close()
    elif job['source'] == 'cmd':
        import shlex
        import subprocess
        cmd = job['cmd_tmpl'].format(coff=coff, cend=coff + clen - 1, clen=clen)
        # stderr is inherited so the downloader's own errors stay visible. Its
        # exit status is not checked: tools like `aws s3api get-object
        # ... /dev/stdout` print JSON after the body and fail on the closed
        # pipe; completeness is judged by the byte count instead.
        proc = subprocess.Popen(shlex.split(cmd), stdout=subprocess.PIPE)
        try:
            yield _Bounded(proc.stdout, clen)
        finally:
            proc.stdout.close()
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
    else:
        with open(job['local_path'], 'rb') as f:
            f.seek(coff)
            yield _Bounded(f, clen)


# ── 7. Worker: decode one group, retry transient source errors ───────────────

DECODE_CHUNK = 16 * 1024 * 1024
RETRY_BASE_S = 1.0
RETRY_CAP_S = 30.0
_TRANSIENT_S3_CODES = {'SlowDown', 'Throttling', 'ThrottlingException', 'RequestTimeout',
                       'InternalError', 'ServiceUnavailable', 'RequestLimitExceeded'}

_W = {}  # per-process worker state, set by _init


def _init(job):
    """Worker initializer: index the members; open one S3 client per process."""
    random.seed()  # forked workers share the parent's state; de-sync retry jitter
    _W['job'] = job
    _W['members'] = job['members']
    _W['starts'] = [m['data_uoff'] for m in job['members']]
    if job['source'] == 's3':
        import boto3
        from botocore.config import Config
        # Adaptive retries (exponential backoff with jitter plus client-side
        # rate limiting) cover the initial GET. A drop mid-body is not retried
        # by botocore; _process_group retries the whole group for that.
        _W['s3'] = boto3.client('s3', region_name=job['region'],
                                endpoint_url=_s3_endpoint_url(),
                                config=Config(max_pool_connections=8,
                                              connect_timeout=10, read_timeout=60,
                                              retries={'max_attempts': 6,
                                                       'mode': 'adaptive'}))


def _s3_endpoint_url():
    """A custom S3 endpoint (S3-compatible store, VPC interface endpoint) from
    the standard AWS variables. boto3 >= 1.28 reads them itself; passing them
    explicitly makes older distro boto3 (Ubuntu 22.04 ships 1.20) agree with
    the AWS CLI. None = the regular regional endpoint."""
    return os.environ.get('AWS_ENDPOINT_URL_S3') or os.environ.get('AWS_ENDPOINT_URL') or None


def _new_writer(rel_path):
    full = os.path.join(_W['job']['out_dir'], rel_path)
    return DirectWriter(full) if _W['job']['direct'] else BufferedWriter(full)


def _write_chunk(chunk, b_start, writers, frags):
    """Write the parts of one decoded chunk that belong to member files.
    chunk holds global uncompressed bytes [b_start, b_start + len(chunk)).
    Returns the number of file bytes written."""
    members, starts = _W['members'], _W['starts']
    b_end = b_start + len(chunk)
    view = memoryview(chunk)
    written = 0
    i = max(0, bisect.bisect_right(starts, b_start) - 1)  # last member starting <= b_start
    while i < len(members):
        m = members[i]
        ds, de = m['data_uoff'], m['data_uend']
        if ds >= b_end:
            break
        lo, hi = max(ds, b_start), min(de, b_end)
        if hi > lo:
            w = writers.get(i)
            if w is None:
                w = writers[i] = _new_writer(m['path'])
            w.write(lo - ds, view[lo - b_start:hi - b_start])
            written += hi - lo
            if hi == de:  # file complete: release its fd and buffer right away
                frags.extend((w.path, off, data) for off, data in writers.pop(i).finish())
        i += 1
    return written


def _extract_group(grp):
    """One attempt: decode the group and write the file bytes it contains.
    Returns stats and the O_DIRECT edge fragments; raises on any error."""
    t0 = time.monotonic()
    uoff, uend = grp['uoff'], grp['uend']
    writers = {}  # member index -> open writer
    frags = []    # (path, offset, bytes) for the parent to write afterwards
    pos = uoff    # global uncompressed offset of the next decoded byte
    written = 0
    try:
        with _open_group_source(grp) as src:
            reader = zstd.ZstdDecompressor().stream_reader(src, read_across_frames=True)
            while True:
                chunk = reader.read(DECODE_CHUNK)
                if not chunk:
                    break
                written += _write_chunk(chunk, pos, writers, frags)
                pos += len(chunk)
        # python-zstandard does not raise when its input stops mid-frame; it
        # just returns fewer bytes. The manifest says exactly how many to expect.
        if pos < uend:
            raise TruncatedGroup(f'source ended early: decoded {pos - uoff} of '
                                 f'{uend - uoff} bytes')
        if pos > uend:
            raise ManifestError(f'decoded {pos - uend} bytes more than the manifest '
                                'declares for this span')
        for i in list(writers):  # files that continue into the next group
            w = writers.pop(i)
            frags.extend((w.path, off, data) for off, data in w.finish())
    finally:
        for w in writers.values():
            w.abort()
    return {'written': written, 'seconds': round(time.monotonic() - t0, 1),
            'uoff': uoff, 'ubytes': uend - uoff, 'edge_frags': frags}


def _s3_error_code(exc):
    """The S3 error code of a botocore ClientError, else None."""
    response = getattr(exc, 'response', None)
    if isinstance(response, dict) and 'Error' in response:
        return str(response['Error'].get('Code', ''))
    return None


def _is_zstd_error(exc):
    zstd_error = getattr(zstd, 'ZstdError', None)
    return zstd_error is not None and isinstance(exc, zstd_error)


def _is_network_error(exc):
    """botocore/urllib3 transport errors: resets, timeouts, broken streams."""
    try:
        from botocore import exceptions as bce
        from urllib3 import exceptions as u3e
    except ImportError:
        return False
    return isinstance(exc, (bce.HTTPClientError, bce.ConnectionError,
                            bce.IncompleteReadError, u3e.HTTPError))


def _is_transient(exc):
    """Is a failed group worth retrying? Only for trouble a fresh read can fix:
    data ending early, network/S3 hiccups, I/O errors reading a mount-s3 file.
    Bad data, a bad manifest, output errors and 4xx responses are permanent."""
    if isinstance(exc, SourceError):
        return True
    if isinstance(exc, ExtractError) or _is_zstd_error(exc):
        return False
    code = _s3_error_code(exc)
    if code is not None:
        status = exc.response.get('ResponseMetadata', {}).get('HTTPStatusCode') or 0
        return status >= 500 or code in _TRANSIENT_S3_CODES
    if isinstance(exc, (FileNotFoundError, PermissionError,
                        IsADirectoryError, NotADirectoryError)):
        return False
    if isinstance(exc, OSError):  # EIO from mount-s3, connection reset, timeout
        return True
    return _is_network_error(exc)


def _hint(exc):
    """One line of operator guidance for a group that failed for good."""
    code = _s3_error_code(exc)
    if isinstance(exc, WriteError):
        return 'Check free space and health of the --out filesystem.'
    if isinstance(exc, TruncatedGroup):
        return 'The download kept getting cut short; check network/S3 reachability and re-run.'
    if _is_zstd_error(exc) or isinstance(exc, ManifestError):
        return ('The compressed data does not match the manifest (corrupt or '
                'republished artifact). Re-fetch the manifest and re-run.')
    if code in ('AccessDenied', '403'):
        return 'Access denied: check the IAM role (s3:GetObject) and the S3 VPC endpoint.'
    if code in ('NoSuchKey', 'NoSuchBucket', '404'):
        return 'The artifact was not found: check the bucket, key and region.'
    if isinstance(exc, (FileNotFoundError, PermissionError)):
        return 'Check the --local path and its permissions.'
    return 'Re-run; if it persists, re-run with --verbose and check the error above.'


def _process_group(gi, n_groups, grp):
    """Pool task: extract group gi, retrying transient source errors with
    capped exponential backoff and full jitter. Retrying is safe: every write
    is a pwrite at a fixed offset and groups start on frame boundaries, so an
    attempt rewrites the same bytes. Raises GroupFailed with a full message."""
    label = (f'group {gi + 1}/{n_groups} (compressed bytes '
             f'{grp["coff"]}-{grp["coff"] + grp["clen"] - 1})')
    attempts = max(1, _W['job']['retries'])
    for attempt in range(1, attempts + 1):
        try:
            result = _extract_group(grp)
            result['attempts'] = attempt
            return result
        except Exception as e:  # noqa: BLE001 - classified by _is_transient
            if attempt == attempts or not _is_transient(e):
                tried = f' after {attempt} attempts' if attempt > 1 else ''
                raise GroupFailed(f'{label}{tried}: {type(e).__name__}: {e}. '
                                  f'{_hint(e)}') from None
            delay = random.uniform(0, min(RETRY_CAP_S, RETRY_BASE_S * 2 ** (attempt - 1)))
            _log(f'WARNING: {label}: {type(e).__name__}: {e}; '
                 f'retry {attempt + 1}/{attempts} in {delay:.1f}s')
            time.sleep(delay)


# ── 8. Dispatch and main ─────────────────────────────────────────────────────

def _abort(ex):
    """Stop the pool after a failure: cancel queued groups, kill running ones
    (their output is incomplete anyway and the run is failing)."""
    if hasattr(ex, 'terminate_workers'):  # Python 3.14+
        ex.terminate_workers()
        return
    # Older Pythons: copy the private process table first, shutdown() clears it.
    procs = list((getattr(ex, '_processes', None) or {}).values())
    ex.shutdown(wait=False, cancel_futures=True)
    for p in procs:
        with contextlib.suppress(Exception):
            p.terminate()


def _dispatch(groups, workers, job, verbose=False):
    """Run every group on a process pool and return the results. Any failure
    aborts the run promptly with a non-zero exit:
      * a worker error (after its retries) -> its message, naming the group;
      * a worker killed outright (OOM killer, SIGKILL) -> BrokenProcessPool.

    concurrent.futures, NOT multiprocessing.Pool: when a Pool worker is
    SIGKILLed (the kernel OOM killer, as seen on the default EBS instance),
    Pool silently replaces it and the in-flight task is lost, so map()/imap()
    wait forever (verified live). ProcessPoolExecutor raises BrokenProcessPool
    instead, which becomes a clean non-zero exit."""
    from concurrent.futures import ProcessPoolExecutor, as_completed
    from concurrent.futures.process import BrokenProcessPool
    results = []
    ex = ProcessPoolExecutor(max_workers=workers, initializer=_init, initargs=(job,))
    try:
        futures = [ex.submit(_process_group, gi, len(groups), g)
                   for gi, g in enumerate(groups)]
        for fut in as_completed(futures):
            r = fut.result()  # re-raises the worker's exception here
            results.append(r)
            if verbose:
                retried = f', {r["attempts"]} attempts' if r['attempts'] > 1 else ''
                _log(f'group done ({len(results)}/{len(groups)}): '
                     f'{_gib(r["ubytes"])} in {r["seconds"]}s{retried}')
    except BrokenProcessPool:
        _abort(ex)
        sys.exit("ERROR: an extraction worker was killed (out of memory? check "
                 "`dmesg | grep -i oom` or the container's memory limit). Aborting "
                 "instead of hanging. Re-run with fewer --workers, or with "
                 "--o-direct off, or on a larger instance.")
    except GroupFailed as e:
        _abort(ex)
        sys.exit(f"ERROR: extraction worker failed on {e} Aborting.")
    except KeyboardInterrupt:
        _abort(ex)
        sys.exit("ERROR: interrupted; the output directory is incomplete.")
    except Exception as e:  # noqa: BLE001 - any other worker error aborts, not hangs
        _abort(ex)
        sys.exit(f"ERROR: extraction worker failed ({type(e).__name__}: {e}). Aborting.")
    ex.shutdown(wait=True)
    if len(results) != len(groups):
        sys.exit(f"ERROR: {len(groups) - len(results)} extraction group(s) did not "
                 "complete (worker died). Aborting.")
    return results


def _require_boto3():
    try:
        import boto3  # noqa: F401
    except ImportError:
        sys.exit("ERROR: --s3 needs python 'boto3'. Ubuntu: sudo apt-get install -y "
                 "python3-boto3; Amazon Linux: pip3 install boto3. (Or read the "
                 "artifact through a mount-s3 mount with --local.)")


def parse_args(argv=None):
    ap = argparse.ArgumentParser(
        description='Parallel, manifest-driven extract of a multi-frame .tar.zst.')
    ap.add_argument('--index', required=True, help='download-manifest.json')
    ap.add_argument('--out', required=True, help='output directory (created if missing)')
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument('--local', metavar='FILE',
                     help='read the artifact from a path (e.g. inside a mount-s3 mount)')
    src.add_argument('--s3', nargs=2, metavar=('BUCKET', 'KEY'),
                     help='read the artifact with ranged S3 GETs (boto3; no FUSE)')
    src.add_argument('--cmd', dest='cmd_tmpl', metavar='TEMPLATE',
                     help='run this command per group and read its stdout; '
                          '{coff}/{cend}/{clen} are filled in, e.g. '
                          '"aws s3api get-object --bucket B --key K '
                          '--range bytes={coff}-{cend} /dev/stdout"')
    ap.add_argument('--region', default='us-east-1', help='S3 region for --s3')
    ap.add_argument('--workers', type=int, default=0,
                    help='worker processes (0 = available CPUs, max 96: more '
                         'concurrent mountpoint-s3 streams measured slower). '
                         'Always capped to fit available memory.')
    ap.add_argument('--groups', type=int, default=0,
                    help='contiguous spans to split into (0 = one per worker; '
                         'with --s3 also at most ~1 GiB each). For experiments.')
    ap.add_argument('--o-direct', dest='o_direct', nargs='?', const='on',
                    default='auto', choices=['on', 'off', 'auto'],
                    help="'on' (bypass the page cache so writers to one big file "
                         "scale), 'off' (buffered), or 'auto' (default: on for "
                         "instance-store NVMe). Falls back to buffered if the "
                         "filesystem rejects O_DIRECT. Bare --o-direct = on.")
    ap.add_argument('--retries', type=int, default=5,
                    help='attempts per group on transient source errors (default 5)')
    ap.add_argument('--verbose', action='store_true', help='log every finished group')
    ap.add_argument('--steal', action='store_true', help=argparse.SUPPRESS)  # no-op, kept for old callers
    return ap.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    t0 = time.monotonic()

    # The manifest is untrusted input: check its shape, then every path and
    # symlink target, before creating anything.
    manifest = load_manifest(args.index)
    members, frames = manifest['members'], manifest['frames']
    os.makedirs(args.out, exist_ok=True)
    out_root = os.path.realpath(args.out)
    validate_manifest_members(members, out_root)

    if args.cmd_tmpl:
        source, source_desc = 'cmd', f'command {args.cmd_tmpl!r}'
    elif args.s3:
        source, source_desc = 's3', f's3://{args.s3[0]}/{args.s3[1]} ({args.region})'
        _require_boto3()
    else:
        source, source_desc = 'local', args.local

    o_direct, od_note = resolve_o_direct(args.o_direct, out_root)
    workers, w_note = choose_workers(args.workers)
    groups = build_groups(frames, plan_group_count(args.groups, workers, frames, source)) \
        if frames else []
    workers = max(1, min(workers, len(groups)))  # no idle processes
    for note in (od_note, w_note):
        if note:
            _log(note)
    _log(f'plan: read {source_desc}; {len(frames)} frames in {len(groups)} groups on '
         f'{workers} workers (cpus={_available_cpus()}, memory available '
         f'{_gib(_mem_available_bytes())}); {"O_DIRECT" if o_direct else "buffered"} '
         f'writes to {out_root}; retries={args.retries}')

    prepare_output_tree(members, args.out, out_root)
    job = {'members': members, 'out_dir': args.out, 'source': source,
           'local_path': args.local, 'cmd_tmpl': args.cmd_tmpl,
           'bucket': args.s3[0] if args.s3 else None,
           'key': args.s3[1] if args.s3 else None, 'region': args.region,
           'direct': o_direct, 'retries': args.retries}
    results = _dispatch(groups, workers, job, args.verbose) if groups else []
    edge_count = write_edge_fragments(results)
    restore_modes(members, args.out)
    dur = time.monotonic() - t0

    total_written = sum(r['written'] for r in results)
    times = sorted((r['seconds'] for r in results), reverse=True)
    print(json.dumps({
        'status': 'ok', 'source': source, 'workers': workers, 'groups': len(groups),
        'bytes_written': total_written, 'seconds': round(dur, 1),
        'write_MBps': round(total_written / 1048576 / dur, 0) if dur else 0,
        # worker imbalance: if max >> median, work is lopsided (e.g. one big file)
        'slowest_worker_s': times[0] if times else 0,
        'median_worker_s': times[len(times) // 2] if times else 0,
        'top5_worker_s': times[:5],
        'o_direct': o_direct, 'edge_frags': edge_count,
        'retries': sum(r['attempts'] - 1 for r in results),
    }))


if __name__ == '__main__':
    main()
