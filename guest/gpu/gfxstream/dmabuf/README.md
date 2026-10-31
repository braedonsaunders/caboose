# Phone-resident dma-bufs in the Vulkan driver

Header-only C++17 pieces the Caboose Vulkan driver uses to share images through the
computer's render node; the contract is [docs/gpu-buffers.md](../../../../docs/gpu-buffers.md).

| File | What |
| --- | --- |
| `dmabuf.h` | A buffer's identity (its dma-buf's device and inode, after checking the descriptor is a dma-buf), creation of a remote buffer as a vgem object, and the per-process table of host allocations shared through dma-bufs |
| `remote_images.h` | `CABOOSE_FORMAT_MOD_REMOTE`, the Vulkan formats a remote buffer can have, and their nominal plane layout |
| `registration.h` | Registration of a buffer's image with the GPU broker (CGLS kinds 40 and 41) |

The driver integration (image creation, memory import and export, `vkGetMemoryFdKHR`,
plane layouts, and registration on dedicated allocation) is in the driver's prepared
sources, which include these headers from `caboose-dmabuf/`.

## Test

`dmabuf_test.cpp` needs a vgem device (`modprobe vgem`) and exits 77 without one:

```sh
g++ -std=c++17 -O2 -Wall -Wextra -Werror dmabuf_test.cpp -o dmabuf_test && ./dmabuf_test
```

It checks that a created buffer has at least the requested size, that every descriptor of
one buffer has its identity and other buffers and ordinary files do not, that a thousand
4K remote buffers commit no memory, and the shared-allocation table's users, duplicate
descriptors and release. It passes as an unprivileged user under AddressSanitizer and
UndefinedBehaviorSanitizer. The broker side of registration and presentation is tested
by `../test_buffer_presentation.py` and `../test_broker_buffers.py`.
