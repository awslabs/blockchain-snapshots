#!/usr/bin/env python3
"""
snapshot-extract.py — frame-parallel download + decode + pwrite extractor.

Reads download-manifest.json (frames[] + members[]). Partitions frames into G
groups (contiguous frame runs = contiguous uncompressed regions). G worker
processes each: range-GET their compressed span from S3 (or read local file),
decode their frames independently, and pwrite the decoded file-data bytes to the
correct offsets in pre-created output files. Tar header/padding bytes are
discarded by interval intersection against the member table.

Correct by construction: a decoded byte at global uoffset U is written IFF
some member M has M.data_uoff <= U < M.data_uend, at file offset U-M.data_uoff.

Usage:
  snapshot-extract.py --index download-manifest.json --out /data/out \
     [--workers 0] (--s3 BUCKET KEY [--region r] | --local FILE.tar.zst)
"""
import argparse
import bisect
import json
import multiprocessing as mp
import os
import sys
import warnings

warnings.filterwarnings('ignore')  # silence boto3 py3.9 deprecation spam (1/worker)

try:
    import zstandard as zstd
except ImportError:
    sys.exit("ERROR: pip install zstandard")


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
    file), so a worker streams it as ONE sequential range read — no seeking.

    Balance target = UNCOMPRESSED bytes (the real decode+write work), not
    compressed, since zstd ratio varies per frame. We assign frame i to group
    floor(cum_before_i / total * n_groups): this spreads the remainder evenly
    across ALL groups instead of the greedy "overshoot-then-cut" that dumped a
    tiny leftover into the last group (measured 74% span imbalance, an 18%
    straggler that set the wall-clock under pool.map). With work === groups and
    no work-stealing, the slowest group IS the wall, so uniformity matters."""
    real = frames  # include skippable; their clen keeps coff exact
    total_u = sum(fr['ulen'] for fr in real) or 1
    n_groups = max(1, min(n_groups, len(real)))
    buckets = [[] for _ in range(n_groups)]
    cum = 0
    for fr in real:
        # place this frame by where its START falls in the cumulative work axis
        gi = (cum * n_groups) // total_u
        if gi >= n_groups:
            gi = n_groups - 1
        buckets[gi].append(fr)
        cum += fr['ulen']
    groups = [b for b in buckets if b]  # drop any empty bucket (tiny tail cases)
    out = []
    for g in groups:
        coff = g[0]['coff']
        cend = g[-1]['coff'] + g[-1]['clen']
        uoff = g[0]['uoff']
        uend = g[-1]['uoff'] + g[-1]['ulen']
        out.append({'coff': coff, 'clen': cend - coff, 'uoff': uoff, 'uend': uend})
    return out


# Worker globals (set per process)
_W = {}


def _init(members, out_dir, mode, s3_args, local_path, direct=False, cmd_tmpl=None):
    # member data intervals sorted by data_uoff for bisect
    starts = [m['data_uoff'] for m in members]
    _W['members'] = members
    _W['starts'] = starts
    _W['out_dir'] = out_dir
    _W['mode'] = mode
    _W['local_path'] = local_path
    _W['direct'] = direct
    _W['cmd_tmpl'] = cmd_tmpl
    if mode == 's3':
        import boto3
        from botocore.config import Config
        _W['s3'] = boto3.client('s3', region_name=s3_args['region'],
                                config=Config(max_pool_connections=8,
                                              retries={'max_attempts': 5, 'mode': 'adaptive'}))
        _W['bucket'] = s3_args['bucket']
        _W['key'] = s3_args['key']
    # cache of open fds per file path
    _W['fds'] = {}


def _fd(path):
    fds = _W['fds']
    if path not in fds:
        full = os.path.join(_W['out_dir'], path)
        fds[path] = os.open(full, os.O_WRONLY)
    return fds[path]


ALIGN = 4096  # NVMe/EBS logical block; O_DIRECT needs offset+len+buf aligned


class DirectWriter:
    """Streaming O_DIRECT writer for ONE file within ONE worker. Fed strictly
    sequential, contiguous (offset-increasing) segments. Writes only the
    ALIGNED INTERIOR [align_up(first), align_down(last)) via an O_DIRECT fd —
    XFS takes the inode lock SHARED, so many workers writing the same big file
    (mdbx.dat) scale instead of serializing on the exclusive buffered lock.

    The unaligned HEAD and TAIL (each < ALIGN) are NOT written here. They are
    collected and returned to the parent, which writes ALL fragments serially
    after the pool joins. This is what makes it correct: at a worker-group
    boundary inside mdbx.dat, two workers' edge writes fall in the same 4K
    block; doing them concurrently (buffered RMW) would risk a torn page.
    Serially in the parent, they can't race. Interior O_DIRECT blocks are
    disjoint from edge blocks, so O_DIRECT and the later buffered edge writes
    never touch the same block.
    """
    import mmap as _mmap_mod

    def __init__(self, full_path, buf_bytes=8 * 1024 * 1024):
        self.full = full_path
        self.dfd = os.open(full_path, os.O_WRONLY | os.O_DIRECT)
        cap = (buf_bytes // ALIGN) * ALIGN
        self.buf = self._mmap_mod.mmap(-1, cap)  # anonymous mmap -> page-aligned
        self.view = memoryview(self.buf)
        self.cap = cap
        self.fill = 0          # bytes currently in aligned buffer
        self.dpos = None       # file offset of buffer[0] (always ALIGN-aligned)
        self.cursor = None     # next file offset expected from caller
        self.head_off = None   # file offset where this file's data starts
        self.head_buf = b''    # accumulated unaligned head bytes (< ALIGN)
        self.aligned_started = False
        self.written = 0       # aligned bytes written via O_DIRECT

    def write(self, file_off, data):
        if self.cursor is None:
            self.cursor = file_off
        assert file_off == self.cursor, (self.full, file_off, self.cursor)
        mv = memoryview(data) if not isinstance(data, memoryview) else data
        n = len(mv)
        pos = 0
        # HEAD: accumulate bytes before the first ALIGN boundary as a fragment.
        if not self.aligned_started and self.cursor % ALIGN != 0:
            if self.head_off is None:
                self.head_off = self.cursor
            need = ALIGN - (self.cursor % ALIGN)
            take = min(need, n)
            self.head_buf += bytes(mv[pos:pos + take])
            self.cursor += take
            pos += take
            if self.cursor % ALIGN != 0:
                return  # still inside the head block; await more bytes
        self.aligned_started = True
        # now cursor is ALIGN-aligned
        while pos < n:
            if self.dpos is None:
                self.dpos = self.cursor
            space = self.cap - self.fill
            take = min(space, n - pos)
            self.view[self.fill:self.fill + take] = mv[pos:pos + take]
            self.fill += take
            self.cursor += take
            pos += take
            if self.fill == self.cap:
                whole = (self.fill // ALIGN) * ALIGN  # == cap, aligned
                os.pwrite(self.dfd, self.view[:whole], self.dpos)
                self.dpos += whole
                self.written += whole
                self.fill = 0

    def finish(self):
        """Flush full blocks via O_DIRECT; return edge fragments [(off,bytes)]
        for the parent to write serially (buffered) after the pool joins."""
        frags = []
        if self.head_buf:
            frags.append((self.head_off, self.head_buf))
        if self.dpos is not None:
            whole = (self.fill // ALIGN) * ALIGN
            if whole:
                os.pwrite(self.dfd, self.view[:whole], self.dpos)
                self.written += whole
            rem = self.fill - whole
            if rem:
                frags.append((self.dpos + whole, bytes(self.view[whole:whole + rem])))
        elif self.fill:
            # never reached an aligned boundary: whole file is one sub-block frag
            frags.append((self.cursor - self.fill, bytes(self.view[:self.fill])))
        os.close(self.dfd)
        self.view.release()
        self.buf.close()
        return frags


def _process_group(grp):
    import time as _t
    _t0 = _t.time()
    members = _W['members']
    starts = _W['starts']
    coff, clen, uoff, uend = grp['coff'], grp['clen'], grp['uoff'], grp['uend']

    # fetch compressed bytes for this group's contiguous span [coff, coff+clen)
    proc = None
    if _W['mode'] == 's3':
        body = _W['s3'].get_object(Bucket=_W['bucket'], Key=_W['key'],
                                   Range=f'bytes={coff}-{coff+clen-1}')['Body']
        src = body
    elif _W['mode'] == 'cmd':
        # exec a templated downloader (CRT/curl/aria2) for this byte-range and
        # stream its stdout into the decoder. {coff}/{cend}/{clen} filled in.
        import subprocess, shlex
        cmd = _W['cmd_tmpl'].format(coff=coff, cend=coff + clen - 1, clen=clen)
        proc = subprocess.Popen(shlex.split(cmd), stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL)
        src = _Bounded(proc.stdout, clen)
    else:
        f = open(_W['local_path'], 'rb')
        f.seek(coff)
        src = _Bounded(f, clen)

    dctx = zstd.ZstdDecompressor()
    reader = dctx.stream_reader(src, read_across_frames=True)
    direct = _W.get('direct', False)
    dwriters = {}         # path -> DirectWriter (this worker only)

    gpos = uoff           # global uncompressed offset of next decoded byte
    written = 0
    CHUNK = 16 * 1024 * 1024
    # find first member whose data could overlap gpos
    while True:
        buf = reader.read(CHUNK)
        if not buf:
            break
        b_start = gpos
        b_end = gpos + len(buf)
        # iterate members overlapping [b_start, b_end)
        idx = bisect.bisect_right(starts, b_start) - 1
        if idx < 0:
            idx = 0
        i = idx
        while i < len(members):
            m = members[i]
            ds, de = m['data_uoff'], m['data_uend']
            if ds >= b_end:
                break
            if de <= b_start or de == ds:
                i += 1
                continue
            # overlap [max(ds,b_start), min(de,b_end))
            lo = max(ds, b_start)
            hi = min(de, b_end)
            if hi > lo:
                seg = buf[lo - b_start: hi - b_start]
                file_off = lo - ds
                if direct:
                    p = m['path']
                    dw = dwriters.get(p)
                    if dw is None:
                        dw = DirectWriter(os.path.join(_W['out_dir'], p))
                        dwriters[p] = dw
                    dw.write(file_off, seg)
                else:
                    os.pwrite(_fd(m['path']), seg, file_off)
                written += len(seg)
            i += 1
        gpos = b_end

    if proc is not None:
        try:
            proc.stdout.close()
        except Exception:
            pass
        proc.wait()

    edge_frags = []       # [(path, file_off, bytes)] for parent to write serially
    if direct:
        for p, dw in dwriters.items():
            for off, data in dw.finish():
                edge_frags.append((p, off, data))
    return {'written': written, 'seconds': round(_t.time() - _t0, 1),
            'uoff': uoff, 'ubytes': uend - uoff, 'edge_frags': edge_frags}


class _Bounded:
    """Read-only wrapper limiting reads to n bytes (for local file groups)."""
    def __init__(self, f, n):
        self.f = f
        self.left = n
    def read(self, sz=-1):
        if self.left <= 0:
            return b''
        if sz < 0 or sz > self.left:
            sz = self.left
        d = self.f.read(sz)
        self.left -= len(d)
        return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--index', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--workers', type=int, default=0,
                    help='worker processes (0 = min(cpu_count, 96)). Capped at 96 '
                         'because that is the measured mountpoint-s3 concurrency '
                         'sweet spot: >96 concurrent streams degrade throughput '
                         '(128w and 192w both ~halved net vs 96w). Pass an explicit '
                         'value to override the cap.')
    ap.add_argument('--groups', type=int, default=0,
                    help='contiguous spans to split into (0 = one per worker, '
                         'the measured optimum: large sequential reads are what '
                         'mountpoint-s3 likes; oversubscribing fragments them and '
                         'is slower). Override only for experiments.')
    ap.add_argument('--steal', action='store_true',
                    help='dispatch with imap_unordered (work-stealing) instead of '
                         'pool.map. Slower for uniform groups on mountpoint; kept '
                         'for heterogeneous sources.')
    ap.add_argument('--s3', nargs='+', metavar=('BUCKET', 'KEY'))
    ap.add_argument('--region', default='us-east-1')
    ap.add_argument('--local')
    ap.add_argument('--cmd', dest='cmd_tmpl', default=None,
                    help='download a span by exec-ing this template per group; '
                         '{coff}/{cend}/{clen} are filled in and stdout is '
                         'streamed to the decoder. e.g. for CRT: '
                         '"aws s3api get-object --bucket B --key K '
                         '--range bytes={coff}-{cend} /dev/stdout" (manifest-driven)')
    ap.add_argument('--o-direct', dest='o_direct', action='store_true',
                    help='write via O_DIRECT (concurrent writers to one big file '
                         'scale; bypasses the per-inode buffered write lock)')
    args = ap.parse_args()
    if args.workers <= 0:
        # min(cores, 96): 96 is the measured mountpoint-s3 sweet spot; beyond it
        # concurrent-stream contention degrades throughput (see benchmark notes).
        args.workers = min(os.cpu_count() or 16, 96)

    with open(args.index) as f:
        index = json.load(f)
    members = index['members']
    frames = index['frames']

    # Step A: create dir tree + pre-create/fallocate files (serial, cheap)
    out_root = os.path.realpath(args.out)
    os.makedirs(args.out, exist_ok=True)

    # The manifest is untrusted. Validate every member path and each symlink
    # target before creating any filesystem object.
    validate_manifest_members(members, out_root)
    for m in members:
        path = m['path']
        full = os.path.join(args.out, path)
        t = m['type']
        # Directory if: explicit dir typeflag, trailing-slash path, or the path
        # resolves to the output root itself (the archive's "./" entry, which
        # some tar variants store with typeflag '0'/'' instead of '5').
        is_dir = (t == '5') or path.endswith('/') or os.path.realpath(full) == out_root
        if is_dir:
            os.makedirs(os.path.normpath(full), exist_ok=True)
            continue
        os.makedirs(os.path.dirname(full), exist_ok=True)
        if t in ('0', '\0', ''):  # regular file
            # Never open an existing directory as a file (defensive).
            if os.path.isdir(full):
                continue
            fd = os.open(full, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, m.get('mode', 0o644) or 0o644)
            try:
                if m['size'] > 0:
                    # posix_fallocate reserves blocks (Linux); ftruncate sets
                    # size everywhere else. Either gives pwrite a sized file.
                    if hasattr(os, 'posix_fallocate'):
                        os.posix_fallocate(fd, 0, m['size'])
                    else:
                        os.ftruncate(fd, m['size'])
            finally:
                os.close(fd)
        elif t == '2':  # symlink
            try:
                if not os.path.lexists(full):
                    os.symlink(m['linkname'], full)
            except OSError:
                pass
        elif t == '1':  # hardlink
            pass  # rare in these snapshots; handle post-pass if needed

    # One uniform contiguous span per worker (measured optimum). Each worker
    # does ONE big sequential read — mountpoint-s3's sweet spot. Oversubscribing
    # was tested and is strictly worse (96/192/384 groups all slower: smaller
    # spans reset mountpoint's prefetch and leave workers idle).
    n_groups = args.groups if args.groups > 0 else args.workers
    groups = build_groups(frames, n_groups)

    if args.cmd_tmpl:
        mode = 'cmd'
    elif args.s3:
        mode = 's3'
    else:
        mode = 'local'
    s3_args = None
    if mode == 's3':
        s3_args = {'bucket': args.s3[0], 'key': args.s3[1], 'region': args.region}

    import time
    t0 = time.time()
    with mp.Pool(args.workers, initializer=_init,
                 initargs=(members, args.out, mode, s3_args, args.local,
                           args.o_direct, args.cmd_tmpl)) as pool:
        # pool.map: static 1:1 group→worker assignment (default). Best when
        # groups are uniform (see build_groups) and the source rewards large
        # sequential reads. --steal switches to work-stealing for uneven sources.
        if args.steal:
            results = list(pool.imap_unordered(_process_group, groups))
        else:
            results = pool.map(_process_group, groups)

    # O_DIRECT mode: workers wrote only aligned interiors and returned the
    # unaligned edge fragments. Write them now, SERIALLY (buffered), so the two
    # workers sharing an edge block at a group boundary can't race.
    edge_count = 0
    if args.o_direct:
        edge_fd = {}
        for r in results:
            for path, off, data in r.get('edge_frags', []):
                fd = edge_fd.get(path)
                if fd is None:
                    fd = edge_fd[path] = os.open(os.path.join(args.out, path), os.O_WRONLY)
                os.pwrite(fd, data, off)
                edge_count += 1
        for fd in edge_fd.values():
            os.fsync(fd)
            os.close(fd)
    dur = time.time() - t0

    total_written = sum(r['written'] for r in results)
    times = sorted((r['seconds'] for r in results), reverse=True)
    # worker imbalance: if max >> median, work is lopsided (e.g. one big file)
    slowest = times[0] if times else 0
    median = times[len(times) // 2] if times else 0
    print(json.dumps({
        'status': 'ok', 'workers': args.workers, 'groups': len(groups),
        'bytes_written': total_written, 'seconds': round(dur, 1),
        'write_MBps': round(total_written / 1048576 / dur, 0) if dur else 0,
        'slowest_worker_s': slowest, 'median_worker_s': median,
        'top5_worker_s': times[:5],
        'o_direct': args.o_direct, 'edge_frags': edge_count,
    }))


if __name__ == '__main__':
    main()
