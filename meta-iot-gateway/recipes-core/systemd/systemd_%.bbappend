# pstore PACKAGECONFIG enables systemd-pstore.service, which archives
# kernel pstore records to /var/lib/systemd/pstore at boot. Tied to the
# pstore-persist layer (default-on); the bind mount onto /data is provided
# by iotgw-pstore-persist.
PACKAGECONFIG:append = "${@bb.utils.contains('IOTGW_ENABLE_PSTORE_PERSIST_EFFECTIVE', '1', ' pstore', '', d)}"
