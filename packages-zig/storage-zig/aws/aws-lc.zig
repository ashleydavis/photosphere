const std = @import("std");
const aws_sdk = @import("aws-sdk.zig");

//
// Builds aws-lc's libcrypto (the `crypto` target) as its CMakeLists.txt files do for a Release, non-FIPS, static build
// on Linux and macOS, using the build files aws-lc ships pre-generated in generated-src (the documented build without
// Perl and Go, see its BUILDING.md "Using Pre-Generated Build Files"): the assembly of generated-src/linux-<arch>
// (Linux), generated-src/mac-x86_64 or generated-src/ios-aarch64 (Apple, crypto/CMakeLists.txt's ASSEMBLY_SOURCE), and
// generated-src/err_data.c. libssl, the tools and the tests are not built (s2n-tls and aws-c-cal only use libcrypto).
// CPU jitter entropy is included (DISABLE_CPU_JITTER_ENTROPY is off).
//
// The source lists below are copied from crypto/CMakeLists.txt (crypto_objects and CRYPTO_ARCH_SOURCES),
// crypto/fipsmodule/CMakeLists.txt (fipsmodule and BCM_ASM_SOURCES) and third_party/jitterentropy/CMakeLists.txt, in
// the same order.
//

//
// The C sources of the crypto_objects target, relative to crypto/ (err_data.c is the pre-generated
// generated-src/err_data.c).
//
const crypto_objects = [_][]const u8{
    "asn1/a_bitstr.c",
    "asn1/a_bool.c",
    "asn1/a_d2i_fp.c",
    "asn1/a_dup.c",
    "asn1/a_gentm.c",
    "asn1/a_i2d_fp.c",
    "asn1/a_int.c",
    "asn1/a_mbstr.c",
    "asn1/a_object.c",
    "asn1/a_octet.c",
    "asn1/a_strex.c",
    "asn1/a_strnid.c",
    "asn1/a_time.c",
    "asn1/a_type.c",
    "asn1/a_utctm.c",
    "asn1/a_utf8.c",
    "asn1/asn1_lib.c",
    "asn1/asn1_par.c",
    "asn1/asn_pack.c",
    "asn1/f_int.c",
    "asn1/f_string.c",
    "asn1/tasn_dec.c",
    "asn1/tasn_enc.c",
    "asn1/tasn_fre.c",
    "asn1/tasn_new.c",
    "asn1/tasn_typ.c",
    "asn1/tasn_utl.c",
    "asn1/posix_time.c",
    "base64/base64.c",
    "bio/bio.c",
    "bio/bio_addr.c",
    "bio/bio_mem.c",
    "bio/connect.c",
    "bio/dgram.c",
    "bio/errno.c",
    "bio/fd.c",
    "bio/file.c",
    "bio/hexdump.c",
    "bio/md.c",
    "bio/pair.c",
    "bio/printf.c",
    "bio/socket.c",
    "bio/socket_helper.c",
    "blake2/blake2.c",
    "bn_extra/bn_asn1.c",
    "bn_extra/convert.c",
    "buf/buf.c",
    "bytestring/asn1_compat.c",
    "bytestring/ber.c",
    "bytestring/cbb.c",
    "bytestring/cbs.c",
    "bytestring/unicode.c",
    "chacha/chacha.c",
    "cipher_extra/cipher_extra.c",
    "cipher_extra/cts.c",
    "cipher_extra/derive_key.c",
    "cipher_extra/e_aesctrhmac.c",
    "cipher_extra/e_aesgcmsiv.c",
    "cipher_extra/e_chacha20poly1305.c",
    "cipher_extra/e_aes_cbc_hmac_sha1.c",
    "cipher_extra/e_aes_cbc_hmac_sha256.c",
    "cipher_extra/e_des.c",
    "cipher_extra/e_null.c",
    "cipher_extra/e_rc2.c",
    "cipher_extra/e_rc4.c",
    "cipher_extra/e_tls.c",
    "cipher_extra/tls_cbc.c",
    "conf/conf.c",
    "console/console.c",
    "crypto.c",
    "des/des.c",
    "dh_extra/params.c",
    "dh_extra/dh_asn1.c",
    "digest_extra/digest_extra.c",
    "dsa/dsa.c",
    "dsa/dsa_asn1.c",
    "ecdh_extra/ecdh_extra.c",
    "ecdsa_extra/ecdsa_asn1.c",
    "ec_extra/ec_asn1.c",
    "ec_extra/ec_derive.c",
    "ec_extra/hash_to_curve.c",
    "err/err.c",
    "err_data.c",
    "engine/engine.c",
    "evp_extra/evp_asn1.c",
    "evp_extra/p_dh.c",
    "evp_extra/p_dh_asn1.c",
    "evp_extra/p_dsa.c",
    "evp_extra/p_dsa_asn1.c",
    "evp_extra/p_ec_asn1.c",
    "evp_extra/p_ed25519_asn1.c",
    "evp_extra/p_hmac_asn1.c",
    "evp_extra/p_kem_asn1.c",
    "evp_extra/p_pqdsa_asn1.c",
    "evp_extra/p_rsa_asn1.c",
    "evp_extra/p_x25519.c",
    "evp_extra/p_x25519_asn1.c",
    "evp_extra/p_methods.c",
    "evp_extra/print.c",
    "evp_extra/scrypt.c",
    "evp_extra/sign.c",
    "ex_data.c",
    "hpke/hpke.c",
    "hrss/hrss.c",
    "lhash/lhash.c",
    "md4/md4.c",
    "mem.c",
    "obj/obj.c",
    "obj/obj_xref.c",
    "ocsp/ocsp_asn.c",
    "ocsp/ocsp_client.c",
    "ocsp/ocsp_extension.c",
    "ocsp/ocsp_http.c",
    "ocsp/ocsp_lib.c",
    "ocsp/ocsp_print.c",
    "ocsp/ocsp_server.c",
    "ocsp/ocsp_verify.c",
    "pem/pem_all.c",
    "pem/pem_info.c",
    "pem/pem_lib.c",
    "pem/pem_oth.c",
    "pem/pem_pk8.c",
    "pem/pem_pkey.c",
    "pem/pem_x509.c",
    "pem/pem_xaux.c",
    "pkcs7/bio/cipher.c",
    "pkcs7/pkcs7.c",
    "pkcs7/pkcs7_asn1.c",
    "pkcs7/pkcs7_x509.c",
    "pkcs8/pkcs8.c",
    "pkcs8/pkcs8_x509.c",
    "pkcs8/p5_pbev2.c",
    "poly1305/poly1305.c",
    "poly1305/poly1305_arm.c",
    "poly1305/poly1305_vec.c",
    "pool/pool.c",
    "rand_extra/ccrandomgeneratebytes.c",
    "rand_extra/deterministic.c",
    "rand_extra/getentropy.c",
    "rand_extra/rand_extra.c",
    "rand_extra/vm_ube_fallback.c",
    "rand_extra/urandom.c",
    "rand_extra/windows.c",
    "rc4/rc4.c",
    "refcount_c11.c",
    "refcount_lock.c",
    "refcount_win.c",
    "rsa_extra/rsa_asn1.c",
    "rsa_extra/rsassa_pss_asn1.c",
    "rsa_extra/rsa_crypt.c",
    "rsa_extra/rsa_print.c",
    "stack/stack.c",
    "siphash/siphash.c",
    "spake25519/spake25519.c",
    "thread.c",
    "thread_none.c",
    "thread_pthread.c",
    "thread_win.c",
    "trust_token/pmbtoken.c",
    "trust_token/trust_token.c",
    "trust_token/voprf.c",
    "ube/ube.c",
    "ube/fork_ube_detect.c",
    "ube/vm_ube_detect.c",
    "x509/a_digest.c",
    "x509/a_sign.c",
    "x509/a_verify.c",
    "x509/algorithm.c",
    "x509/asn1_gen.c",
    "x509/by_dir.c",
    "x509/by_file.c",
    "x509/i2d_pr.c",
    "x509/name_print.c",
    "x509/policy.c",
    "x509/rsa_pss.c",
    "x509/t_crl.c",
    "x509/t_req.c",
    "x509/t_x509.c",
    "x509/t_x509a.c",
    "x509/v3_akey.c",
    "x509/v3_akeya.c",
    "x509/v3_alt.c",
    "x509/v3_bcons.c",
    "x509/v3_bitst.c",
    "x509/v3_conf.c",
    "x509/v3_cpols.c",
    "x509/v3_crld.c",
    "x509/v3_enum.c",
    "x509/v3_extku.c",
    "x509/v3_genn.c",
    "x509/v3_ia5.c",
    "x509/v3_info.c",
    "x509/v3_int.c",
    "x509/v3_lib.c",
    "x509/v3_ncons.c",
    "x509/v3_ocsp.c",
    "x509/v3_pcons.c",
    "x509/v3_pmaps.c",
    "x509/v3_prn.c",
    "x509/v3_purp.c",
    "x509/v3_skey.c",
    "x509/v3_utl.c",
    "x509/x_algor.c",
    "x509/x_all.c",
    "x509/x_attrib.c",
    "x509/x_crl.c",
    "x509/x_exten.c",
    "x509/x_name.c",
    "x509/x_pubkey.c",
    "x509/x_req.c",
    "x509/x_sig.c",
    "x509/x_spki.c",
    "x509/x_val.c",
    "x509/x_x509.c",
    "x509/x_x509a.c",
    "x509/x509_att.c",
    "x509/x509_cmp.c",
    "x509/x509_d2.c",
    "x509/x509_def.c",
    "x509/x509_ext.c",
    "x509/x509_lu.c",
    "x509/x509_obj.c",
    "x509/x509_req.c",
    "x509/x509_set.c",
    "x509/x509_trs.c",
    "x509/x509_txt.c",
    "x509/x509_v3.c",
    "x509/x509_vfy.c",
    "x509/x509_vpm.c",
    "x509/x509.c",
    "x509/x509cset.c",
    "x509/x509name.c",
    "x509/x509rset.c",
    "x509/x509spki.c",
    "ui/ui.c",
    "decrepit/bio/base64_bio.c",
    "decrepit/blowfish/blowfish.c",
    "decrepit/cast/cast.c",
    "decrepit/cast/cast_tables.c",
    "decrepit/cfb/cfb.c",
    "decrepit/dh/dh_decrepit.c",
    "decrepit/evp/evp_do_all.c",
    "decrepit/obj/obj_decrepit.c",
    "decrepit/ripemd/ripemd.c",
    "decrepit/rsa/rsa_decrepit.c",
    "decrepit/x509/x509_decrepit.c",
};

