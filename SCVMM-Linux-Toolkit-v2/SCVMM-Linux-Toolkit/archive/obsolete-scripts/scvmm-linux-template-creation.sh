
#!/usr/bin/env bash
#
# SCVMM Linux Template Creation
# Ubuntu Server 26.04
# SCVMM 2025 UR1
#
# Step 1: Agent installation (previously completed)
# Step 2: Specialization ownership
#

set -Eeuo pipefail

VERSION="0.1"
SCRIPT_NAME="scvmm-linux-template-creation"

LOG_DIR="/var/log/scvmm-template"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}-${TIMESTAMP}.log"

DRY_RUN=0
CONTINUE_ON_ERROR=1

# --------------------------------------------------
# Root check
# --------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "Please run with sudo:"
    echo "sudo bash $0"
    exit 1
fi

# --------------------------------------------------
# Logging initialization
# --------------------------------------------------

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

# --------------------------------------------------
# Logging
# --------------------------------------------------

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

error() {
    log "ERROR: $*"
}

warning() {
    log "WARNING: $*"
}

# --------------------------------------------------
# Error handling
# --------------------------------------------------

error_handler() {
    local exit_code=$?
    local line_number=$1
    local command="$2"

    echo
    error "Command failed."
    error "Exit code: ${exit_code}"
    error "Line: ${line_number}"
    error "Command: ${command}"

    return "$exit_code"
}

trap 'error_handler "$LINENO" "$BASH_COMMAND"' ERR


# --------------------------------------------------
# User interaction
# --------------------------------------------------

ask_yes_no() {
    local prompt="$1"
    local answer

    while true; do
        read -r -p "$prompt [y/N]: " answer

        case "$answer" in
            [Yy]|[Yy][Ee][Ss])
                return 0
                ;;
            [Nn]|[Nn][Oo]|"")
                return 1
                ;;
            *)
                echo "Please answer y or n."
                ;;
        esac
    done
}

run_command() {
    if [[ $DRY_RUN -eq 1 ]]; then
        log "DRY RUN: $*"
    else
        "$@"
    fi
}

# --------------------------------------------------
# Step tracking
# --------------------------------------------------

STEP_FAILURES=0
STEP_SKIPPED=0
STEP_COMPLETED=0

run_step() {
    local step_name="$1"
    local step_function="$2"

    echo
    log "================================================"
    log "STARTING: $step_name"
    log "================================================"

    if "$step_function"; then
        ((STEP_COMPLETED+=1))
        log "SUCCESS: $step_name"
    else
        ((STEP_FAILURES+=1))
        error "FAILED: $step_name"

        if [[ $CONTINUE_ON_ERROR -eq 1 ]]; then
            if ! ask_yes_no "Continue with the next step?"; then
                log "Execution stopped by user."
                exit 1
            fi
        else
            exit 1
        fi
    fi
}

# ==================================================
# STEP 1 - AGENT CHECK
# ==================================================

step1_agent_check() {

    log "Checking SCVMM Guest Agent."

    if [[ ! -d /opt/microsoft/scvmmguestagent ]]; then
        error "SCVMM Guest Agent directory not found."
        return 1
    fi

    log "Agent installation directory exists."

    return 0
}

# ==================================================
# STEP 2 - SPECIALIZATION OWNERSHIP
# ==================================================

