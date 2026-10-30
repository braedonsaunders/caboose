# GPU broker transport foundation

`duplex.py` relays opaque bytes between two already connected stream sockets with
an independent bounded buffer in each direction. It owns both sockets, closes
them on completion, cancellation or error, propagates half-close after draining,
and has a finite absolute lifetime. Cancellation wakes a blocked selector.
Forwarded-byte counts describe transport only, never GPU completion.

This is an isolated transport component, not a runnable GPU broker or a registered
Vulkan driver. It has no public listener or automatic launch path. The caller must
authenticate and associate each connection with a process/session before passing
socket ownership. Executor leases, protocol negotiation, resource tracking and
GPU feedback remain outside this component. It does not currently connect the
phone or change the existing capture path.

Run the real-socket tests without a compiler or external service:

```sh
python3 -m unittest discover -s guest/gpu/broker -v
```

The tests cover binary request/response integrity, half-close, bounded buffers,
reverse-direction progress under backpressure, cancellation, deadlines and
connection isolation. Every test closes its sockets and joins its threads.