//
// CRYPTO_ARCH_SOURCES for x86_64 (the .S files are in generated-src/linux-x86_64/crypto or
// generated-src/mac-x86_64/crypto, except hrss/asm/poly_rq_mul.S which is in crypto/).
//
const crypto_arch_sources_x86_64 = [_][]const u8{
    "chacha/chacha-x86_64.S",
    "cipher_extra/chacha20_poly1305_x86_64.S",
    "cipher_extra/aes128gcmsiv-x86_64.S",
    "cipher_extra/aesni-sha1-x86_64.S",
    "cipher_extra/aesni-sha256-x86_64.S",
    "test/trampoline-x86_64.S",
};

//
// CRYPTO_ARCH_SOURCES for aarch64 (in generated-src/linux-aarch64/crypto or generated-src/ios-aarch64/crypto).
//
const crypto_arch_sources_aarch64 = [_][]const u8{
    "chacha/chacha-armv8.S",
    "test/trampoline-armv8.S",
    "cipher_extra/chacha20_poly1305_armv8.S",
};

//
// BCM_ASM_SOURCES for x86_64 that come from perlasm (in the fipsmodule directory of the generated x86_64 assembly).
//
const bcm_asm_sources_x86_64 = [_][]const u8{
    "aesni-gcm-avx512.S",
    "aesni-gcm-x86_64.S",
    "aesni-xts-avx512.S",
    "aesni-x86_64.S",
    "ghash-ssse3-x86_64.S",
    "ghash-x86_64.S",
    "md5-x86_64.S",
    "p256-x86_64-asm.S",
    "p256_beeu-x86_64-asm.S",
    "rdrand-x86_64.S",
    "rsaz-avx2.S",
    "rsaz-2k-avx512.S",
    "rsaz-3k-avx512.S",
    "rsaz-4k-avx512.S",
    "sha1-x86_64.S",
    "sha256-x86_64.S",
    "sha512-x86_64.S",
    "vpaes-x86_64.S",
    "x86_64-mont5.S",
    "x86_64-mont.S",
};