step2_cloud_init() {

    local marker="/etc/cloud/cloud-init.disabled"

    echo
    log "Checking cloud-init specialization ownership."

    # ----------------------------------------------
    # Check installation
    # ----------------------------------------------

    if ! dpkg-query -W -f='${Status}' cloud-init 2>/dev/null |
        grep -q "install ok installed"; then

        log "cloud-init is not installed."
        log "Nothing to disable."
        return 0
    fi

    log "cloud-init package is installed."

    # ----------------------------------------------
    # Check disabled marker
    # ----------------------------------------------

    if [[ -f "$marker" ]]; then
        log "cloud-init disable marker already exists."
        log "Cloud-init is already configured as disabled."
        return 0
    fi

    # ----------------------------------------------
    # Inspect service states
    # ----------------------------------------------

    log "Inspecting cloud-init services."

    for service in \
        cloud-init-local.service \
        cloud-init.service \
        cloud-config.service \
        cloud-final.service
    do
        if systemctl list-unit-files "$service" \
            --no-legend 2>/dev/null | grep -q "$service"; then

            STATE="$(systemctl is-enabled "$service" 2>/dev/null || true)"
            ACTIVE="$(systemctl is-active "$service" 2>/dev/null || true)"

            log "$service: enabled=$STATE active=$ACTIVE"
        else
            log "$service: unit not found."
        fi
    done

    # ----------------------------------------------
    # Check cloud-init status
    # ----------------------------------------------

    log "Current cloud-init status:"

    if command -v cloud-init >/dev/null 2>&1; then
        cloud-init status --long 2>&1 || true
    fi

    # ----------------------------------------------
    # Inspect Netplan
    # ----------------------------------------------

    echo
    log "Checking Netplan configuration."

    if [[ -d /etc/netplan ]]; then

        find /etc/netplan -maxdepth 1 -type f \
            -printf '%f\n' | while read -r file; do
                log "Netplan file found: $file"
            done

        if grep -Rqs "renderer:" /etc/netplan; then
            log "Netplan renderer configuration found."
        else
            warning "No explicit Netplan renderer found."
        fi

    else
        warning "/etc/netplan directory not found."
    fi

    # ----------------------------------------------
    # Require confirmation
    # ----------------------------------------------

    echo
    echo "CLOUD-INIT SPECIALIZATION DECISION"
    echo "----------------------------------"
    echo "SCVMM is intended to own hostname and network"
    echo "customization on first boot."
    echo
    echo "Before disabling cloud-init, confirm that:"
    echo "  1. Your existing network configuration works."
    echo "  2. Netplan or another network manager owns it."
    echo "  3. You do not require cloud-init for other setup."
    echo

    if ! ask_yes_no "Disable cloud-init for SCVMM specialization?"; then
        log "User elected to leave cloud-init unchanged."
        return 0
    fi

    # ----------------------------------------------
    # Clean existing cloud-init state
    # ----------------------------------------------

    echo
    log "Cleaning existing cloud-init instance state."

    if [[ $DRY_RUN -eq 0 ]]; then
        if ! cloud-init clean --logs --seed; then
            error "cloud-init clean failed."
            return 1
        fi
    else
        log "DRY RUN: cloud-init clean --logs --seed"
    fi

    # ----------------------------------------------
    # Disable cloud-init using supported marker
    # ----------------------------------------------

    log "Creating cloud-init disabled marker."

    if [[ $DRY_RUN -eq 0 ]]; then
        install -d -m 0755 /etc/cloud
        touch "$marker"
        chmod 0644 "$marker"
    else
        log "DRY RUN: create $marker"
    fi

    # ----------------------------------------------
    # Verify
    # ----------------------------------------------

    if [[ $DRY_RUN -eq 0 ]]; then
        [[ -f "$marker" ]] || {
            error "Cloud-init disable marker was not created."
            return 1
        }
    fi

    log "Cloud-init neutralization completed."
    log "Package remains installed."
    log "Existing Netplan files were preserved."

    return 0
}



# ==================================================
# STEP 3 - MACHINE ID CLEANUP
# ==================================================

