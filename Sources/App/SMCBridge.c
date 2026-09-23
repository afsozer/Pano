#include "SMCBridge.h"
#include <IOKit/IOKitLib.h>
#include <dispatch/dispatch.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

// Average CPU/GPU die temperature from the System Management Controller.
// No root needed: AppleSMC's user client allows reads.
//
// SMC key names are not stable across Apple Silicon generations, so instead of
// a hard-coded list the keys are discovered once by enumerating the whole SMC
// key table and picking temperature keys by prefix.
//
// Prefix rules, cross-checked against the per-generation sensor table of the
// open-source Stats app (github.com/exelban/stats, Modules/Sensors/values.swift):
//   M1, M2, M4, M5: CPU cores are "Tp.." (performance / super cores) and
//                   "Te.." (efficiency cores on M4); GPU clusters are "Tg..".
//   M3:             efficiency cores are "Te..", but performance cores
//                   ("Tf0.", "Tf4.") and GPU clusters ("Tf1.", "Tf2.") share
//                   the "Tf" prefix. Those are only used as a fallback when a
//                   machine has no "Tp" / "Tg" keys, because other generations
//                   expose unrelated "Tf" keys too (an M5 has TfC0/TfC1).
// Only 32-bit float ("flt ") readings are accepted. Intel Macs report their
// sensors as fixed-point "sp78" under different keys (TC0P, TG0D, ...); they
// are deliberately not supported and come back as NaN ("unavailable").
//
// Measured on an M5 MacBook Pro: the SMC exposes ~2,800 keys; discovery takes
// ~0.5 s (hence the cache; a cached read is ~10 ms) and
// selects 14 "Tp", 4 "Te" and 23 "Tg" float keys. Several keys from Stats'
// M5 table (Tp08, Tp0K, Tp0U, ...) do not exist on that machine at all, which
// is why discovery beats a fixed list.

enum {
    kSMCSelector = 2,
    kSMCReadBytes = 5,
    kSMCGetKeyFromIndex = 8,
    kSMCReadKeyInfo = 9,
};

enum { kMaxKeys = 64 };

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfo;

typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCPLimitData pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

typedef struct {
    uint32_t keys[kMaxKeys];
    size_t count;
} SMCKeyList;

static uint32_t fourCC(const char key[5]) {
    return ((uint32_t)(uint8_t)key[0] << 24) |
           ((uint32_t)(uint8_t)key[1] << 16) |
           ((uint32_t)(uint8_t)key[2] << 8) |
           (uint32_t)(uint8_t)key[3];
}

static io_connect_t openSMC(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) return IO_OBJECT_NULL;
    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    return result == KERN_SUCCESS ? connection : IO_OBJECT_NULL;
}

static int callSMC(io_connect_t connection, SMCKeyData *input, SMCKeyData *output) {
    size_t outputSize = sizeof(*output);
    memset(output, 0, sizeof(*output));
    kern_return_t result = IOConnectCallStructMethod(connection, kSMCSelector,
                                                      input, sizeof(*input),
                                                      output, &outputSize);
    // `output->result` is the SMC's own status; non-zero means e.g. "key not found".
    return result == KERN_SUCCESS && output->result == 0;
}

static int readKeyInfo(io_connect_t connection, uint32_t key, SMCKeyInfo *info) {
    SMCKeyData input = {0}, output;
    input.key = key;
    input.data8 = kSMCReadKeyInfo;
    if (!callSMC(connection, &input, &output)) return 0;
    *info = output.keyInfo;
    return 1;
}

static int readKey(io_connect_t connection, uint32_t key, uint32_t *type,
                   uint32_t *size, uint8_t bytes[32]) {
    SMCKeyInfo info;
    if (!readKeyInfo(connection, key, &info) || info.dataSize == 0 || info.dataSize > 32) return 0;
    SMCKeyData input = {0}, output;
    input.key = key;
    input.keyInfo.dataSize = info.dataSize;
    input.data8 = kSMCReadBytes;
    if (!callSMC(connection, &input, &output)) return 0;
    *type = info.dataType;
    *size = info.dataSize;
    memcpy(bytes, output.bytes, 32);
    return 1;
}