//
// BCM_ASM_SOURCES for aarch64 that come from perlasm (in the fipsmodule directory of the generated aarch64 assembly).
//
const bcm_asm_sources_aarch64 = [_][]const u8{
    "aesv8-armx.S",
    "aesv8-gcm-armv8.S",
    "aesv8-gcm-armv8-unroll8.S",
    "armv8-mont.S",
    "bn-armv8.S",
    "ghash-neon-armv8.S",
    "ghashv8-armx.S",
    "keccak1600-armv8.S",
    "md5-armv8.S",
    "p256-armv8-asm.S",
    "p256_beeu-armv8-asm.S",
    "rndr-armv8.S",
    "sha1-armv8.S",
    "sha256-armv8.S",
    "sha512-armv8.S",
    "vpaes-armv8.S",
};

//
// The s2n-bignum files BCM_ASM_SOURCES has on both architectures, relative to S2N_BIGNUM_DIR
// (third_party/s2n-bignum/s2n-bignum-imported/x86_att or .../arm).
//
const s2n_bignum_sources = [_][]const u8{
    "p256/p256_montjscalarmul.S",
    "p256/p256_montjscalarmul_alt.S",
    "p256/bignum_montinv_p256.S",
    "p384/bignum_add_p384.S",
    "p384/bignum_sub_p384.S",
    "p384/bignum_neg_p384.S",
    "p384/bignum_tomont_p384.S",
    "p384/bignum_deamont_p384.S",
    "p384/bignum_montmul_p384.S",
    "p384/bignum_montmul_p384_alt.S",
    "p384/bignum_montsqr_p384.S",
    "p384/bignum_montsqr_p384_alt.S",
    "p384/bignum_nonzero_6.S",
    "p384/bignum_littleendian_6.S",
    "p384/p384_montjdouble.S",
    "p384/p384_montjdouble_alt.S",
    "p384/p384_montjscalarmul.S",
    "p384/p384_montjscalarmul_alt.S",
    "p384/bignum_montinv_p384.S",
    "p521/bignum_add_p521.S",
    "p521/bignum_sub_p521.S",
    "p521/bignum_neg_p521.S",
    "p521/bignum_mul_p521.S",
    "p521/bignum_mul_p521_alt.S",
    "p521/bignum_sqr_p521.S",
    "p521/bignum_sqr_p521_alt.S",
    "p521/bignum_tolebytes_p521.S",
    "p521/bignum_fromlebytes_p521.S",
    "p521/p521_jdouble.S",
    "p521/p521_jdouble_alt.S",
    "p521/p521_jscalarmul.S",
    "p521/p521_jscalarmul_alt.S",
    "p521/bignum_inv_p521.S",
    "curve25519/bignum_mod_n25519.S",
    "curve25519/bignum_neg_p25519.S",
    "curve25519/bignum_madd_n25519.S",
    "curve25519/bignum_madd_n25519_alt.S",
    "curve25519/edwards25519_decode.S",
    "curve25519/edwards25519_decode_alt.S",
    "curve25519/edwards25519_encode.S",
    "curve25519/edwards25519_scalarmulbase.S",
    "curve25519/edwards25519_scalarmulbase_alt.S",
    "curve25519/edwards25519_scalarmuldouble.S",
    "curve25519/edwards25519_scalarmuldouble_alt.S",
    "sha3/sha3_keccak_f1600.S",
    "sha3/sha3_keccak4_f1600_alt.S",
};