step3_machine_id() {

    local MACHINE_ID_FILE="/etc/machine-id"
    local DBUS_ID_FILE="/var/lib/dbus/machine-id"
    local CURRENT_ID=""

    log "Checking system machine identity."

    # ----------------------------------------------
    # Check machine-id file
    # ----------------------------------------------

    if [[ ! -e "$MACHINE_ID_FILE" ]]; then
        error "/etc/machine-id is missing."
        return 1
    fi

    if [[ -L "$MACHINE_ID_FILE" ]]; then
        error "/etc/machine-id must be a regular file."
        return 1
    fi

    CURRENT_ID="$(tr -d '\n' < "$MACHINE_ID_FILE")"

    # ----------------------------------------------
    # Check DBus symlink
    # ----------------------------------------------

    if [[ -L "$DBUS_ID_FILE" ]]; then

        if [[ "$(readlink "$DBUS_ID_FILE")" == "/etc/machine-id" ]]; then
            log "DBus machine-id symlink is correct."
        else
            error "DBus machine-id symlink points elsewhere."
            return 1
        fi

    elif [[ -e "$DBUS_ID_FILE" ]]; then

        warning "DBus machine-id is a regular file, not a symlink."

        if [[ "$(cat "$DBUS_ID_FILE")" != "$CURRENT_ID" ]]; then
            error "DBus machine-id differs from system machine-id."
            return 1
        fi

        if ! ask_yes_no "Replace DBus machine-id with correct symlink?"; then
            log "DBus symlink repair skipped."
            return 1
        fi

        if [[ $DRY_RUN -eq 0 ]]; then
            rm -f "$DBUS_ID_FILE"
            ln -s /etc/machine-id "$DBUS_ID_FILE"
        else
            log "DRY RUN: replace DBus machine-id with symlink."
        fi

    else

        warning "DBus machine-id is missing."

        if ask_yes_no "Create DBus machine-id symlink?"; then
            if [[ $DRY_RUN -eq 0 ]]; then
                install -d -m 0755 /var/lib/dbus
                ln -s /etc/machine-id "$DBUS_ID_FILE"
            else
                log "DRY RUN: create DBus machine-id symlink."
            fi
        else
            return 1
        fi

    fi

    # ----------------------------------------------
    # Check whether already generalized
    # ----------------------------------------------

    if [[ -z "$CURRENT_ID" ]]; then
        log "Machine ID is already empty."
        log "No machine identity cleanup required."
        return 0
    fi

    if [[ ! "$CURRENT_ID" =~ ^[[:xdigit:]]{32}$ ]]; then
        error "Machine ID has an unexpected format."
        return 1
    fi

    log "A valid source machine ID exists."

    # ----------------------------------------------
    # Ask before cleanup
    # ----------------------------------------------

    echo
    echo "MACHINE ID CLEANUP"
    echo "------------------"
    echo "This removes the source VM identity."
    echo "The deployed VM should generate a new ID."
    echo

    if ! ask_yes_no "Clear the source machine ID now?"; then
        log "Machine ID cleanup skipped by user."
        return 0
    fi

    # ----------------------------------------------
    # Clear machine identity
    # ----------------------------------------------

    if [[ $DRY_RUN -eq 0 ]]; then

        truncate -s 0 "$MACHINE_ID_FILE"
        chmod 0444 "$MACHINE_ID_FILE"

    else

        log "DRY RUN: truncate /etc/machine-id"

    fi

   # ----------------------------------------------
# Verify
# ----------------------------------------------

if [[ $DRY_RUN -eq 1 ]]; then
    log "DRY RUN: Machine ID was NOT modified."
    return 0
fi

if [[ -s "$MACHINE_ID_FILE" ]]; then
    error "Machine ID was not cleared."
    return 1
fi

if [[ ! -L "$DBUS_ID_FILE" ]]; then
    error "DBus machine-id symlink verification failed."
    return 1
fi

if [[ "$(readlink "$DBUS_ID_FILE")" != "/etc/machine-id" ]]; then
    error "DBus symlink target is incorrect."
    return 1
fi

log "Machine ID successfully cleared."
log "DBus machine-id symlink preserved."

return 0
}


# ==================================================
# STEP 4 - SSH HOST KEY CLEANUP
# ==================================================

