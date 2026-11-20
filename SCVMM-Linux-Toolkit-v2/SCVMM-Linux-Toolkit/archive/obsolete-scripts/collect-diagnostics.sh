#!/usr/bin/env bash

set -u

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="/var/log/scvmm-template/diagnostics-${TIMESTAMP}.txt"

mkdir -p /var/log/scvmm-template

if [[ $EUID -ne 0 ]]; then
    echo "Run using: sudo bash $0"
    exit 1
fi

exec > >(tee "$REPORT") 2>&1

section() {
    echo
    echo "================================================"
    echo "$1"
    echo "================================================"
}

run() {
    echo
    echo "COMMAND: $*"
    "$@" 2>&1 || echo "WARNING: Command returned non-zero status."
}

section "UBUNTU SYSTEM INFORMATION"
run hostnamectl
run cat /etc/os-release
run uname -r

section "MACHINE ID"
run cat /etc/machine-id
run ls -l /var/lib/dbus/machine-id

section "SSH HOST KEYS"
run ls -la /etc/ssh
run systemctl is-enabled sshd-keygen.service
run systemctl status sshd-keygen.service --no-pager
run systemctl cat sshd-keygen.service

section "NETWORK INTERFACES"
run ip -brief address
run ip route show
run resolvectl status

section "NETPLAN CONFIGURATION"
run netplan get
run ls -la /etc/netplan

for FILE in /etc/netplan/*.yaml; do
    [[ -f "$FILE" ]] || continue
    section "NETPLAN FILE: $FILE"
    run cat "$FILE"
done

section "NETWORKMANAGER CONNECTIONS"
run nmcli connection show
run nmcli -f all connection show netplan-eth0

section "NETWORKMANAGER SERVICES"
run systemctl status NetworkManager --no-pager
run systemctl status systemd-networkd --no-pager

section "DHCP LEASE FILES"
for DIR in /var/lib/dhcp /var/lib/NetworkManager; do
    if [[ -d "$DIR" ]]; then
        run find "$DIR" -maxdepth 2 -type f -ls
    fi
done

section "PERSISTENT NETWORK RULES"
run find /etc/udev/rules.d -maxdepth 1 -type f -ls

section "CLOUD-INIT"
run dpkg-query -W cloud-init
run ls -la /etc/cloud/cloud-init.disabled

section "SCVMM AGENT"
run ls -la /opt/microsoft/scvmmguestagent

section "FILESYSTEM"
run findmnt
run df -h
run lsblk -f

section "DIAGNOSTIC REPORT COMPLETE"

echo
echo "Report saved to:"
echo "$REPORT"
