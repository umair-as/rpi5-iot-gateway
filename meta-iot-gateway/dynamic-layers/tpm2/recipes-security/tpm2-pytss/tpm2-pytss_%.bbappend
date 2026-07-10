# tpm2-pytss upstream declares runtime libs under setup_requires in setup.cfg.
# setuptools then tries to fetch wheels via pip during do_compile (offline fail).
# Clear setup_requires so build uses Yocto-provided native deps only.
DEPENDS:append = " python3-cffi-native python3-setuptools-scm-native"

do_configure:append() {
    if [ -f ${S}/setup.cfg ]; then
        awk '
            BEGIN { drop = 0 }
            {
                if ($0 ~ /^setup_requires[[:space:]]*=/) {
                    print "setup_requires ="
                    drop = 1
                    next
                }

                if (drop == 1) {
                    if ($0 ~ /^[[:space:]]+/) {
                        next
                    }
                    drop = 0
                }

                print
            }
        ' ${S}/setup.cfg > ${S}/setup.cfg.new
        mv ${S}/setup.cfg.new ${S}/setup.cfg
    fi
}