//
// The s2n-bignum files BCM_ASM_SOURCES adds on x86_64, relative to S2N_BIGNUM_DIR.
//
const s2n_bignum_sources_x86_64 = [_][]const u8{
    "p384/bignum_tomont_p384_alt.S",
    "p384/bignum_deamont_p384_alt.S",
    "curve25519/curve25519_x25519.S",
    "curve25519/curve25519_x25519_alt.S",
    "curve25519/curve25519_x25519base.S",
    "curve25519/curve25519_x25519base_alt.S",
};

//
// The s2n-bignum files BCM_ASM_SOURCES adds on aarch64, relative to S2N_BIGNUM_DIR.
//
const s2n_bignum_sources_aarch64 = [_][]const u8{
    "curve25519/curve25519_x25519_byte.S",
    "curve25519/curve25519_x25519_byte_alt.S",
    "curve25519/curve25519_x25519base_byte.S",
    "curve25519/curve25519_x25519base_byte_alt.S",
    "fastmul/bignum_kmul_16_32.S",
    "fastmul/bignum_kmul_32_64.S",
    "fastmul/bignum_ksqr_16_32.S",
    "fastmul/bignum_ksqr_32_64.S",
    "fastmul/bignum_emontredc_8n.S",
    "generic/bignum_ge.S",
    "generic/bignum_mul.S",
    "generic/bignum_optsub.S",
    "generic/bignum_sqr.S",
    "generic/bignum_copy_row_from_table.S",
    "generic/bignum_copy_row_from_table_8n.S",
    "generic/bignum_copy_row_from_table_16.S",
    "generic/bignum_copy_row_from_table_32.S",
};

