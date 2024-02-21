#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

export DEBIAN_FRONTEND="noninteractive"

function log() {
  echo >&2 "$*"
}

function err() {
  log "ERROR: $*"
}

function error_exit() {
  local -r rc="$1"
  shift 1
  err "$*"
  exit "$rc"
}

# Require environment variables
[ -z "${SUBSPACE_HTTP_HOST-}" ] &&
  error_exit 1 "environment variable SUBSPACE_HTTP_HOST is required"

# Optional environment variables
# common
export SUBSPACE_BACKLINK="${SUBSPACE_BACKLINK:-/}"
export SUBSPACE_DISABLE_DNS="${SUBSPACE_DISABLE_DNS:-false}"
export SUBSPACE_DISABLE_MASQUERADE="${SUBSPACE_DISABLE_MASQUERADE:-false}"
export SUBSPACE_HTTP_ADDR="${SUBSPACE_HTTP_ADDR:-:80}"
export SUBSPACE_HTTP_INSECURE="${SUBSPACE_HTTP_INSECURE:-false}"
export SUBSPACE_LETSENCRYPT="${SUBSPACE_LETSENCRYPT:-true}"
export SUBSPACE_LISTENPORT="${SUBSPACE_LISTENPORT:-51820}"
export SUBSPACE_NAMESERVERS="${SUBSPACE_NAMESERVERS:-1.1.1.1,1.0.0.1}"
export SUBSPACE_THEME="${SUBSPACE_THEME:-green}"

# IPv4
export SUBSPACE_IPV4_POOL="${SUBSPACE_IPV4_POOL:-10.99.97.0/24}"
export SUBSPACE_IPV4_GW="${SUBSPACE_IPV4_GW:-$(echo "${SUBSPACE_IPV4_POOL-}" | cut -d '/' -f1 | sed 's/.0$/./g')1}"
export SUBSPACE_IPV4_NAT_ENABLED="${SUBSPACE_IPV4_NAT_ENABLED:-false}"

# IPv6
export SUBSPACE_IPV6_POOL="${SUBSPACE_IPV6_POOL:-fd00::10:97:0/112}"
export SUBSPACE_IPV6_GW="${SUBSPACE_IPV6_GW:-$(echo "${SUBSPACE_IPV6_POOL-}" | cut -d '/' -f1 | sed 's/:0$/:/g')1}"
export SUBSPACE_IPV6_NAT_ENABLED="${SUBSPACE_IPV6_NAT_ENABLED:-false}"

[ "$SUBSPACE_IPV4_NAT_ENABLED" == "false" ] &&
  [ "$SUBSPACE_IPV6_NAT_ENABLED" == "false" ] &&
  error_exit 2 "At least one of SUBSPACE_IPV4_NAT_ENABLED (=$SUBSPACE_IPV4_NAT_ENABLED), SUBSPACE_IPV6_NAT_ENABLED (=$SUBSPACE_IPV6_NAT_ENABLED) must be set to 'true'"

# Empty out inherited nameservers
echo "" >/etc/resolv.conf
# Set DNS servers
echo "${SUBSPACE_NAMESERVERS}" | tr "," "\n" | sed -e 's:^:nameserver :' >>/etc/resolv.conf

