/**
 * blowfish.cpp — NAPI bridge for Blowfish encryption
 *
 * Exposes a single function: encryptBlock(left: number, right: number): [number, number]
 *
 * The left and right params are big-endian uint32 values.
 * The Nikon pairing engine feeds raw big-endian 32-bit words into the hash function.
 * This NAPI function encrypts one 8-byte block using Blowfish/ECB with the Nikon key
 * and returns the resulting two big-endian uint32 values.
 */

#include <napi/native_api.h>
#include <hilog/log.h>
#include <cstdint>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "HarmoNikon-Blowfish"

// Full type definitions (must match blowfish_core.cpp)
struct bfish_t {
    uint32_t pbox[18];
    uint32_t sbox[4][256];
};

struct bfblk_t {
    uint32_t hi;
    uint32_t lo;
};

extern "C" void bfish_init(bfish_t *bf, const uint8_t *key, size_t len);
extern "C" void bfish_enblock(bfish_t *bf, bfblk_t *blk);

// Nikon smart-device Blowfish key (8 bytes)
static const uint8_t NIKON_KEY[8] = {
    0xFF, 0xFF, 0xAA, 0x55, 0x11, 0x22, 0x33, 0x00
};

// Global Blowfish state, initialized once
static bfish_t g_bf;
static bool g_initialized = false;

static void ensureInit() {
    if (!g_initialized) {
        bfish_init(&g_bf, NIKON_KEY, 8);
        g_initialized = true;
        OH_LOG_INFO(LOG_APP, "[CHECKPOINT] Blowfish NAPI: initialized with Nikon key (FF FF AA 55 11 22 33 00)");
    }
}

/**
 * encryptBlock(left: number, right: number): [number, number]
 *
 * Encrypts a single 8-byte block (hi=left, lo=right) using Blowfish/ECB.
 * Input and output are big-endian uint32 values (not little-endian).
 *
 * This matches the Android JCE "Blowfish/ECB/NoPadding" behavior where
 * 8 bytes are fed as two big-endian int32s.
 */
static napi_value Encrypt(napi_env env, napi_callback_info info) {
    ensureInit();

    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // Parse left (uint32 as double from ArkTS)
    int32_t left = 0;
    napi_get_value_int32(env, args[0], &left);

    // Parse right (uint32 as double from ArkTS)
    int32_t right = 0;
    napi_get_value_int32(env, args[1], &right);

    // Encrypt the block in place
    bfblk_t blk;
    blk.hi = (uint32_t)left;
    blk.lo = (uint32_t)right;

    OH_LOG_INFO(LOG_APP, "[TRACE] Blowfish encryptBlock input: hi=%{public}x lo=%{public}x", blk.hi, blk.lo);

    bfish_enblock(&g_bf, &blk);

    OH_LOG_INFO(LOG_APP, "[TRACE] Blowfish encryptBlock output: hi=%{public}x lo=%{public}x", blk.hi, blk.lo);

    // Return [hi, lo] as int32 array
    napi_value result;
    napi_create_array_with_length(env, 2, &result);

    napi_value hiVal, loVal;
    napi_create_int32(env, (int32_t)blk.hi, &hiVal);
    napi_create_int32(env, (int32_t)blk.lo, &loVal);

    napi_set_element(env, result, 0, hiVal);
    napi_set_element(env, result, 1, loVal);

    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        { "encryptBlock", nullptr, Encrypt, nullptr, nullptr, nullptr, napi_default, nullptr }
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);

    OH_LOG_INFO(LOG_APP, "[CHECKPOINT] Blowfish NAPI module loaded. encryptBlock() ready.");
    return exports;
}
EXTERN_C_END

static napi_module blowfishModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "blowfish",
    .nm_priv = nullptr,
    .reserved = { nullptr },
};

// This is a dynamic NAPI module, registered by name "blowfish"
// Must be imported in ArkTS as: import blowfish from 'libblowfish.so';
