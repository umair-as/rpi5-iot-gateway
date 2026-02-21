# Linux 6.18 bpftool builds sign.o and needs OpenSSL headers in target sysroot.
DEPENDS:append = " openssl"
