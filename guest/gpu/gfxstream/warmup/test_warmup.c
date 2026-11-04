// SPDX-License-Identifier: MIT
// The replay reads only logs of its own pointer width (README.md). Built and run by
// ../driver/test.sh: cc -I VULKAN_HEADERS test_warmup.c -ldl
#define main caboose_gpu_warmup_main
#include "caboose-gpu-warmup.c"
#undef main
#include <assert.h>

static uint64_t fnv(const unsigned char* bytes, size_t count) {
    return digest(bytes, count, 0xcbf29ce484222325ull);
}

// A log as the driver writes it: magic, identity, then one format question's answer.
static void write_log(const char* path, uint32_t width, int marked) {
    unsigned char identity[256];
    size_t size = 0;
    const char* session = "session-bytes";
    memcpy(identity + size, session, strlen(session)); size += strlen(session);
    if (marked) {
        const char* marker = "caboose-format-cache-v1:";
        memcpy(identity + size, marker, strlen(marker)); size += strlen(marker);
        memset(identity + size, 'a', 64); size += 64;
        memcpy(identity + size, &width, 4); size += 4;
    }
    memcpy(identity + size, "device", 6); size += 6;
    unsigned char key[512];
    size_t keys = 0;
    const uint32_t length = (uint32_t)size, op = kFormat, format = 44;
    key[keys++] = 'P';
    memcpy(key + keys, &length, 4); keys += 4;
    memcpy(key + keys, identity, size); keys += size;
    memcpy(key + keys, &op, 4); keys += 4;
    memcpy(key + keys, &format, 4); keys += 4;
    unsigned char record[1024];
    const unsigned char value[12] = {1, 2, 3};
    memcpy(record + 16, key, keys);
    memcpy(record + 16 + keys, value, sizeof(value));
    const uint32_t keySize = (uint32_t)keys, valueSize = sizeof(value);
    const uint64_t checksum = fnv(record + 16, keys + sizeof(value));
    memcpy(record, &keySize, 4); memcpy(record + 4, &valueSize, 4); memcpy(record + 8, &checksum, 8);
    FILE* file = fopen(path, "wb");
    assert(file);
    fwrite("CBCQ\2\0\0\0", 1, 8, file);
    fwrite(&length, 4, 1, file);
    fwrite(identity, 1, size, file);
    fwrite(record, 1, 16 + keys + sizeof(value), file);
    fclose(file);
}

int main(void) {
    char directory[] = "/tmp/caboose-warmup-XXXXXX";
    assert(mkdtemp(directory));
    char own[128], other[128], unmarked[128];
    snprintf(own, sizeof(own), "%s/own.bin", directory);
    snprintf(other, sizeof(other), "%s/other.bin", directory);
    snprintf(unmarked, sizeof(unmarked), "%s/unmarked.bin", directory);
    write_log(own, (uint32_t)sizeof(void*), 1);
    write_log(other, sizeof(void*) == 8 ? 4 : 8, 1);
    write_log(unmarked, (uint32_t)sizeof(void*), 0);
    read_log(other);
    read_log(unmarked);
    assert(asked == 0 && skipped == 2);
    read_log(own);
    assert(asked == 1 && skipped == 2 && questions[0].op == kFormat && questions[0].format == 44);
    read_log(own);  // a question asked in two sessions is asked once
    assert(asked == 1);
    unlink(own); unlink(other); unlink(unmarked); rmdir(directory);
    puts("warm-up: logs of the replay's own width only passed");
    return 0;
}
