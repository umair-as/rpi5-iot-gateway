# CVE_STATUS — narrowly-evidenced VEX for sbom-cve-check matches already fixed
# in the shipped version.
#
# CVE-2024-12084: affects rsync 3.2.7/3.3.0; the shipped 3.4.0 or later is outside
# the affected set. https://nvd.nist.gov/vuln/detail/CVE-2024-12084
CVE_STATUS[CVE-2024-12084] = "fixed-version: shipped rsync is past the fixed boundary (fixed in 3.4.0)"
