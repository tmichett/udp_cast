#!/bin/bash

# UDP Cast Reliable Transfer Script
# Provides highly reliable file transfer over gigabit connections
# Automatically manages remote receivers from Ansible inventory
# Requires root SSH access to target hosts for /var/lib/libvirt/images/ access

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
Usage: $SCRIPT_NAME [OPTIONS]

Highly reliable UDP Cast transfer over gigabit networks.
Automatically discovers ISO/QCOW2 files from RHT course manifest and transfers them.
Automatically manages remote receivers from Ansible inventory.

REQUIREMENTS:
- Root SSH access to all target hosts (uses root@hostname)
- UDP receiver processes run as root for proper /var/lib/libvirt/images/ access

Files are automatically discovered by:
1. Reading RHT_COURSE from /etc/rht
2. Finding manifest file in /content/manifests based on course SKU
3. Extracting ISO and QCOW2 files from foundation and classroom entries
4. Transferring each file with source path: /content/<final_name>
5. Files are saved to /var/lib/libvirt/images/<basename> on receivers (as root)

Options:
    -i, --inventory FILE    Ansible inventory file (default: $INVENTORY_FILE)
    -g, --group NAME        Ansible group name (default: $GROUP_NAME)
    -p, --port PORT         UDP port base (default: $UDP_PORT_BASE)
    -b, --bandwidth RATE    Max bandwidth (e.g., 800m for 800Mbps)
    -d, --dry-run          Show what would be done without executing
    -t, --timeout SECONDS  Transfer timeout (default: $TRANSFER_TIMEOUT)
    -l, --log-dir DIR      Log directory (default: $LOG_DIR)
    -v, --verbose          Verbose output
    -h, --help             Show this help

Examples:
    $SCRIPT_NAME
    $SCRIPT_NAME -b 800m -v
    $SCRIPT_NAME -i /custom/inventory -g servers

EOF
}

# Parse command line arguments
BANDWIDTH="900m"  # High-performance for gigabit networks
DRY_RUN=false
VERBOSE=false

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
            error "Unexpected argument: $1"
            error "This script automatically discovers files from RHT manifest."
            usage
            exit 1
            ;;
    esac
done

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
info "Inventory: $INVENTORY_FILE"
info "Group: $GROUP_NAME"

# Function to read RHT_COURSE from /etc/rht
get_rht_course() {
    local rht_file="/etc/rht"
    
    if [[ ! -f "$rht_file" ]]; then
        error "RHT configuration file not found: $rht_file"
        return 1
    fi
    
    local rht_course
    if rht_course=$(grep "^RHT_COURSE=" "$rht_file" | cut -d'=' -f2 | tr -d '"'"'"''); then
        if [[ -n "$rht_course" ]]; then
            echo "$rht_course"
            return 0
        fi
    fi
    
    error "RHT_COURSE not found or empty in $rht_file"
    return 1
}

# Function to find manifest file based on SKU
find_manifest_file() {
    local sku="$1"
    local manifest_dir="/content/manifests"
    
    if [[ ! -d "$manifest_dir" ]]; then
        error "Manifest directory not found: $manifest_dir"
        return 1
    fi
    
    # Convert SKU to uppercase for manifest filename matching
    local sku_upper=$(echo "$sku" | tr '[:lower:]' '[:upper:]')
    
    # Find manifest file that starts with the SKU
    local manifest_file
    manifest_file=$(find "$manifest_dir" -name "${sku_upper}*" -type f | head -n1)
    
    if [[ -z "$manifest_file" ]]; then
        error "No manifest file found starting with $sku_upper in $manifest_dir"
        return 1
    fi
    
    echo "$manifest_file"
    return 0
}