step4_ssh_keys() {

    local SSH_DIR="/etc/ssh"
    local KEYGEN_SERVICE="sshd-keygen.service"
    local KEY_COUNT=0
    local KEY

    log "Checking SSH host key configuration."

    # ----------------------------------------------
    # Check SSH installation
    # ----------------------------------------------

    if ! command -v sshd >/dev/null 2>&1; then
        error "OpenSSH server is not installed."
        return 1
    fi

    if ! systemctl is-enabled ssh.service >/dev/null 2>&1; then
        warning "SSH service is not enabled."
    else
        log "SSH service is enabled."
    fi

    # ----------------------------------------------
    # Validate current SSH configuration
    # ----------------------------------------------

    log "Validating SSH configuration."

    if ! sshd -t; then
        error "SSH configuration validation failed."
        return 1
    fi

    log "SSH configuration is valid."

    # ----------------------------------------------
    # Check host key regeneration service
    # ----------------------------------------------

    if [[ ! -f "/usr/lib/systemd/system/${KEYGEN_SERVICE}" ]]; then
        error "SSH host key generation service is missing."
        return 1
    fi

    log "SSH key regeneration service exists."

    if ! grep -q 'ConditionFirstBoot=yes' \
        "/usr/lib/systemd/system/${KEYGEN_SERVICE}"; then

        error "Expected first-boot condition not found."
        return 1
    fi

    log "First-boot generation condition verified."

    if ! grep -q 'ExecStart=ssh-keygen -A' \
        "/usr/lib/systemd/system/${KEYGEN_SERVICE}"; then

        error "Expected ssh-keygen command not found."
        return 1
    fi

    log "SSH key generation command verified."

    # ----------------------------------------------
    # Check service enablement
    # ----------------------------------------------

    local ENABLE_STATE

    ENABLE_STATE="$(systemctl is-enabled "$KEYGEN_SERVICE" 2>/dev/null || true)"

    log "SSH key generation service state: $ENABLE_STATE"

    if [[ "$ENABLE_STATE" != "enabled" ]]; then

        if ! ask_yes_no "Enable SSH host key regeneration service?"; then
            error "SSH host key regeneration is not enabled."
            return 1
        fi

        if [[ $DRY_RUN -eq 0 ]]; then
            systemctl enable "$KEYGEN_SERVICE" ||
                return 1
        else
            log "DRY RUN: systemctl enable $KEYGEN_SERVICE"
        fi
    fi

    # ----------------------------------------------
    # Find existing host keys
    # ----------------------------------------------

    local -a HOST_KEYS=()

    while IFS= read -r -d '' KEY; do
        HOST_KEYS+=("$KEY")
    done < <(
        find "$SSH_DIR" -maxdepth 1 -type f \
            \( -name 'ssh_host_*_key' \
            -o -name 'ssh_host_*_key.pub' \) \
            -print0
    )

    KEY_COUNT="${#HOST_KEYS[@]}"

    log "Existing SSH host key files: $KEY_COUNT"

    # ----------------------------------------------
    # Already cleaned?
    # ----------------------------------------------

    if [[ "$KEY_COUNT" -eq 0 ]]; then
        log "No SSH host keys found."
        log "Host key cleanup already completed."
        return 0
    fi

    echo
    echo "SSH HOST KEY CLEANUP"
    echo "--------------------"
    echo "The following source VM host keys exist:"

    for KEY in "${HOST_KEYS[@]}"; do
        echo "  $KEY"
    done

    echo
    echo "These keys must be unique on each deployed VM."
    echo "They will NOT be backed up into the template."
    echo "Ubuntu will generate new keys on first boot."
    echo

    if ! ask_yes_no "Remove the existing SSH host keys?"; then
        log "SSH host key cleanup skipped."
        return 0
    fi

    # ----------------------------------------------
    # Remove source host keys
    # ----------------------------------------------

    if [[ $DRY_RUN -eq 1 ]]; then
        for KEY in "${HOST_KEYS[@]}"; do
            log "DRY RUN: remove $KEY"
        done

        log "DRY RUN: SSH host keys were NOT removed."
        return 0
    fi

    for KEY in "${HOST_KEYS[@]}"; do
        rm -f -- "$KEY" || {
            error "Failed to remove $KEY"
            return 1
        }

        log "Removed: $KEY"
    done

    # ----------------------------------------------
    # Verify
    # ----------------------------------------------

    local REMAINING

    REMAINING="$(find "$SSH_DIR" -maxdepth 1 -type f \
        \( -name 'ssh_host_*_key' \
        -o -name 'ssh_host_*_key.pub' \) | wc -l)"

    if [[ "$REMAINING" -ne 0 ]]; then
        error "SSH host key cleanup incomplete."
        return 1
    fi

    log "All source SSH host keys removed."
    log "SSH host key regeneration remains enabled."
    log "New host keys will be verified on the first deployed VM."

    return 0
}


# ==================================================
# STEP 5 - NETWORK IDENTITY INSPECTION
# ==================================================

