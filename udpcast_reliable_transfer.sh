#!/bin/bash

# UDP Cast Reliable Transfer Script
# Provides highly reliable file transfer over gigabit connections
# Automatically manages remote receivers from Ansible inventory

set -euo pipefail

# Configuration
SCRIPT_NAME="$(basename "$0")"
LOG_DIR="${LOG_DIR:-$HOME/.udpcast/logs}"  # Default to user directory, allow override
INVENTORY_FILE="/etc/ansible/inventory/foundation"
GROUP_NAME="Foundation"
UDP_PORT_BASE=9000
TRANSFER_TIMEOUT=3600  # 1 hour timeout
SSH_TIMEOUT=30
MAX_RETRIES=5

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level=$1
    shift
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo -e "$message"
    # Only log to file if LOG_DIR is available
    if [[ -n "$LOG_DIR" && -w "$LOG_DIR" ]]; then
        echo -e "$message" >> "$LOG_DIR/$SCRIPT_NAME.log"
    fi
}

info() { log "${BLUE}INFO${NC}" "$@"; }
warn() { log "${YELLOW}WARN${NC}" "$@"; }
error() { log "${RED}ERROR${NC}" "$@"; }
success() { log "${GREEN}SUCCESS${NC}" "$@"; }

# Usage function
usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS] <image_file>

Highly reliable UDP Cast transfer over gigabit networks.
Automatically manages remote receivers from Ansible inventory.

Arguments:
    image_file          Path to the file/image to transfer

Options:
    -i, --inventory FILE    Ansible inventory file (default: $INVENTORY_FILE)
    -g, --group NAME        Ansible group name (default: $GROUP_NAME)
    -p, --port PORT         UDP port base (default: $UDP_PORT_BASE)
    -b, --bandwidth RATE    Max bandwidth (e.g., 800m for 800Mbps)
    -c, --compression       Enable compression (gzip)
    -d, --dry-run          Show what would be done without executing
    -t, --timeout SECONDS  Transfer timeout (default: $TRANSFER_TIMEOUT)
    -l, --log-dir DIR      Log directory (default: $LOG_DIR)
    -v, --verbose          Verbose output
    -h, --help             Show this help

Examples:
    $SCRIPT_NAME /path/to/system.img
    $SCRIPT_NAME -b 900m -c /path/to/backup.tar
    $SCRIPT_NAME -i /custom/inventory -g servers disk_image.dd

EOF
}

# Parse command line arguments
BANDWIDTH="900m"  # Conservative for gigabit (leaves headroom)
USE_COMPRESSION=false
DRY_RUN=false
VERBOSE=false
IMAGE_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--inventory)
            INVENTORY_FILE="$2"
            shift 2
            ;;
        -g|--group)
            GROUP_NAME="$2"
            shift 2
            ;;
        -p|--port)
            UDP_PORT_BASE="$2"
            shift 2
            ;;
        -b|--bandwidth)
            BANDWIDTH="$2"
            shift 2
            ;;
        -c|--compression)
            USE_COMPRESSION=true
            shift
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -t|--timeout)
            TRANSFER_TIMEOUT="$2"
            shift 2
            ;;
        -l|--log-dir)
            LOG_DIR="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            if [[ -z "$IMAGE_FILE" ]]; then
                IMAGE_FILE="$1"
            else
                error "Multiple image files specified"
                usage
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate arguments
if [[ -z "$IMAGE_FILE" ]]; then
    error "Image file is required"
    usage
    exit 1
fi

if [[ ! -f "$IMAGE_FILE" ]]; then
    error "Image file does not exist: $IMAGE_FILE"
    exit 1
fi

# Create log directory with error handling
if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    # If we can't create the specified log directory, fall back to a temp directory
    LOG_DIR="/tmp/udpcast-$$"
    warn "Could not create log directory, using temporary directory: $LOG_DIR"
    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        error "Could not create any log directory. Logging will be limited."
        LOG_DIR=""
    fi
fi