# Function to parse manifest file and extract ISO/QCOW2 files only
parse_manifest_files() {
    local manifest_file="$1"
    local files=()
    
    if [[ ! -f "$manifest_file" ]]; then
        error "Manifest file not found: $manifest_file"
        return 1
    fi
    
    info "Parsing manifest file: $manifest_file" >&2
    
    # Use the working awk command we tested earlier
    local temp_file="/tmp/manifest_parse_$$"
    
    # Extract all foundation AND classroom entries using the working awk approach
    awk '/^[[:space:]]*artifacts:[[:space:]]*$/{found=1; next} found && /^[[:space:]]*-[[:space:]]*filename:/{filename=$0} found && /^[[:space:]]*final[[:space:]]*name:/{final=$0} found && /^[[:space:]]*usage:[[:space:]]*\[(.*foundation.*|.*classroom.*)\]/{gsub(/^[[:space:]]*final[[:space:]]*name:[[:space:]]*/, "", final); print final}' "$manifest_file" | sort -u > "$temp_file"
    
    # Also get hardlinked files from foundation AND classroom entries  
    awk '/^[[:space:]]*artifacts:[[:space:]]*$/{found=1; next} found && /^[[:space:]]*usage:[[:space:]]*\[(.*foundation.*|.*classroom.*)\]/{target=1; next} found && target && /^[[:space:]]*hardlink[[:space:]]*names:/{hardlinks=1; next} found && target && hardlinks && /^[[:space:]]*-[[:space:]]*(.+)$/{gsub(/^[[:space:]]*-[[:space:]]*/, ""); print} found && /^[[:space:]]*-[[:space:]]*filename:/{target=0; hardlinks=0}' "$manifest_file" >> "$temp_file"
    
    # Read the results into the files array
    while IFS= read -r line; do
        if [[ -n "$line" && ! "$line" =~ ^[[:space:]]*final[[:space:]]*name: ]]; then
            files+=("$line")
        fi
    done < "$temp_file"
    
    # Clean up
    rm -f "$temp_file"
    
    if [[ ${#files[@]} -eq 0 ]]; then
        error "No files found for foundation usage in manifest: $manifest_file"
        return 1
    fi
    
    # Filter to only include ISO and QCOW2 files (no XML files)
    local valid_files=()
    for file in "${files[@]}"; do
        # Only include files with ISO/QCOW2 extensions and valid paths
        if [[ "$file" =~ \.(iso|qcow2)$ && "$file" =~ ^[a-zA-Z0-9/_.-]+$ ]]; then
            valid_files+=("$file")
        fi
    done
    
    if [[ ${#valid_files[@]} -eq 0 ]]; then
        error "No ISO/QCOW2 files found for transfer in manifest: $manifest_file"
        return 1
    fi
    
    # Send info message to stderr to avoid contaminating stdout
    info "Found ${#valid_files[@]} ISO/QCOW2 files to transfer:" >&2
    printf '%s\n' "${valid_files[@]}" | sed 's/^/  - /' >&2
    
    # Return valid files via stdout (clean data only)
    printf '%s\n' "${valid_files[@]}"
    return 0
}

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
    info "Testing SSH connectivity to root@$host"
    
    if ssh -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes root@"$host" "echo 'SSH connection successful'" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function to start UDP receiver on remote host
start_remote_receiver() {
    local host="$1"
    local filename="$2"
    local port_base="$3"
    
    info "Starting UDP receiver on root@$host for $filename"
    
    # First check if udp-receiver is available on the remote host
    if ! ssh -o ConnectTimeout="$SSH_TIMEOUT" root@"$host" "which udp-receiver" >/dev/null 2>&1; then
        error "udp-receiver not found on $host. Please install udpcast package."
        return 1
    fi
    
    # Ensure destination directory exists
    local dest_dir="/var/lib/libvirt/images"
    ssh -o ConnectTimeout="$SSH_TIMEOUT" root@"$host" "mkdir -p '$dest_dir'" || {
        error "Failed to create destination directory $dest_dir on $host"
        return 1
    }
    
    # Build receiver command with destination path
    # The filename parameter now contains the final name path, so use its basename
    local dest_filename="$(basename "$filename")"
    local dest_file="$dest_dir/$dest_filename"
    local receiver_cmd="udp-receiver"
    receiver_cmd+=" --file '$dest_file'"
    receiver_cmd+=" --portbase $port_base"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "DRY RUN: Would execute on root@$host: $receiver_cmd"
        return 0
    fi
    
    # Execute receiver in background on remote host as root
    if [[ "$VERBOSE" == true ]]; then
        info "Executing on root@$host: $receiver_cmd"
    fi
    
    ssh -o ConnectTimeout="$SSH_TIMEOUT" root@"$host" "nohup $receiver_cmd > /tmp/udp-receiver-$host-$dest_filename.out 2>&1 &" || {
        error "Failed to start receiver on $host"
        return 1
    }
    
    # Give receiver time to start
    sleep 3
    
    # Verify receiver is running
    if ssh -o ConnectTimeout="$SSH_TIMEOUT" root@"$host" "pgrep -f udp-receiver" >/dev/null 2>&1; then
        success "UDP receiver started successfully on root@$host for $dest_file"
        return 0
    else
        error "Failed to verify UDP receiver on $host"
        
        # Debug information
        info "Checking for error messages on $host..."
        local out_file="/tmp/udp-receiver-$host-$dest_filename.out"
        if ssh -o ConnectTimeout="$SSH_TIMEOUT" root@"$host" "test -f '$out_file'"; then
            error "Remote receiver output:"
            ssh -o ConnectTimeout="$SSH_TIMEOUT" root@"$host" "cat '$out_file'" || true
        fi
        
        local log_file="/tmp/udp-receiver-$host-$dest_filename.log"
        if ssh -o ConnectTimeout="$SSH_TIMEOUT" root@"$host" "test -f '$log_file'"; then
            error "Remote receiver log:"
            ssh -o ConnectTimeout="$SSH_TIMEOUT" root@"$host" "cat '$log_file'" || true
        fi
        
        return 1
    fi
}

# Function to stop UDP receivers on remote hosts
stop_remote_receivers() {
    local hosts=("$@")
    
    info "Stopping UDP receivers on all hosts"
    for host in "${hosts[@]}"; do
        ssh -o ConnectTimeout="$SSH_TIMEOUT" root@"$host" "pkill -f udp-receiver" 2>/dev/null || true
        info "Stopped receivers on root@$host"
    done
}

# Function to start UDP sender
start_sender() {
    local source_file="$1"
    local num_receivers="$2"
    local port_base="$3"
    local filename="$4"
    
    info "Starting UDP sender for $num_receivers receivers: $(basename "$source_file")"
    
    # Verify source file exists
    if [[ ! -f "$source_file" ]]; then
        error "Source file does not exist: $source_file"
        return 1
    fi
    
    # Build sender command - keep it simple like the working manual test
    local sender_cmd="udp-sender"
    sender_cmd+=" '$source_file'"
    sender_cmd+=" --interface br0" 
    sender_cmd+=" --min-receivers $num_receivers"
    sender_cmd+=" --portbase $port_base"
    sender_cmd+=" --nokbd"
    
    # Add logging if log directory is available
    if [[ -n "$LOG_DIR" && -w "$LOG_DIR" ]]; then
        # The filename parameter now contains the final name path, so use its basename
        local dest_filename="$(basename "$filename")"
        local log_file="$LOG_DIR/udp-sender-$dest_filename.log"
        sender_cmd+=" --log '$log_file'"
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        info "DRY RUN: Would execute: $sender_cmd"
        return 0
    fi
    
    info "Executing: $sender_cmd"
    
    # Execute sender
    if eval "$sender_cmd"; then
        success "Transfer completed successfully for $(basename "$source_file")"
        return 0
    else
        error "Transfer failed for $(basename "$source_file")"
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

# Function to transfer a single file
transfer_single_file() {
    local filename="$1"
    local transfer_number="$2"
    local hosts=("${@:3}")
    
    local source_file="/content/$filename"
    # Use dynamic port allocation to avoid conflicts
    local dynamic_port=$((UDP_PORT_BASE + transfer_number - 1))
    
    # The filename parameter now contains the final name path, so use its basename as destination
    local dest_filename="$(basename "$filename")"
    
    info "=== Transferring: $dest_filename ==="
    info "Source: $source_file"
    info "Destination on receivers: /var/lib/libvirt/images/$dest_filename"
    info "Using UDP port: $dynamic_port"
    
    # Verify source file exists
    if [[ ! -f "$source_file" ]]; then
        error "Source file does not exist: $source_file"
        return 1
    fi
    
    # Start receivers on all hosts for this specific file
    local successful_receivers=()
    for host in "${hosts[@]}"; do
        if start_remote_receiver "$host" "$filename" "$dynamic_port"; then
            successful_receivers+=("$host")
        else
            error "Failed to start receiver on $host for $filename"
        fi
    done
    
    if [[ ${#successful_receivers[@]} -eq 0 ]]; then
        error "No receivers could be started for $filename"
        return 1
    fi
    
    info "Successfully started ${#successful_receivers[@]} receivers for $filename"
    
    # Set up cleanup trap for this file
    trap 'stop_remote_receivers "${successful_receivers[@]}"' EXIT INT TERM
    
    # Wait a bit for all receivers to be ready
    info "Waiting for receivers to be ready..."
    sleep 5
    
    # Start sender for this file
    if start_sender "$source_file" "${#successful_receivers[@]}" "$dynamic_port" "$filename"; then
        success "Transfer completed successfully for $filename to ${#successful_receivers[@]} hosts"
        
        # Skip verification in dry-run mode
        if [[ "$DRY_RUN" == true ]]; then
            info "DRY RUN: Skipping file verification"
        else
            # Verify transfer integrity by comparing file sizes
            info "Verifying transfer integrity for $dest_filename..."
            local source_size
            source_size=$(stat -f%z "$source_file" 2>/dev/null || stat -c%s "$source_file" 2>/dev/null)
            
            local all_verified=true
            for host in "${successful_receivers[@]}"; do
                local dest_file="/var/lib/libvirt/images/$dest_filename"
                local remote_size
                if remote_size=$(ssh -o ConnectTimeout="$SSH_TIMEOUT" root@"$host" "stat -f%z '$dest_file' 2>/dev/null || stat -c%s '$dest_file' 2>/dev/null" 2>/dev/null); then
                    if [[ "$source_size" == "$remote_size" ]]; then
                        success "File size verification passed for root@$host: $remote_size bytes"
                    else
                        error "File size mismatch on $host! Source: $source_size bytes, Remote: $remote_size bytes"
                        all_verified=false
                    fi
                else
                    error "Could not verify file size for $dest_filename on root@$host"
                    all_verified=false
                fi
            done
            
            if [[ "$all_verified" == false ]]; then
                error "Transfer verification failed for $dest_filename! File may be corrupted."
                return 1
            fi
        fi
        
        # Show transfer statistics
        if [[ -n "$LOG_DIR" && -f "$LOG_DIR/udp-sender-$dest_filename.log" ]]; then
            info "Transfer statistics for $dest_filename:"
            tail -n 10 "$LOG_DIR/udp-sender-$dest_filename.log" | grep -E "(bytes|bitrate|packets)" || true
        fi
        
        # Clean up receivers for this file
        stop_remote_receivers "${successful_receivers[@]}"
        trap - EXIT INT TERM  # Remove trap since we cleaned up manually
        
        return 0
    else
        error "Transfer failed for $filename"
        stop_remote_receivers "${successful_receivers[@]}"
        trap - EXIT INT TERM  # Remove trap since we cleaned up manually
        return 1
    fi
}

# Main execution
main() {
    # Step 1: Discover files from manifest
    info "Discovering ISO/QCOW2 files from RHT course manifest..."
    
    local rht_course manifest_file
    rht_course=$(get_rht_course) || {
        error "Failed to read RHT_COURSE configuration"
        exit 1
    }
    
    info "RHT Course: $rht_course"
    
    manifest_file=$(find_manifest_file "$rht_course") || {
        error "Failed to find manifest file for course: $rht_course"
        exit 1
    }
    
    info "Manifest file: $manifest_file"
    
    local files_to_transfer
    mapfile -t files_to_transfer < <(parse_manifest_files "$manifest_file") || {
        error "Failed to parse manifest files"
        exit 1
    }
    
    if [[ ${#files_to_transfer[@]} -eq 0 ]]; then
        error "No ISO/QCOW2 files found to transfer from manifest"
        exit 1
    fi
    
    info "Found ${#files_to_transfer[@]} ISO/QCOW2 files to transfer"
    
    # Step 2: Check if inventory file exists, create example if not
    if [[ ! -f "$INVENTORY_FILE" ]]; then
        warn "Inventory file not found: $INVENTORY_FILE"
        local example_file="./foundation_inventory.example"
        create_example_inventory "$example_file"
        error "Please create and configure your Ansible inventory file at: $INVENTORY_FILE"
        error "Use the example file as a reference: $example_file"
        exit 1
    fi
    
    # Step 3: Get hosts from inventory
    mapfile -t hosts < <(get_foundation_hosts "$INVENTORY_FILE" "$GROUP_NAME")
    if [[ ${#hosts[@]} -eq 0 ]]; then
        error "No hosts found for group '$GROUP_NAME' in inventory: $INVENTORY_FILE"
        error "Please check your inventory file and group name"
        exit 1
    fi
    
    info "Found ${#hosts[@]} hosts in group '$GROUP_NAME': ${hosts[*]}"
    
    # Step 4: Validate SSH connectivity to all hosts
    local reachable_hosts=()
    for host in "${hosts[@]}"; do
        if test_ssh_connectivity "$host"; then
            reachable_hosts+=("$host")
            success "SSH connection successful to root@$host"
        else
            warn "Cannot connect to root@$host via SSH"
        fi
    done
    
    if [[ ${#reachable_hosts[@]} -eq 0 ]]; then
        error "No hosts are reachable via SSH"
        exit 1
    fi
    
    if [[ ${#reachable_hosts[@]} -ne ${#hosts[@]} ]]; then
        warn "Some hosts are unreachable. Transfer will proceed with ${#reachable_hosts[@]} hosts"
    fi
    
    info "Transfer will proceed to ${#reachable_hosts[@]} hosts: ${reachable_hosts[*]}"
    
    # Step 5: Transfer each file sequentially
    local successful_transfers=0
    local failed_transfers=0
    local total_files=${#files_to_transfer[@]}
    
    for i in "${!files_to_transfer[@]}"; do
        local transfer_number=$((i + 1))
        local filename="${files_to_transfer[i]}"
        
        info ""
        info "Starting transfer $transfer_number of $total_files"
        
        if transfer_single_file "$filename" "$transfer_number" "${reachable_hosts[@]}"; then
            success "Successfully transferred $(basename "$filename")"
            ((successful_transfers++))
        else
            error "Failed to transfer $(basename "$filename")"
            ((failed_transfers++))
        fi
        
        # Small delay between transfers to prevent port conflicts
        if [[ $transfer_number -lt $total_files ]]; then
            sleep 2
        fi
    done
    
    # Step 6: Summary
    info ""
    info "=== Transfer Summary ==="
    info "Total files: $total_files"
    info "Successful transfers: $successful_transfers"
    info "Failed transfers: $failed_transfers"
    info "Target hosts: ${#reachable_hosts[@]}"
    
    if [[ $failed_transfers -gt 0 ]]; then
        error "Some transfers failed. Check logs for details."
        return 1
    else
        success "All transfers completed successfully!"
        return 0
    fi
}

# Execute main function
if ! main "$@"; then
    error "Script execution failed"
    exit 1
fi

info "Script completed successfully"