//
// The s2n-bignum files BCM_ASM_SOURCES adds on aarch64 when MY_ASSEMBLER_SUPPORTS_NEON_SHA3_EXTENSION (which Zig's
// assembler does), compiled with -march=armv8.4-a+sha3.
//
const s2n_bignum_sources_aarch64_sha3 = [_][]const u8{
    "sha3/sha3_keccak_f1600_alt.S",
    "sha3/sha3_keccak2_f1600.S",
    "sha3/sha3_keccak4_f1600_alt2.S",
};

//
// The mlkem-native files BCM_ASM_SOURCES adds on aarch64, relative to crypto/fipsmodule/ml_kem.
//
const mlkem_native_sources_aarch64 = [_][]const u8{
    "mlkem/native/aarch64/src/intt.S",
    "mlkem/native/aarch64/src/ntt.S",
    "mlkem/native/aarch64/src/poly_mulcache_compute_asm.S",
    "mlkem/native/aarch64/src/poly_reduce_asm.S",
    "mlkem/native/aarch64/src/poly_tobytes_asm.S",
    "mlkem/native/aarch64/src/poly_tomont_asm.S",
    "mlkem/native/aarch64/src/polyvec_basemul_acc_montgomery_cached_asm_k2.S",
    "mlkem/native/aarch64/src/polyvec_basemul_acc_montgomery_cached_asm_k3.S",
    "mlkem/native/aarch64/src/polyvec_basemul_acc_montgomery_cached_asm_k4.S",
    "mlkem/native/aarch64/src/rej_uniform_asm.S",
};

//
// The mlkem-native files BCM_ASM_SOURCES adds on x86_64, relative to crypto/fipsmodule/ml_kem.
//
const mlkem_native_sources_x86_64 = [_][]const u8{
    "mlkem/native/x86_64/src/intt.S",
    "mlkem/native/x86_64/src/ntt.S",
    "mlkem/native/x86_64/src/mulcache_compute.S",
    "mlkem/native/x86_64/src/nttfrombytes.S",
    "mlkem/native/x86_64/src/ntttobytes.S",
    "mlkem/native/x86_64/src/nttunpack.S",
    "mlkem/native/x86_64/src/reduce.S",
    "mlkem/native/x86_64/src/tomont.S",
    "mlkem/native/x86_64/src/polyvec_basemul_acc_montgomery_cached_asm_k2.S",
    "mlkem/native/x86_64/src/polyvec_basemul_acc_montgomery_cached_asm_k3.S",
    "mlkem/native/x86_64/src/polyvec_basemul_acc_montgomery_cached_asm_k4.S",
    "mlkem/native/x86_64/src/rej_uniform_asm.S",
    "mlkem/native/x86_64/src/poly_compress_d10.S",
    "mlkem/native/x86_64/src/poly_compress_d11.S",
    "mlkem/native/x86_64/src/poly_compress_d4.S",
    "mlkem/native/x86_64/src/poly_compress_d5.S",
    "mlkem/native/x86_64/src/poly_decompress_d10.S",
    "mlkem/native/x86_64/src/poly_decompress_d11.S",
    "mlkem/native/x86_64/src/poly_decompress_d4.S",
    "mlkem/native/x86_64/src/poly_decompress_d5.S",
};

//
// JITTER_SOURCES, relative to third_party/jitterentropy/jitterentropy-library/src.
//
const jitter_sources = [_][]const u8{
    "jitterentropy-base.c",
    "jitterentropy-gcd.c",
    "jitterentropy-health.c",
    "jitterentropy-noise.c",
    "jitterentropy-sha3.c",
    "jitterentropy-timer.c",
};

