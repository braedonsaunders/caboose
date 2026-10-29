#!/usr/bin/python3
"""Relay the host's vsock connections to local Caboose services in a Linux VM."""
import asyncio
import contextlib
import socket

PORTS = (14600, 14601, 14700, 14701)
HOST_CID = 2
MAX_CONNECTIONS = 128


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        writer.close()
        with contextlib.suppress(ConnectionError, OSError):
            await writer.wait_closed()


async def relay(client, port):
    try:
        reader, writer = await asyncio.open_connection(sock=client)
        try:
            target_reader, target_writer = await asyncio.open_connection('127.0.0.1', port)
        except (ConnectionError, OSError):
            writer.close()
            await writer.wait_closed()
            return
        tasks = [asyncio.create_task(pipe(reader, target_writer)),
                 asyncio.create_task(pipe(target_reader, writer))]
        try:
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            writer.close()
            target_writer.close()
    finally:
        client.close()


async def serve(listener, port, active):
    loop = asyncio.get_running_loop()
    while True:
        client, address = await loop.sock_accept(listener)
        if address[0] != HOST_CID or len(active) >= MAX_CONNECTIONS:
            client.close()
            continue
        task = asyncio.create_task(relay(client, port))
        active.add(task)
        task.add_done_callback(active.discard)


async def main():
    listeners = []
    active = set()
    servers = []
    try:
        for port in PORTS:
            listener = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            listeners.append(listener)
            listener.bind((socket.VMADDR_CID_ANY, port))
            listener.listen(128)
            listener.setblocking(False)
            servers.append(asyncio.create_task(serve(listener, port, active)))
        await asyncio.gather(*servers)
    finally:
        for task in servers + list(active):
            task.cancel()
        await asyncio.gather(*servers, *active, return_exceptions=True)
        for listener in listeners:
            listener.close()


if __name__ == '__main__':
    asyncio.run(main())
