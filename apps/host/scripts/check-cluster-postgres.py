#!/usr/bin/env python3
"""Bounded private PostgreSQL gate; requires installed PostgreSQL and existing JS dependencies."""
import os, pathlib, shutil, subprocess, tempfile, time
root = pathlib.Path(__file__).resolve().parents[1]
bin = pathlib.Path(os.environ.get('CABOOSE_TEST_PG_BIN', '/opt/homebrew/opt/postgresql@16/bin'))
private = pathlib.Path(tempfile.mkdtemp(prefix='caboose-cluster-', dir='/tmp'))
started = False
minio = None
minio_log = None
try:
    subprocess.run([str(bin/'initdb'),'-D',str(private/'data'),'-A','trust','--no-locale'], check=True, stdout=subprocess.DEVNULL, timeout=20)
    (private/'socket').mkdir()
    options = f"-k {private/'socket'} -h '' -p 19437 -c max_connections=10 -c shared_buffers=16MB -c work_mem=1MB -c maintenance_work_mem=16MB"
    subprocess.run([str(bin/'pg_ctl'),'-D',str(private/'data'),'-l',str(private/'postgres.log'),'-o',options,'-w','start'],check=True,timeout=20)
    started = True
    env = dict(os.environ, CABOOSE_TEST_CLUSTER_DATABASE_URL=f"postgresql:///postgres?host={private/'socket'}&port=19437", NODE_OPTIONS='--max-old-space-size=512')
    if os.environ.get('CABOOSE_TEST_MINIO_BINARY'):
        import socket, urllib.request
        listener = socket.socket(); listener.bind(('127.0.0.1',0)); port = listener.getsockname()[1]; listener.close()
        minio_log = open(private/'minio.log','wb')
        minio_env = dict(os.environ, MINIO_ROOT_USER='disposable',MINIO_ROOT_PASSWORD='disposable-test-only',GOMEMLIMIT='256MiB',GOMAXPROCS='1',MINIO_BROWSER='off')
        minio = subprocess.Popen([os.environ['CABOOSE_TEST_MINIO_BINARY'],'server',str(private/'objects'),'--address',f'127.0.0.1:{port}'],env=minio_env,stdout=minio_log,stderr=subprocess.STDOUT)
        env['CABOOSE_TEST_MINIO_ENDPOINT'] = f'http://127.0.0.1:{port}'
        deadline = time.monotonic()+15
        while True:
            try:
                urllib.request.urlopen(f'http://127.0.0.1:{port}/minio/health/ready',timeout=1).close(); break
            except Exception:
                if time.monotonic()>deadline: raise RuntimeError('MinIO readiness deadline')
                time.sleep(.1)
    subprocess.run(['pnpm','exec','vitest','run','src/cluster/coordinator.test.ts','src/cluster/recovery.test.ts','src/cluster/routing.test.ts','src/portable-storage/index.test.ts','src/computers.test.ts','src/fleet.test.ts','--maxWorkers=1','--minWorkers=1'], cwd=root, env=env, check=True, timeout=100)
finally:
    if minio:
        minio.terminate()
        try: minio.wait(timeout=10)
        except subprocess.TimeoutExpired: minio.kill(); minio.wait(timeout=5)
        if minio_log: minio_log.close()
        check = socket.socket(); check.settimeout(.3)
        try:
            if check.connect_ex(('127.0.0.1',port)) == 0: raise RuntimeError('MinIO listener survived cleanup')
        finally: check.close()
    if started:
        subprocess.run([str(bin/'pg_ctl'),'-D',str(private/'data'),'-m','immediate','-w','stop'], check=True,timeout=10)
    if (private/'socket'/'.s.PGSQL.19437').exists():
        raise RuntimeError('Private PostgreSQL listener survived cleanup')
    shutil.rmtree(private)