# Masquerading ip{6}tables setup
if [ "${SUBSPACE_DISABLE_MASQUERADE}" == "false" ]; then
  # IPv4
  if [ "${SUBSPACE_IPV4_NAT_ENABLED}" == "true" ]; then
    ! /sbin/iptables -t nat --check POSTROUTING -s "${SUBSPACE_IPV4_POOL}" -j MASQUERADE &&
      /sbin/iptables -t nat --append POSTROUTING -s "${SUBSPACE_IPV4_POOL}" -j MASQUERADE
    ! /sbin/iptables --check FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT &&
      /sbin/iptables --append FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
    ! /sbin/iptables --check FORWARD -s "${SUBSPACE_IPV4_POOL}" -j ACCEPT &&
      /sbin/iptables --append FORWARD -s "${SUBSPACE_IPV4_POOL}" -j ACCEPT
  fi

  # IPv6
  if [ "${SUBSPACE_IPV6_NAT_ENABLED}" == "true" ]; then
    ! /sbin/ip6tables -t nat --check POSTROUTING -s "${SUBSPACE_IPV6_POOL}" -j MASQUERADE &&
      /sbin/ip6tables -t nat --append POSTROUTING -s "${SUBSPACE_IPV6_POOL}" -j MASQUERADE
    ! /sbin/ip6tables --check FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT &&
      /sbin/ip6tables --append FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
    ! /sbin/ip6tables --check FORWARD -s "${SUBSPACE_IPV6_POOL}" -j ACCEPT &&
      /sbin/ip6tables --append FORWARD -s "${SUBSPACE_IPV6_POOL}" -j ACCEPT
  fi
fi

# DNS leak protection when enabled
if [ "${SUBSPACE_DISABLE_DNS}" == "false" ]; then
  # IPv4
  if [ "${SUBSPACE_IPV4_NAT_ENABLED}" == "true" ]; then
    ! /sbin/iptables -t nat --check OUTPUT -s "${SUBSPACE_IPV4_POOL}" -p udp --dport 53 -j DNAT --to "${SUBSPACE_IPV4_GW}":53 &&
      /sbin/iptables -t nat --append OUTPUT -s "${SUBSPACE_IPV4_POOL}" -p udp --dport 53 -j DNAT --to "${SUBSPACE_IPV4_GW}":53
    ! /sbin/iptables -t nat --check OUTPUT -s "${SUBSPACE_IPV4_POOL}" -p tcp --dport 53 -j DNAT --to "${SUBSPACE_IPV4_GW}":53 &&
      /sbin/iptables -t nat --append OUTPUT -s "${SUBSPACE_IPV4_POOL}" -p tcp --dport 53 -j DNAT --to "${SUBSPACE_IPV4_GW}":53
  fi
  # IPv6
  if [ "${SUBSPACE_IPV6_NAT_ENABLED}" == "true" ]; then
    ! /sbin/ip6tables --wait -t nat --check OUTPUT -s "${SUBSPACE_IPV6_POOL}" -p udp --dport 53 -j DNAT --to "${SUBSPACE_IPV6_GW}" &&
      /sbin/ip6tables --wait -t nat --append OUTPUT -s "${SUBSPACE_IPV6_POOL}" -p udp --dport 53 -j DNAT --to "${SUBSPACE_IPV6_GW}"
    ! /sbin/ip6tables --wait -t nat --check OUTPUT -s "${SUBSPACE_IPV6_POOL}" -p tcp --dport 53 -j DNAT --to "${SUBSPACE_IPV6_GW}" &&
      /sbin/ip6tables --wait -t nat --append OUTPUT -s "${SUBSPACE_IPV6_POOL}" -p tcp --dport 53 -j DNAT --to "${SUBSPACE_IPV6_GW}"
  fi
fi

#
# WireGuard ("${SUBSPACE_IPV4_POOL}")
#
umask_val=$(umask)
umask 0077
export WG_DIR="/data/wireguard"
if [ ! -d /data/wireguard ]; then
  mkdir -p "${WG_DIR}/clients" "${WG_DIR}/peers"

  # So you can cat *.conf safely
  touch "${WG_DIR}/clients/null.conf" "${WG_DIR}/peers/null.conf"

  # Generate public/private server keys
  wg genkey | tee "${WG_DIR}/server.private" | wg pubkey >"${WG_DIR}/server.public"
fi

cat <<WGSERVER >"${WG_DIR}"/server.conf
[Interface]
PrivateKey = $(cat "${WG_DIR}"/server.private)
ListenPort = ${SUBSPACE_LISTENPORT}

