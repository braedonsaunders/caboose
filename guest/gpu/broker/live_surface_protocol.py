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

    require(16 <= kind <= 24, "unknown surface kind")
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
    else:  # surface retire
        exact(40)