//
// The C flags the top-level CMakeLists.txt gives every target on Linux and macOS with a GCC-compatible compiler
// (C_STANDARD 11 with extensions, `-fvisibility=hidden -fno-common`, and `-ffunction-sections -fdata-sections` for non-FIPS builds).
// The warning flags are left out: they change what the compiler reports, not what it produces.
//
const c_flags = [_][]const u8{
    "-std=gnu11",
    "-fvisibility=hidden",
    "-fno-common",
    "-ffunction-sections",
    "-fdata-sections",
};

//
// Adds the include path and the definitions every aws-lc target is compiled with: BORINGSSL_IMPLEMENTATION
// (target_compile_definitions), BORINGSSL_RELEASE_BUILD (a "Release" build that is not FIPS), `-D_XOPEN_SOURCE=700`
// (Linux only), and the positive check_compiler probes of tests/compiler_features_tests (linux_random_h.c compiles with
// Zig's compiler for Linux and not for macOS, which has no linux/random.h, with or without -DDEFINE_U32;
// stdalign_check.c and builtin_swap_check.c compile for both, on both architectures).
//
fn addCommonSettings(context: *const aws_sdk.Context, module: *std.Build.Module, dependency: *std.Build.Dependency) void {
    module.addIncludePath(dependency.path("include"));
    module.addCMacro("BORINGSSL_IMPLEMENTATION", "1");
    module.addCMacro("BORINGSSL_RELEASE_BUILD", "1");
    if (context.isLinux) {
        module.addCMacro("_XOPEN_SOURCE", "700");
        module.addCMacro("HAVE_LINUX_RANDOM_H", "1");
    }
    module.addCMacro("AWS_LC_STDALIGN_AVAILABLE", "1");
    module.addCMacro("AWS_LC_BUILTIN_SWAP_SUPPORTED", "1");
}

//
// Adds files relative to a directory of the dependency.
//
fn addSources(module: *std.Build.Module, dependency: *std.Build.Dependency, directory: []const u8, files: []const []const u8, flags: []const []const u8) void {
    module.addCSourceFiles(.{
        .root = dependency.path(directory),
        .files = files,
        .flags = flags,
    });
}

