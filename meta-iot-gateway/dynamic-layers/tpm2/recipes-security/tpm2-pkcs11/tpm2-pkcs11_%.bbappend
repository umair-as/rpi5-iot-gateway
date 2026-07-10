# Ensure the Python front-end tool has its runtime backend available.
# Without this, /usr/bin/tpm2_ptool fails with ModuleNotFoundError: tpm2_pytss.
RDEPENDS:${PN}-tools:append = " tpm2-pytss"
