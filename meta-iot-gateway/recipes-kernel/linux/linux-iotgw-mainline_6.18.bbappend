# No generated kernel CVE exclusion list: sbom-cve-check reads the kernel CNA's
# affected/fixed ranges from cvelistV5, and a generated list can override
# fresher CNA data with stale verdicts. Keep the CVE database pin
# (iotgw-cve-db.inc) about as fresh as the kernel pin, and add CVE_STATUS here
# only per finding, with its evidence.

