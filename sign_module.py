#!/usr/bin/env python3
"""
Self-contained Linux kernel module signer (matches CONFIG_MODULE_SIG_SHA512).
Implements the same layout as scripts/sign-file:
  <unsigned module bytes> + <PKCS#7 DER signature> + <struct module_signature 12B> + "~Module signature appended~\n"

struct module_signature (12 bytes):
  u8 algo; u8 hash; u8 id_type; u8 signer_len; u8 key_id_len; u8 pad[3]; be32 sig_len
  For PKEY_ID_PKCS7: algo=0, hash=0(PKCS7 carries it), id_type=2, signer_len=0, key_id_len=0
"""
import subprocess
import struct
import sys

def main():
    if len(sys.argv) != 5:
        print("usage: sign_module.py <unsigned.ko> <cert.pem> <key.pem> <signed.ko>")
        sys.exit(1)
    ko, cert, key, out = sys.argv[1:5]

    body = open(ko, "rb").read()

    # PKCS#7 detached signature (CMS), SHA512, no attributes, binary, DER
    sig = subprocess.run(
        ["openssl", "cms", "-sign", "-binary", "-noattr", "-md", "sha512",
         "-in", ko, "-signer", cert, "-inkey", key, "-outform", "DER"],
        capture_output=True, check=True,
    ).stdout

    # struct module_signature: algo=0 hash=0 id_type=2 signer_len=0 key_id_len=0 pad[3]=0 sig_len=len(sig)
    modsig = struct.pack(
        ">BBBBBBBBI", 0, 0, 2, 0, 0, 0, 0, 0, len(sig)
    )
    assert len(modsig) == 12, len(modsig)

    marker = b"~Module signature appended~\n"  # 28 bytes
    with open(out, "wb") as f:
        f.write(body)
        f.write(sig)
        f.write(modsig)
        f.write(marker)

    print(f"signed: {out}  body={len(body)} sig={len(sig)} total={len(body)+len(sig)+12+28}")

if __name__ == "__main__":
    main()
