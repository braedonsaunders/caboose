"""Structural checks for live surface controls; never a Vulkan success oracle."""
import struct

U32 = struct.Struct("<I")
U64 = struct.Struct("<Q")
STATUS = struct.Struct("<iIiI")


def validate_surface(kind: int, payload: bytes):
    def require(ok, message):
        if not ok:
            raise ValueError(message)

    def word(offset):
        return U32.unpack_from(payload, offset)[0]

    def wide(offset):
        return U64.unpack_from(payload, offset)[0]

    def exact(length):
        require(len(payload) == length, "surface payload length")

    def status(offset):
        error, has_vk, vk, reserved = STATUS.unpack_from(payload, offset)
        require(error >= 0 and has_vk in (0, 1) and reserved == 0,
                "surface result status")
        require(has_vk == 1 or vk == 0, "absent Vulkan result")
        return error, has_vk, vk

    require(16 <= kind <= 36 or kind == 39, "unknown surface kind")
    require(len(payload) >= 40, "truncated surface identity")
    require(payload[:16] != bytes(16) and payload[16:32] != bytes(16) and wide(32) != 0,
            "zero surface identity")
    if kind == 16:  # bind
        exact(64)
        require(wide(40) and wide(48), "invalid bind identity")
        require((word(56) == 0) == (word(60) == 0), "mixed-zero bind extent")
    elif kind in (17, 24):  # bound / retired
        exact(56)
        status(40)
    elif kind == 18:  # physical-device query
        exact(56)
        require(wide(40) and wide(48), "invalid query identity")
    elif kind == 19:  # raw physical-device surface capabilities
        require(len(payload) >= 64 and wide(40), "invalid capabilities query")
        error, has_vk, vk = status(48)
        if error or not has_vk or vk != 0:
            exact(64)
            require(error != 0 or (has_vk and vk != 0), "capabilities require actual Vulkan success")
            return
        require(len(payload) >= 128, "truncated capabilities")
        formats, modes, queues = struct.unpack_from("<III", payload, 116)
        require(all(count <= 4096 for count in (formats, modes, queues)), "capability count limit")
        exact(128 + 8 * formats + 4 * modes + 16 * queues)
        start = 128 + 8 * formats + 4 * modes
        seen = set()
        for offset in range(start, len(payload), 16):
            family, _, count, supported = struct.unpack_from("<IIII", payload, offset)
            require(family not in seen and count != 0 and supported in (0, 1), "invalid queue capabilities")
            seen.add(family)
    elif kind == 20:  # present, actual remote layout GENERAL
        require(len(payload) >= 96, "truncated present")
        require(all(wide(offset) for offset in (40, 48, 56, 64)), "invalid present identity")
        require(word(72) and word(76) and word(80), "invalid present format/extent")
        require(word(84) == 1, "source must be in actual GENERAL layout")
        count = word(92)
        require(count <= 64, "present semaphore limit")
        exact(96 + 8 * count)
        waits = [wide(offset) for offset in range(96, len(payload), 8)]
        require(all(waits) and len(set(waits)) == len(waits), "invalid binary waits")
    elif kind == 21:  # submission/event result, never a release
        exact(72)
        require(wide(40), "invalid present serial")
        error, has_vk, vk = status(48)
        disposition, event = struct.unpack_from("<II", payload, 64)
        require(disposition <= 2 and event <= 2, "invalid presentation result")
        require(event != 1 or (has_vk == 1 and vk == -4), "device loss needs actual Vulkan result")
    elif kind == 22:  # real source-read completion
        exact(48)
        require(wide(40), "invalid release serial")
    elif kind in (23, 35):  # retire / authenticated owner revoke request
        exact(40)
    elif kind == 25:  # create; request, device, old swapchain, actual create fields
        require(len(payload) >= 120, "truncated swapchain create")
        require(wide(40) and wide(48), "invalid create identity")
        require(all(word(offset) for offset in (68, 72, 80, 84, 88, 92)),
                "invalid create parameters")
        require(word(108) in (0, 1) and word(112) in (0, 1), "invalid create enum")
        count = word(116)
        require(count <= 64, "queue family limit")
        exact(120 + 4 * count)
        families = [word(offset) for offset in range(120, len(payload), 4)]
        require(len(set(families)) == count, "duplicate queue families")
        require((word(112) == 0 and count == 0) or (word(112) == 1 and count >= 2),
                "invalid sharing families")
    elif kind == 26:  # created: request, native swapchain ID, actual result/count
        exact(80)
        require(wide(40) and word(76) == 0, "invalid created response")
        error, has_vk, vk = status(56)
        success = error == 0 and has_vk == 1 and vk == 0
        if success:
            require(wide(48) and 1 <= word(72) <= 256, "invalid actual image count")
        else:
            require(error != 0 or (has_vk and vk != 0), "creation needs actual result")
            require(wide(48) == 0 and word(72) == 0, "failed create has resources")
    elif kind == 27:  # the provider count, or up to 8 guest-owned images (flag 1, 3 with mailbox)
        require(len(payload) >= 56 and wide(40), "invalid swapchain map")
        count, flags = word(48), word(52)
        require(1 <= count <= 256 and flags in (0, 1, 3) and (flags == 0 or count <= 8), "invalid source count")
        exact(56 + 8 * count)
        images = [wide(offset) for offset in range(56, len(payload), 8)]
        require(all(images) and len(set(images)) == count, "invalid source images")
    elif kind in (28, 33):
        exact(64)
        require(wide(40), "invalid swapchain identity")
        status(48)
    elif kind == 29:  # one native acquire operation with a guest timeout
        exact(88)
        require(wide(40) and wide(48) and (wide(56) or wide(64)), "invalid acquire identity")
        require(word(80) == 1 and word(84) == 0, "unsupported acquire device mask")
    elif kind == 30:
        exact(88)
        require(wide(40) and wide(48), "invalid acquired identity")
        error, has_vk, vk = status(56)
        success = error == 0 and has_vk == 1 and vk in (0, 1000001003)
        require(word(72) == int(success), "acquire index requires actual success")
        require(word(76) < 256 if success else word(76) == 0, "invalid acquired index")
        require(error != 0 or has_vk == 1, "acquire requires actual or local failure")
        reason = word(80)
        require(reason <= 3 and word(84) == 0, "invalid acquire completion reason")
        require((reason == 0 and error == 0) or
                (reason != 0 and error != 0 and has_vk == 0),
                "acquire completion provenance")
    elif kind in (31, 36):
        exact(56)
        require(wide(40) and wide(48), "invalid swapchain operation identity")
    elif kind == 32:
        exact(48)
        require(wide(40), "invalid swapchain retirement")
    elif kind == 39:  # an indexed present ordered behind a device-stream ORDER mark
        require(len(payload) >= 88, "truncated ordered present")
        require(all(wide(offset) for offset in (40, 48, 56, 64)), "invalid ordered present identity")
        require(word(72) < 256 and word(80) == 1, "invalid ordered present layout/index")
        count = word(84)
        require(count <= 64, "present semaphore limit")
        exact(88 + 8 * count)
        waits = [wide(offset) for offset in range(88, len(payload), 8)]
        require(all(waits) and len(set(waits)) == count, "invalid binary waits")
    elif kind == 34:
        require(len(payload) >= 80, "truncated indexed present")
        require(all(wide(offset) for offset in (40, 48, 56)), "invalid indexed present identity")
        require(word(64) < 256 and word(72) == 1, "invalid indexed present layout/index")
        count = word(76)
        require(count <= 64, "present semaphore limit")
        exact(80 + 8 * count)
        waits = [wide(offset) for offset in range(80, len(payload), 8)]
        require(all(waits) and len(set(waits)) == count, "invalid binary waits")