step5_network() {

    local NETPLAN_DIR="/etc/netplan"
    local NM_DIR="/etc/NetworkManager/system-connections"
    local UDEV_RULE="/etc/udev/rules.d/70-persistent-net.rules"

    log "Starting network identity inspection."

    # ----------------------------------------------
    # Check network utilities
    # ----------------------------------------------

    for utility in ip find grep; do
        if ! command -v "$utility" >/dev/null 2>&1; then
            error "Required utility missing: $utility"
            return 1
        fi
    done

    # ----------------------------------------------
    # Network interfaces
    # ----------------------------------------------

    echo
    log "Current network interfaces."

    ip -brief address 2>&1 | tee -a "$LOG_FILE"

    # ----------------------------------------------
    # Routing information
    # ----------------------------------------------

    echo
    log "Current routing table."

    ip route show 2>&1 | tee -a "$LOG_FILE"

    # ----------------------------------------------
    # DNS configuration
    # ----------------------------------------------

    echo
    log "Current DNS configuration."

    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl status 2>&1 | tee -a "$LOG_FILE"
    else
        log "resolvectl not available."
    fi

    # ----------------------------------------------
    # Netplan inspection
    # ----------------------------------------------

    echo
    log "Inspecting Netplan configuration."

    if [[ -d "$NETPLAN_DIR" ]]; then

        while IFS= read -r -d '' FILE; do

            log "Netplan file: $FILE"

            grep -nE \
                'renderer:|dhcp4:|dhcp6:|addresses:|gateway4:|routes:|via:|macaddress:|match:|set-name:|nameservers:' \
                "$FILE" 2>/dev/null |
                tee -a "$LOG_FILE" || true

        done < <(
            find "$NETPLAN_DIR" -maxdepth 1 \
                -type f -name '*.yaml' -print0
        )

    else

        warning "Netplan directory not found."

    fi


    # ----------------------------------------------
    # NetworkManager inspection
    # ----------------------------------------------

    echo
    log "Inspecting NetworkManager."

    if command -v nmcli >/dev/null 2>&1; then

        # Connection summary

        log "NetworkManager connection summary."

        nmcli -t -f \
            NAME,UUID,TYPE,DEVICE \
            connection show 2>&1 |
            tee -a "$LOG_FILE"

        # Detailed connection profiles

        echo
        log "NetworkManager detailed connection properties."

        while IFS= read -r PROFILE; do

            [[ -n "$PROFILE" ]] || continue

            log "Inspecting profile: $PROFILE"

            nmcli connection show "$PROFILE" 2>&1 |
                tee -a "$LOG_FILE"

        done < <(
            nmcli -t -f NAME connection show
        )

    else

        log "NetworkManager command not installed."

    fi

    # ----------------------------------------------
    # NetworkManager profile directory
    # ----------------------------------------------

    echo
    log "Checking NetworkManager connection profiles."

    if [[ -d "$NM_DIR" ]]; then

        find "$NM_DIR" -maxdepth 1 -type f \
            -printf '%f\n' |
            tee -a "$LOG_FILE"

    else

        log "NetworkManager connection directory not found."

    fi

    # ----------------------------------------------
    # DHCP lease inspection
    # ----------------------------------------------

    echo
    log "Inspecting DHCP lease files."

    for DIR in \
        /var/lib/dhcp \
        /var/lib/NetworkManager
    do

        if [[ -d "$DIR" ]]; then

            find "$DIR" -maxdepth 1 -type f \
                \( -name '*.lease' \
                -o -name '*.leases' \
                -o -name 'dhclient*.leases*' \
                -o -name 'dhclient*.lease*' \) \
                -printf '%p\n' |
                tee -a "$LOG_FILE"

        fi

    done

    # ----------------------------------------------
    # Persistent NIC naming
    # ----------------------------------------------

    echo
    log "Checking persistent NIC naming rules."

    if [[ -f "$UDEV_RULE" ]]; then

        warning "Persistent network rule found:"
        log "$UDEV_RULE"

    else

        log "No legacy persistent NIC rule found."

    fi

    # ----------------------------------------------
    # Network customization assessment
    # ----------------------------------------------

    echo
    echo "NETWORK CONFIGURATION ASSESSMENT"
    echo "--------------------------------"
    echo "The current network configuration has"
    echo "been inspected and recorded."
    echo
    echo "No Netplan files were modified."
    echo "No NetworkManager profiles were modified."
    echo "No DHCP leases were removed."
    echo "No network services were restarted."
    echo

    echo "Review the network configuration before"
    echo "proceeding with generalization."
    echo

    log "Network identity inspection completed."
    log "No network configuration changes were made."

    return 0
}


# ==================================================
# MAIN
# ==================================================

echo
echo "================================================"
echo " SCVMM LINUX TEMPLATE CREATION v${VERSION}"
echo "================================================"
echo "OS: Ubuntu Server"
echo "SCVMM: 2025 UR1"
echo "Log: $LOG_FILE"

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
    log "DRY RUN ENABLED."
fi

if [[ "${1:-}" == "--stop-on-error" ]]; then
    CONTINUE_ON_ERROR=0
fi

# Step 1 is a verification because agent installation
# has already been completed manually.

run_step "Step 1 - Guest Agent Verification" step1_agent_check

run_step "Step 2 - Specialization Ownership" step2_cloud_init

# Future steps will be added here:
#
run_step "Step 3 - Machine Identity" step3_machine_id
run_step "Step 4 - SSH Host Keys" step4_ssh_keys
run_step "Step 5 - Network Cleanup" step5_network
# run_step "Step 6 - Subscription Identity" step6_subscription
# run_step "Step 7 - Disk Preparation" step7_disk
# run_step "Step 8 - Final Validation" step8_validation
# run_step "Step 9 - Shutdown Readiness" step9_shutdown

echo
echo "================================================"
echo " EXECUTION SUMMARY"
echo "================================================"

echo "Completed: $STEP_COMPLETED"
echo "Failed:    $STEP_FAILURES"
echo "Skipped:   $STEP_SKIPPED"
echo
echo "Log: $LOG_FILE"
echo

if [[ $STEP_FAILURES -gt 0 ]]; then
    echo "Completed with errors."
    exit 1
fi

echo "Template preparation steps completed."
