/* PoseidonRust — C ABI for the Rust toolchain spike.
 *
 * Hand-written for the spike. Once the seam is proven, generate this header
 * with cbindgen so it can never drift from src/lib.rs.
 *
 * Ownership: any pointer returned by this API is owned by Rust and must be
 * released through the matching free function here. Never free it with the C/C++
 * allocator.
 */
#ifndef POSEIDON_RUST_H
#define POSEIDON_RUST_H

#ifdef __cplusplus
extern "C" {
#endif

/* Must match PRS_ABI_VERSION in src/lib.rs. */
#define PRS_ABI_VERSION 1

/* Returns PRS_ABI_VERSION as compiled into the linked Rust crate. */
int prs_abi_version(void);

/* Returns a + b (wrapping on overflow). */
int prs_add(int a, int b);

/* Returns a newly allocated "Hello from Rust, <name>!" string owned by Rust.
 * The caller must release it with prs_string_free.
 * Returns NULL on a NULL/non-UTF-8 input. */
char *prs_greet(const char *name);

/* Releases a string returned by prs_greet. NULL is a no-op. */
void prs_string_free(char *s);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* POSEIDON_RUST_H */