info "Starting UDP Cast reliable transfer"
info "Image file: $IMAGE_FILE"
info "Inventory: $INVENTORY_FILE"
info "Group: $GROUP_NAME"

# Function to parse Ansible inventory and get hosts
get_foundation_hosts() {
    local inventory_file="$1"
    local group_name="$2"
    local hosts=()
    
    if [[ ! -f "$inventory_file" ]]; then
        error "Inventory file not found: $inventory_file"
        return 1
    fi
    
    # Try using ansible-inventory first (most reliable)
    if command -v ansible-inventory >/dev/null 2>&1; then
        echo "Using ansible-inventory to parse hosts" >&2  # Send to stderr
        local json_output
        if json_output=$(ansible-inventory -i "$inventory_file" --list 2>/dev/null); then
            # Extract hosts from JSON output
            hosts=($(echo "$json_output" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if '$group_name' in data and 'hosts' in data['$group_name']:
        for host in data['$group_name']['hosts']:
            print(host)
    elif '_meta' in data and 'hostvars' in data['_meta']:
        # Alternative parsing for different inventory structures
        for host, vars in data['_meta']['hostvars'].items():
            groups = vars.get('group_names', [])
            if '$group_name' in groups or '$group_name'.lower() in groups:
                print(host)
except Exception as e:
    print(f'Error parsing JSON: {e}', file=sys.stderr)
" 2>/dev/null))
        fi
    fi
    
    # Fallback: manual parsing of INI-style inventory
    if [[ ${#hosts[@]} -eq 0 ]]; then
        echo "Falling back to manual inventory parsing" >&2  # Send to stderr
        local in_group=false
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')  # trim whitespace
            
            # Skip empty lines and comments
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            
            # Check for group headers
            if [[ "$line" =~ ^\[(.+)\]$ ]]; then
                local current_group="${BASH_REMATCH[1]}"
                if [[ "$current_group" == "$group_name" ]]; then
                    in_group=true
                else
                    in_group=false
                fi
                continue
            fi
            
            # If we're in the target group, add hosts
            if [[ "$in_group" == true ]]; then
                # Extract hostname (before any ansible_host= or other variables)
                local hostname=$(echo "$line" | awk '{print $1}')
                [[ -n "$hostname" ]] && hosts+=("$hostname")
            fi
        done < "$inventory_file"
    fi
    
    if [[ ${#hosts[@]} -eq 0 ]]; then
        error "No hosts found in group '$group_name' in inventory '$inventory_file'"
        return 1
    fi
    
    if [[ ${#hosts[@]} -gt 0 ]]; then
        echo "Found ${#hosts[@]} hosts in group '$group_name':" >&2
        printf '%s\n' "${hosts[@]}" | sed 's/^/  - /' >&2  # Send to stderr to avoid mixing with return data
        
        # Return hosts via stdout (clean data only)
        printf '%s\n' "${hosts[@]}"
    fi
}

# Function to test SSH connectivity
test_ssh_connectivity() {
    local host="$1"
    info "Testing SSH connectivity to $host"
    
    if ssh -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes "$host" "echo 'SSH connection successful'" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function to start UDP receiver on remote host
start_remote_receiver() {
    local host="$1"
    local image_file="$2"
    local port_base="$3"
    
    info "Starting UDP receiver on $host"
    
    # First check if udp-receiver is available on the remote host
    if ! ssh -o ConnectTimeout="$SSH_TIMEOUT" "$host" "which udp-receiver" >/dev/null 2>&1; then
        error "udp-receiver not found on $host. Please install udpcast package."
        return 1
    fi
    
    # Build receiver command with high reliability settings
    local receiver_cmd="udp-receiver"
    receiver_cmd+=" --portbase $port_base"
    receiver_cmd+=" --interface br0"
    receiver_cmd+=" --file '$image_file'"
    receiver_cmd+=" --stat-period 5000"
    receiver_cmd+=" --start-timeout $TRANSFER_TIMEOUT"
    receiver_cmd+=" --receive-timeout $TRANSFER_TIMEOUT"
    receiver_cmd+=" --sync"
    
    # Add compression if enabled
    if [[ "$USE_COMPRESSION" == true ]]; then
        receiver_cmd+=" --pipe 'gzip -dc'"
    fi
    
    # Add logging
    receiver_cmd+=" --log '/tmp/udp-receiver-$host.log'"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "DRY RUN: Would execute on $host: $receiver_cmd"
        return 0
    fi
    
    # Execute receiver in background on remote host
    if [[ "$VERBOSE" == true ]]; then
        info "Executing on $host: $receiver_cmd"
    fi
    
    ssh -o ConnectTimeout="$SSH_TIMEOUT" "$host" "nohup $receiver_cmd > /tmp/udp-receiver-$host.out 2>&1 &" || {
        error "Failed to start receiver on $host"
        return 1
    }
    
    # Give receiver time to start
    sleep 3
    
    # Verify receiver is running
    if ssh -o ConnectTimeout="$SSH_TIMEOUT" "$host" "pgrep -f udp-receiver" >/dev/null 2>&1; then
        success "UDP receiver started successfully on $host"
        return 0
    else
        error "Failed to verify UDP receiver on $host"
        
        # Debug information
        info "Checking for error messages on $host..."
        if ssh -o ConnectTimeout="$SSH_TIMEOUT" "$host" "test -f /tmp/udp-receiver-$host.out"; then
            error "Remote receiver output:"
            ssh -o ConnectTimeout="$SSH_TIMEOUT" "$host" "cat /tmp/udp-receiver-$host.out" || true
        fi
        
        if ssh -o ConnectTimeout="$SSH_TIMEOUT" "$host" "test -f /tmp/udp-receiver-$host.log"; then
            error "Remote receiver log:"
            ssh -o ConnectTimeout="$SSH_TIMEOUT" "$host" "cat /tmp/udp-receiver-$host.log" || true
        fi
        
        return 1
    fi
}

# Function to stop UDP receivers on remote hosts
stop_remote_receivers() {
    local hosts=("$@")
    
    info "Stopping UDP receivers on all hosts"
    for host in "${hosts[@]}"; do
        ssh -o ConnectTimeout="$SSH_TIMEOUT" "$host" "pkill -f udp-receiver" 2>/dev/null || true
        info "Stopped receivers on $host"
    done
}

# Function to start UDP sender
start_sender() {
    local image_file="$1"
    local num_receivers="$2"
    local port_base="$3"
    
    info "Starting UDP sender for $num_receivers receivers"
    
    # Build sender command with high reliability settings
    local sender_cmd="udp-sender"
    sender_cmd+=" --file '$image_file'"
    sender_cmd+=" --portbase $port_base"
    sender_cmd+=" --interface br0"
    sender_cmd+=" --full-duplex"
    sender_cmd+=" --max-bitrate $BANDWIDTH"
    sender_cmd+=" --min-receivers $num_receivers"
    sender_cmd+=" --min-wait 10"
    sender_cmd+=" --max-wait 60"
    sender_cmd+=" --retries-until-drop 10"
    sender_cmd+=" --slice-size 256"  # Optimized for gigabit
    sender_cmd+=" --nokbd"
    
    # Add compression if enabled
    if [[ "$USE_COMPRESSION" == true ]]; then
        sender_cmd+=" --pipe 'gzip -1 -c'"
    fi
    
    # Add logging if log directory is available
    if [[ -n "$LOG_DIR" && -w "$LOG_DIR" ]]; then
        sender_cmd+=" --log '$LOG_DIR/udp-sender.log'"
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        info "DRY RUN: Would execute: $sender_cmd"
        return 0
    fi
    
    info "Executing: $sender_cmd"
    
    # Execute sender
    if eval "$sender_cmd"; then
        success "Transfer completed successfully"
        return 0
    else
        error "Transfer failed"
        return 1
    fi
}

# Function to create example inventory file
create_example_inventory() {
    local example_file="$1"
    
    cat > "$example_file" << 'EOF'
# Example Ansible Inventory File
# Save this to /etc/ansible/inventory/foundation

[Foundation]
server01.example.com
server02.example.com ansible_host=192.168.1.101
server03.example.com ansible_host=192.168.1.102
server04.example.com ansible_host=192.168.1.103

[Foundation:vars]
ansible_user=root
ansible_ssh_private_key_file=/root/.ssh/id_rsa
EOF
    
    info "Created example inventory file: $example_file"
}

# Main execution
main() {
    # Check if inventory file exists, create example if not
    if [[ ! -f "$INVENTORY_FILE" ]]; then
        warn "Inventory file not found: $INVENTORY_FILE"
        local example_file="./foundation_inventory.example"
        # Try to create the example in the working directory instead
        if [[ -f "foundation_inventory.example" ]]; then
            example_file="foundation_inventory.example"
        fi
        error "Please create the inventory file at $INVENTORY_FILE"
        info "See example inventory format in: $example_file"
        return 1
    fi
    
    # Get list of hosts
    local hosts
    if ! hosts=($(get_foundation_hosts "$INVENTORY_FILE" "$GROUP_NAME")); then
        error "Failed to get hosts from inventory"
        return 1
    fi
    
    local num_hosts=${#hosts[@]}
    if [[ $num_hosts -eq 0 ]]; then
        error "No hosts found in group $GROUP_NAME"
        return 1
    fi
    
    info "Planning transfer to $num_hosts hosts"
    
    # Test SSH connectivity to all hosts
    local reachable_hosts=()
    for host in "${hosts[@]}"; do
        if test_ssh_connectivity "$host"; then
            reachable_hosts+=("$host")
            success "SSH connectivity OK: $host"
        else
            error "SSH connectivity failed: $host"
        fi
    done
    
    if [[ ${#reachable_hosts[@]} -eq 0 ]]; then
        error "No hosts are reachable via SSH"
        return 1
    fi
    
    if [[ ${#reachable_hosts[@]} -ne $num_hosts ]]; then
        warn "Only ${#reachable_hosts[@]} of $num_hosts hosts are reachable"
        local proceed
        read -p "Continue with reachable hosts only? (y/N): " proceed
        if [[ "$proceed" != "y" && "$proceed" != "Y" ]]; then
            info "Transfer cancelled by user"
            return 1
        fi
    fi
    
    # Start receivers on all reachable hosts
    local successful_receivers=()
    for host in "${reachable_hosts[@]}"; do
        if start_remote_receiver "$host" "$IMAGE_FILE" "$UDP_PORT_BASE"; then
            successful_receivers+=("$host")
        else
            error "Failed to start receiver on $host"
        fi
    done
    
    if [[ ${#successful_receivers[@]} -eq 0 ]]; then
        error "No receivers could be started"
        return 1
    fi
    
    info "Successfully started ${#successful_receivers[@]} receivers"
    
    # Set up cleanup trap
    trap 'stop_remote_receivers "${successful_receivers[@]}"' EXIT INT TERM
    
    # Wait a bit for all receivers to be ready
    info "Waiting for receivers to be ready..."
    sleep 5
    
    # Start sender
    if start_sender "$IMAGE_FILE" "${#successful_receivers[@]}" "$UDP_PORT_BASE"; then
        success "Transfer completed successfully to ${#successful_receivers[@]} hosts"
        
        # Show transfer statistics
        if [[ -n "$LOG_DIR" && -f "$LOG_DIR/udp-sender.log" ]]; then
            info "Transfer statistics:"
            tail -n 10 "$LOG_DIR/udp-sender.log" | grep -E "(bytes|bitrate|packets)" || true
        fi
        
        return 0
    else
        error "Transfer failed"
        return 1
    fi
}

# Execute main function
if ! main "$@"; then
    error "Script execution failed"
    exit 1
fi

info "Script completed successfully"
