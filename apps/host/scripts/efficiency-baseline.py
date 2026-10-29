#!/usr/bin/env python3
"""Record real API timings and optional Linux process/snapshot metrics. No changes by default."""
import argparse
import json
import os
import pathlib
import statistics
import time
import urllib.error
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def metrics(pid, snapshot):
    result = {}
    if pid:
        try:
            # Count this process only; provide the VMM PID, not the host supervisor PID.
            fields = pathlib.Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
            result['cpuTicks'] = int(fields[11]) + int(fields[12])
            result['startTicks'] = int(fields[19])
            result['ticksPerSecond'] = os.sysconf('SC_CLK_TCK')
            text = pathlib.Path(f'/proc/{pid}/smaps_rollup').read_text()
            for line in text.splitlines():
                name, _, value = line.partition(':')
                if name in ('Rss', 'Pss', 'Private_Dirty', 'Swap'):
                    result[name + 'Bytes'] = int(value.split()[0]) * 1024
        except (OSError, ValueError, IndexError):
            result['processMetricsUnavailable'] = True
    if snapshot:
        try:
            root = pathlib.Path(snapshot)
            if not root.exists():
                raise FileNotFoundError()
            paths = [root] if root.is_file() else root.rglob('*')
            sizes = [p.lstat() for p in paths if p.is_file() and not p.is_symlink()]
            result['snapshotLogicalBytes'] = sum(s.st_size for s in sizes)
            result['snapshotAllocatedBytes'] = sum(s.st_blocks * 512 for s in sizes)
        except OSError:
            result['snapshotMetricsUnavailable'] = True
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True, help='Computer API prefix, e.g. https://host/v1 or https://host/v1/computers/c-ID')
    parser.add_argument('--token-file', required=True)
    parser.add_argument('--operation', choices=['observe', 'files', 'session', 'park'], default='observe',
                        help='files/session WAKE the guest; park explicitly parks it. No restart or deletion.')
    parser.add_argument('--repeat', type=int, default=1)
    parser.add_argument('--pid', type=int, help='Optional local Linux VMM PID; excludes other processes')
    parser.add_argument('--snapshot', help='Optional local snapshot directory')
    parser.add_argument('--sample-seconds', type=float, default=0, help='Optional post-request observation interval, 0..60')
    args = parser.parse_args()
    if not 1 <= args.repeat <= 100 or not 0 <= args.sample_seconds <= 60:
        parser.error('repeat must be 1..100 and sample-seconds 0..60')
    token = pathlib.Path(args.token_file).read_text().strip()
    opener = urllib.request.build_opener(NoRedirect())

    def request(method, path):
        req = urllib.request.Request(args.url.rstrip('/') + path, method=method,
                                     headers={'Authorization': 'Bearer ' + token})
        start = time.perf_counter()
        try:
            with opener.open(req, timeout=300) as response:
                body = response.read()
                return response.status, (time.perf_counter() - start) * 1000, body
        except urllib.error.HTTPError as error:
            error.close()
            return error.code, (time.perf_counter() - start) * 1000, b''
        except (OSError, urllib.error.URLError):
            return None, (time.perf_counter() - start) * 1000, b''

    def state():
        status, _, body = request('GET', '/computer')
        try:
            return json.loads(body)['state'] if status == 200 else 'unavailable'
        except (ValueError, KeyError):
            return 'unavailable'

    method, path = {'observe': ('GET', '/computer'), 'files': ('GET', '/fs/list?path='),
                    'session': ('POST', '/session'), 'park': ('POST', '/session/park')}[args.operation]
    samples = []
    for i in range(args.repeat):
        before = state()
        status, elapsed, _ = request(method, path)
        first = metrics(args.pid, args.snapshot)
        started = time.perf_counter()
        if args.sample_seconds:
            time.sleep(args.sample_seconds)
        last = metrics(args.pid, args.snapshot)
        record = {'sample': i + 1, 'operation': args.operation, 'before': before, 'after': state(),
                  'status': status, 'elapsedMs': elapsed, 'observationSeconds': time.perf_counter() - started,
                  'metricsBeforeObservation': first, 'metricsAfterObservation': last}
        samples.append(record)
        print(json.dumps(record), flush=True)
    good = [s['elapsedMs'] for s in samples if s['status'] == 200]
    print(json.dumps({'summary': {'samples': len(samples), 'successful': len(good),
                                'medianMs': statistics.median(good) if good else None,
                                'maxMs': max(good) if good else None}}))
    return 0 if len(good) == len(samples) else 1


if __name__ == '__main__':
    raise SystemExit(main())
