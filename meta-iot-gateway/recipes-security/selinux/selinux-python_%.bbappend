# sepolicy-generate only adds binutils to the RDEPENDS of the sepolicy package
# (`sepolicy generate` reads ELF symbols to draft a module). Policy is written
# and compiled on the build host, never on the device, so the appliance does
# not need it, and keeping it would ship binutils with libbfd/libopcodes
# (~12 MB) in every image, prod included. The sepolicy tool itself stays.
PACKAGECONFIG:remove = "sepolicy-generate"