WGSERVER
cat "${WG_DIR}"/peers/*.conf >>"${WG_DIR}"/server.conf
umask "${umask_val}"
# Special handling of file not created by start-up script
[ -f /data/config.json ] &&
  chmod 600 /data/config.json

# Reinitialize interface if already present
ip link show wg0 2>/dev/null &&
  ip link del wg0
ip link add wg0 type wireguard

# Setup routing on the wireguard interface
[ "${SUBSPACE_IPV4_NAT_ENABLED}" == "true" ] &&
  ip addr add "${SUBSPACE_IPV4_GW}"/"$(echo "${SUBSPACE_IPV4_POOL-}" | cut -d '/' -f2)" dev wg0
[ "${SUBSPACE_IPV6_NAT_ENABLED}" == "true" ] &&
  ip addr add "${SUBSPACE_IPV6_GW}"/"$(echo "${SUBSPACE_IPV6_POOL-}" | cut -d '/' -f2)" dev wg0
wg setconf wg0 "${WG_DIR}"/server.conf
ip link set wg0 up

# dnsmasq service if DNS is enabled
if [ "${SUBSPACE_DISABLE_DNS}" == "false" ]; then
  DNSMASQ_LISTEN_ADDRESS="127.0.0.1"
  [ "${SUBSPACE_IPV4_NAT_ENABLED}" == "true" ] &&
    DNSMASQ_LISTEN_ADDRESS="${DNSMASQ_LISTEN_ADDRESS},${SUBSPACE_IPV4_GW}"
  [ "${SUBSPACE_IPV6_NAT_ENABLED}" == "true" ] &&
    DNSMASQ_LISTEN_ADDRESS="${DNSMASQ_LISTEN_ADDRESS},${SUBSPACE_IPV6_GW}"

  if [ ! -d /etc/service/dnsmasq ]; then
    # create the path and all its components
    mkdir -p /etc/service/dnsmasq/log/main
    # dnsmasq configuration file
    cat <<DNSMASQ >/etc/dnsmasq.conf
    # Only listen on necessary addresses.
    listen-address=${DNSMASQ_LISTEN_ADDRESS}
    interface=wg0

    # Never forward plain names (without a dot or domain part)
    domain-needed

    # Never forward addresses in the non-routed address spaces.
    bogus-priv

    # Allow extending dnsmasq by providing custom configurations.
    conf-dir=/etc/dnsmasq.d
DNSMASQ

    # dnsmasq runit definition
    cat <<RUNIT >/etc/service/dnsmasq/run
#!/bin/sh
exec /usr/sbin/dnsmasq --keep-in-foreground
RUNIT

    # dnsmasq service log
    cat <<RUNIT >/etc/service/dnsmasq/log/run
#!/bin/sh
exec svlogd -tt ./main
RUNIT

    # make runits executable
    chmod +x /etc/service/dnsmasq/run /etc/service/dnsmasq/log/run
  fi
fi

# subspace service
if [ ! -d /etc/service/subspace ]; then
  # create the path and all its components
  mkdir -p /etc/service/subspace/log/main

  # subspace runit definition
  cat <<RUNIT >/etc/service/subspace/run
#!/bin/sh
source /etc/envvars
exec /usr/bin/subspace \
    "--http-host=${SUBSPACE_HTTP_HOST}" \
    "--http-addr=${SUBSPACE_HTTP_ADDR}" \
    "--http-insecure=${SUBSPACE_HTTP_INSECURE}" \
    "--backlink=${SUBSPACE_BACKLINK}" \
    "--letsencrypt=${SUBSPACE_LETSENCRYPT}" \
    "--theme=${SUBSPACE_THEME}"
RUNIT

  # subspace service log
  cat <<RUNIT >/etc/service/subspace/log/run
#!/bin/sh
exec svlogd -tt ./main
RUNIT

  # make runits executable
  chmod +x /etc/service/subspace/run /etc/service/subspace/log/run
fi

exec "$@"
