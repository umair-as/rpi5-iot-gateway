# Ensure common admin paths are available for all users
# Allows tools like /sbin/ip and /usr/sbin/* to be found without sudo
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"
