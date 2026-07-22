#!/bin/sh
# Prepare the /data-backed log backing dirs and their volatile mountpoints
# BEFORE systemd-journal-flush / auditd run.
#
# systemd-journal-flush.service is ordered Before=systemd-tmpfiles-setup.service
# and RequiresMountsFor=/var/log/journal, so the journal bind (and therefore its
# backing dir + mountpoint) must be ready earlier than the normal tmpfiles pass.
# Ordering a .mount After=systemd-tmpfiles-setup.service would create a cycle
# (flush -> mount -> tmpfiles -> flush); this oneshot creates the directories
# early instead, so the mounts only depend on it.
set -e

# Persistent backing on /data.
install -d -m 0755 -o root -g root /data/log
install -d -m 2755 -o root -g systemd-journal /data/log/journal
install -d -m 0700 -o root -g root /data/log/audit

# Mountpoints on the volatile /var/volatile/log tmpfs (/var/log -> volatile/log).
install -d -m 0755 -o root -g root /var/volatile/log
install -d -m 2755 -o root -g systemd-journal /var/volatile/log/journal
install -d -m 0700 -o root -g root /var/volatile/log/audit