//
// Builds libcrypto.
//
pub fn build(context: *const aws_sdk.Context, dependency: *std.Build.Dependency) !*std.Build.Step.Compile {
    const b = context.b;
    // crypto/CMakeLists.txt's ASSEMBLY_SOURCE: ios-aarch64 for aarch64 on Apple, mac-<arch> for the other Apple
    // architectures, linux-<arch> on Linux.
    var generated: []const u8 = if (context.isX86_64) "generated-src/linux-x86_64/crypto" else "generated-src/linux-aarch64/crypto";
    if (context.isMacos) {
        generated = if (context.isX86_64) "generated-src/mac-x86_64/crypto" else "generated-src/ios-aarch64/crypto";
    }
    const s2n_bignum_dir = if (context.isX86_64) "third_party/s2n-bignum/s2n-bignum-imported/x86_att" else "third_party/s2n-bignum/s2n-bignum-imported/arm";

    // crypto_objects.
    const library = context.createLibrary("crypto");
    const module = library.root_module;
    addCommonSettings(context, module, dependency);
    var objects: std.ArrayList([]const u8) = .empty;
    for (crypto_objects) |file| {
        if (!std.mem.eql(u8, file, "err_data.c")) {
            try objects.append(b.allocator, file);
        }
    }
    addSources(module, dependency, "crypto", objects.items, &c_flags);
    addSources(module, dependency, "generated-src", &.{"err_data.c"}, &c_flags);
    if (context.isX86_64) {
        addSources(module, dependency, generated, &crypto_arch_sources_x86_64, &c_flags);
        addSources(module, dependency, "crypto", &.{"hrss/asm/poly_rq_mul.S"}, &c_flags);
    }
    else {
        addSources(module, dependency, generated, &crypto_arch_sources_aarch64, &c_flags);
    }

    // fipsmodule (the non-FIPS branch: bcm.c, fips_shared_support.c, cpucap/cpucap.c and BCM_ASM_SOURCES).
    const fipsmodule = context.createLibrary("crypto-fipsmodule");
    const fips = fipsmodule.root_module;
    addCommonSettings(context, fips, dependency);
    fips.addCMacro("S2N_BN_HIDE_SYMBOLS", "1");
    fips.addIncludePath(dependency.path("third_party/s2n-bignum/s2n-bignum-imported/include"));
    addSources(fips, dependency, "crypto/fipsmodule", &.{ "bcm.c", "fips_shared_support.c", "cpucap/cpucap.c" }, &c_flags);
    if (context.isX86_64) {
        addSources(fips, dependency, b.fmt("{s}/fipsmodule", .{generated}), &bcm_asm_sources_x86_64, &c_flags);
        addSources(fips, dependency, s2n_bignum_dir, &s2n_bignum_sources, &c_flags);
        addSources(fips, dependency, s2n_bignum_dir, &s2n_bignum_sources_x86_64, &c_flags);
        addSources(fips, dependency, "crypto/fipsmodule/ml_kem", &mlkem_native_sources_x86_64, &c_flags);
        addSources(fips, dependency, "", try aws_sdk.globFiles(b, dependency, "crypto/fipsmodule/ml_dsa/mldsa/native/x86_64/src", ".S"), &c_flags);
    }
    else {
        // check_compiler("neon_sha3_check.c" MY_ASSEMBLER_SUPPORTS_NEON_SHA3_EXTENSION) passes, and adds the define.
        fips.addCMacro("MY_ASSEMBLER_SUPPORTS_NEON_SHA3_EXTENSION", "1");
        addSources(fips, dependency, b.fmt("{s}/fipsmodule", .{generated}), &bcm_asm_sources_aarch64, &c_flags);
        addSources(fips, dependency, s2n_bignum_dir, &s2n_bignum_sources, &c_flags);
        addSources(fips, dependency, s2n_bignum_dir, &s2n_bignum_sources_aarch64, &c_flags);
        addSources(fips, dependency, "third_party/s2n-bignum/s2n-bignum-to-be-imported/arm/aes", &.{ "aes-xts-enc.S", "aes-xts-dec.S" }, &c_flags);
        addSources(fips, dependency, "crypto/fipsmodule/ml_kem", &mlkem_native_sources_aarch64, &c_flags);
        addSources(fips, dependency, "", try aws_sdk.globFiles(b, dependency, "crypto/fipsmodule/ml_dsa/mldsa/native/aarch64/src", ".S"), &c_flags);

        // The SHA3 files are compiled with -march=armv8.4-a+sha3.
        const sha3 = context.createLibraryForTarget("crypto-fipsmodule-sha3", context.targetWithFeatures(&.{
            @intFromEnum(std.Target.aarch64.Feature.v8_4a),
            @intFromEnum(std.Target.aarch64.Feature.sha3),
        }));
        addCommonSettings(context, sha3.root_module, dependency);
        sha3.root_module.addCMacro("S2N_BN_HIDE_SYMBOLS", "1");
        sha3.root_module.addCMacro("MY_ASSEMBLER_SUPPORTS_NEON_SHA3_EXTENSION", "1");
        sha3.root_module.addIncludePath(dependency.path("third_party/s2n-bignum/s2n-bignum-imported/include"));
        addSources(sha3.root_module, dependency, s2n_bignum_dir, &s2n_bignum_sources_aarch64_sha3, &c_flags);
        fips.linkLibrary(sha3);
    }
    module.linkLibrary(fipsmodule);

    // jitterentropy, compiled with JITTER_COMPILE_FLAGS (which include -O0: the library refuses to be optimized).
    const jitterentropy = context.createLibrary("crypto-jitterentropy");
    const jitter = jitterentropy.root_module;
    jitter.addIncludePath(dependency.path("third_party/jitterentropy/jitterentropy-library"));
    addCommonSettings(context, jitter, dependency);
    addSources(jitter, dependency, "third_party/jitterentropy/jitterentropy-library/src", &jitter_sources, &(c_flags ++ [_][]const u8{
        "-DAWSLC",
        "-fwrapv",
        "-O0",
        "-U_FORTIFY_SOURCE",
    }));
    module.linkLibrary(jitterentropy);

    // AWSLC_LINK_THREADS: Threads::Threads, which is empty on macOS, whose C library has the pthread functions.
    if (context.isLinux) {
        module.linkSystemLibrary("pthread", .{});
    }

    library.installHeadersDirectory(dependency.path("include"), "", .{});
    return library;
}