static int readFloat(io_connect_t connection, uint32_t key, double *value) {
    uint32_t type = 0, size = 0;
    uint8_t bytes[32] = {0};
    if (!readKey(connection, key, &type, &size, bytes)) return 0;
    if (type != fourCC("flt ") || size != 4) return 0;
    float raw = 0;
    memcpy(&raw, bytes, sizeof(raw)); // SMC floats are little-endian, like the host.
    *value = raw;
    return 1;
}

static int isPlausible(double celsius) {
    return celsius >= 10 && celsius <= 120;
}

static void appendKey(SMCKeyList *list, uint32_t key) {
    if (list->count < kMaxKeys) list->keys[list->count++] = key;
}

static SMCKeyList cpuKeys, gpuKeys;

/// Walks the SMC key table once (~0.5 s) and fills cpuKeys / gpuKeys.
static void discoverKeys(void *unused) {
    (void)unused;
    io_connect_t connection = openSMC();
    if (connection == IO_OBJECT_NULL) return;

    uint32_t type = 0, size = 0;
    uint8_t bytes[32] = {0};
    if (!readKey(connection, fourCC("#KEY"), &type, &size, bytes) || size < 4) {
        IOServiceClose(connection);
        return;
    }
    uint32_t keyCount = ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
                        ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];

    SMCKeyList m3CPU = {0}, m3GPU = {0};
    for (uint32_t index = 0; index < keyCount; index++) {
        SMCKeyData input = {0}, output;
        input.data8 = kSMCGetKeyFromIndex;
        input.data32 = index;
        if (!callSMC(connection, &input, &output)) continue;
        uint32_t key = output.key;
        char a = (char)(key >> 24), b = (char)(key >> 16), c = (char)(key >> 8);
        if (a != 'T') continue;

        // Cheap prefix test first; only candidates pay for the key-info call.
        int cpu = b == 'p' || b == 'e';
        int gpu = b == 'g';
        int m3cpu = b == 'f' && (c == '0' || c == '4');
        int m3gpu = b == 'f' && (c == '1' || c == '2');
        if (!(cpu || gpu || m3cpu || m3gpu)) continue;

        SMCKeyInfo info;
        if (!readKeyInfo(connection, key, &info)) continue;
        if (info.dataType != fourCC("flt ") || info.dataSize != 4) continue;

        if (cpu) appendKey(&cpuKeys, key);
        else if (gpu) appendKey(&gpuKeys, key);
        else if (m3cpu) appendKey(&m3CPU, key);
        else appendKey(&m3GPU, key);
    }
    if (cpuKeys.count == 0) cpuKeys = m3CPU;
    if (gpuKeys.count == 0) gpuKeys = m3GPU;
    IOServiceClose(connection);
}

static void ensureKeysDiscovered(void) {
    static dispatch_once_t once;
    dispatch_once_f(&once, NULL, discoverKeys);
}

static double averageTemperature(const SMCKeyList *list) {
    if (list->count == 0) return NAN;
    io_connect_t connection = openSMC();
    if (connection == IO_OBJECT_NULL) return NAN;
    double sum = 0;
    size_t valid = 0;
    for (size_t i = 0; i < list->count; i++) {
        double value;
        if (readFloat(connection, list->keys[i], &value) && isPlausible(value)) {
            sum += value;
            valid++;
        }
    }
    IOServiceClose(connection);
    return valid ? sum / (double)valid : NAN;
}

double SMCReadAverageCPUTemperature(void) {
    ensureKeysDiscovered();
    return averageTemperature(&cpuKeys);
}

double SMCReadAverageGPUTemperature(void) {
    ensureKeysDiscovered();
    return averageTemperature(&gpuKeys);
}
