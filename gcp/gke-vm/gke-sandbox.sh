#!/bin/bash
# CLI utility to manage GKE sandbox instances
# Version: 1.2.0
# Author: Sean-Michael Riesterer
#
# Usage:
#   ./gke-sandbox.sh list [PROJECT] [USER]
#   ./gke-sandbox.sh delete <vm-name> [PROJECT] [ZONE]
#
# Prerequisites: Gcloud CLI Login

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CREATE_SCRIPT="${SCRIPT_DIR}/create-gcp-vm.sh"
readonly CONFIG_FILE="${SCRIPT_DIR}/env/create-gcp-vm.cfg"

# Load configuration
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=env/create-gcp-vm.cfg disable=SC1091
    source "$CONFIG_FILE"
else
    echo "WARNING: Configuration file not found: $CONFIG_FILE" >&2
    exit 1
fi

# Color definitions
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

###########################################################################
# Functions

function Print_Header {
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
}

function Print_Status { echo -e "${GREEN}[INFO]${NC} $1" ; }

function Print_Error { echo -e "${RED}[ERROR]${NC} $1" >&2 ; }

function Print_Warning { echo -e "${YELLOW}[WARNING]${NC} $1" ; }

function Show_Usage {
    cat << EOF
Usage: $0 <command> [options]

Commands:
    create --cluster <name> [OPTIONS]
                                    Create a new GKE sandbox instance
                                    Run '$0 create --help' for all available options

    list [PROJECT] [USER]           List GKE sandbox instances
                                    PROJECT defaults to '$DEFAULT_PROJECT'
                                    USER defaults to current user

    show [vm-name] [PROJECT] [ZONE]
                                    Display the IAP connection command for a VM
                                    If vm-name is omitted, interactive selection is shown
                                    PROJECT defaults to '$DEFAULT_PROJECT'
                                    ZONE defaults to '$DEFAULT_ZONE'

    connect [vm-name] [PROJECT] [ZONE]
                                    Connect to a VM via IAP SSH
                                    If vm-name is omitted, interactive selection is shown
                                    PROJECT defaults to '$DEFAULT_PROJECT'
                                    ZONE defaults to '$DEFAULT_ZONE'

    delete [vm-name] [PROJECT] [ZONE]
                                    Delete a GKE sandbox instance
                                    If vm-name is omitted, interactive selection is shown
                                    PROJECT defaults to '$DEFAULT_PROJECT'
                                    ZONE defaults to '$DEFAULT_ZONE'

Examples:
    # Create a new sandbox (run with --help to see all options)
    $0 create --cluster <CLUSTER-NAME>
    $0 create --help

    # List sandboxes
    $0 list
    $0 list <PROJECT-ID> <USERNAME>

    # Interactive selection (no VM name needed)
    $0 show
    $0 connect
    $0 delete

    # Direct VM operations
    $0 show <VM-NAME>
    $0 connect <VM-NAME>
    $0 delete <VM-NAME>

Configuration:
    Defaults are loaded from: $CONFIG_FILE

For detailed help on create options: $0 create --help

EOF
    exit 1
}

function List_Sandboxes {
    local project="${1:-$DEFAULT_PROJECT}"
    local user="${2:-$USER}"

    Print_Header "Listing Sandboxes for user: $user (project: $project)"

    if ! gcloud compute instances list \
        --project="$project" \
        --filter="labels.owner=$user AND labels.type=sandbox" \
        --format="table(
            name,
            zone.basename(),
            labels.cluster,
            machineType.machine_type().basename(),
            networkInterfaces[0].networkIP:label=INTERNAL_IP,
            creationTimestamp.date('%Y-%m-%d %H:%M')
        )"; then
        Print_Error "Listing instances failed"
        return 1
    fi
}

function Select_VM_Interactive {
    local project="${1:-$DEFAULT_PROJECT}"
    local user="${2:-$USER}"

    # Get list of VMs with cluster info: name,zone,cluster
    local vms
    vms=$(gcloud compute instances list \
        --project="$project" \
        --filter="labels.owner=$user AND labels.type=sandbox" \
        --format="csv[no-heading](name,zone.basename(),labels.cluster)" 2>/dev/null)

    if [[ -z "$vms" ]]; then
        Print_Error "No sandbox VMs found for user '$user' in project '$project'"
        return 1
    fi

    # Convert to array
    local vm_array=()
    while IFS= read -r line; do
        vm_array+=("$line")
    done <<< "$vms"

    # Check if only one VM exists
    if [[ ${#vm_array[@]} -eq 1 ]]; then
        IFS=',' read -r vm_name vm_zone vm_cluster <<< "${vm_array[0]}"
        Print_Status "Only one VM found: $vm_name (cluster: $vm_cluster)" >&2
        echo "$vm_name,$vm_zone"
        return 0
    fi

    # Display menu - all output to stderr except the final result
    Print_Header "Select a VM" >&2
    echo "" >&2
    local index=1
    for vm in "${vm_array[@]}"; do
        IFS=',' read -r vm_name vm_zone vm_cluster <<< "$vm"
        if [[ -n "$vm_cluster" ]]; then
            echo -e "  ${BOLD}$index)${NC} ${GREEN}$vm_cluster${NC} → $vm_name ${BLUE}(zone: $vm_zone)${NC}" >&2
        else
            echo -e "  ${BOLD}$index)${NC} $vm_name ${BLUE}(zone: $vm_zone)${NC}" >&2
        fi
        ((index++))
    done
    echo "" >&2
    echo -e "  ${BOLD}0)${NC} Cancel" >&2
    echo "" >&2

    # Get user selection
    local selection
    while true; do
        echo -e "${BOLD}Select a VM [0-$((${#vm_array[@]}))]:${NC} \c" >&2
        read -r selection

        # Validate input
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 0 ]] && [[ "$selection" -le ${#vm_array[@]} ]]; then
            if [[ "$selection" -eq 0 ]]; then
                Print_Status "Operation cancelled." >&2
                return 1
            fi
            break
        else
            Print_Error "Invalid selection. Please enter a number between 0 and ${#vm_array[@]}"
        fi
    done

    # Return selected VM (name,zone)
    IFS=',' read -r vm_name vm_zone vm_cluster <<< "${vm_array[$((selection-1))]}"
    echo "$vm_name,$vm_zone"
    return 0
}

function Show_Connection {
    local vm_name="${1:-}"
    local project="${2:-$DEFAULT_PROJECT}"
    local zone="${3:-$DEFAULT_ZONE}"

    # If no VM name provided, show interactive selection
    if [[ -z "$vm_name" ]]; then
        local selection
        if ! selection=$(Select_VM_Interactive "$project"); then
            return 1
        fi
        IFS=',' read -r vm_name zone <<< "$selection"
    fi

    # Verify the VM exists first
    Print_Status "Checking if VM '$vm_name' exists..."
    if ! gcloud compute instances describe "$vm_name" \
        --zone="$zone" \
        --project="$project" \
        --format="value(name)" &>/dev/null; then
        Print_Error "VM '$vm_name' not found in zone '$zone' of project '$project'"
        return 1
    fi

    Print_Header "IAP Connection Command"
    echo ""
    echo -e "${GREEN}gcloud compute ssh \"$vm_name\" --zone=\"$zone\" --project=\"$project\" --tunnel-through-iap${NC}"
    echo ""
}

function Connect_To_VM {
    local vm_name="${1:-}"
    local project="${2:-$DEFAULT_PROJECT}"
    local zone="${3:-$DEFAULT_ZONE}"

    # If no VM name provided, show interactive selection
    if [[ -z "$vm_name" ]]; then
        local selection
        if ! selection=$(Select_VM_Interactive "$project"); then
            return 1
        fi
        IFS=',' read -r vm_name zone <<< "$selection"
    fi

    # Verify the VM exists first
    Print_Status "Checking if VM '$vm_name' exists..."
    if ! gcloud compute instances describe "$vm_name" \
        --zone="$zone" \
        --project="$project" \
        --format="value(name)" &>/dev/null; then
        Print_Error "VM '$vm_name' not found in zone '$zone' of project '$project'"
        return 1
    fi

    Print_Status "Connecting to VM '$vm_name' via IAP..."
    echo ""

    gcloud compute ssh "$vm_name" \
        --zone="$zone" \
        --project="$project" \
        --tunnel-through-iap
}

function Delete_Sandbox {
    local vm_name="${1:-}"
    local project="${2:-$DEFAULT_PROJECT}"
    local zone="${3:-$DEFAULT_ZONE}"

    # If no VM name provided, show interactive selection
    if [[ -z "$vm_name" ]]; then
        local selection
        if ! selection=$(Select_VM_Interactive "$project"); then
            return 1
        fi
        IFS=',' read -r vm_name zone <<< "$selection"
    fi

    # Verify the VM exists first
    Print_Status "Checking if VM '$vm_name' exists..."
    if ! gcloud compute instances describe "$vm_name" \
        --zone="$zone" \
        --project="$project" \
        --format="value(name)" &>/dev/null; then
        Print_Error "VM '$vm_name' not found in zone '$zone' of project '$project'"
        return 1
    fi

    # Get VM network information for potential IAP rule cleanup
    local network
    network=$(gcloud compute instances describe "$vm_name" \
        --zone="$zone" \
        --project="$project" \
        --format="value(networkInterfaces[0].network.basename())" 2>/dev/null)

    # Show VM details
    Print_Header "VM Details"
    gcloud compute instances describe "$vm_name" \
        --zone="$zone" \
        --project="$project" \
        --format="table(
            name,
            zone.basename(),
            machineType.machine_type().basename(),
            networkInterfaces[0].networkIP:label=INTERNAL_IP,
            creationTimestamp.date('%Y-%m-%d %H:%M'),
            labels.list():label=LABELS
        )"

    # Confirmation prompt
    echo ""
    Print_Warning "You are about to delete VM: $vm_name"
    Print_Warning "Project: $project"
    Print_Warning "Zone: $zone"
    echo ""
    echo -e "${BOLD}Are you sure you want to delete this VM? (${GREEN}yes${NC}${BOLD}/${RED}no${NC}${BOLD}):${NC} \c"
    read -r confirmation

    # Case-insensitive pattern matching
    if [[ ! "$confirmation" =~ ^[Yy][Ee][Ss]$ ]]; then
        Print_Status "Deletion cancelled by user."
        return 0
    fi

    Print_Status "Deleting sandbox VM: $vm_name (this takes ~90 seconds)..."

    if ! gcloud compute instances delete "$vm_name" \
        --zone="$zone" \
        --project="$project" \
        --quiet; then
        Print_Error "Failed to delete instance ${vm_name}"
        return 1
    fi

    Print_Status "VM deleted successfully!"

    # Check if IAP firewall rule exists and prompt for deletion
    if [[ -n "$network" ]]; then
        local iap_rule_name="allow-ssh-ingress-from-iap-${network}"

        if gcloud compute firewall-rules describe "$iap_rule_name" \
            --project="$project" &>/dev/null; then

            echo ""
            Print_Warning "Found IAP firewall rule: $iap_rule_name"
            Print_Warning "This rule allows SSH access via IAP for network: $network"
            echo ""
            echo -e "${BOLD}Do you want to delete this IAP firewall rule? (${GREEN}yes${NC}${BOLD}/${RED}no${NC}${BOLD}):${NC} \c"
            read -r iap_confirmation

            if [[ "$iap_confirmation" =~ ^[Yy][Ee][Ss]$ ]]; then
                Print_Status "Deleting IAP firewall rule: $iap_rule_name..."

                if gcloud compute firewall-rules delete "$iap_rule_name" \
                    --project="$project" \
                    --quiet; then
                    Print_Status "IAP firewall rule deleted successfully!"
                else
                    Print_Error "Failed to delete IAP firewall rule: $iap_rule_name"
                    Print_Warning "You may need to delete it manually or check permissions"
                fi
            else
                Print_Status "IAP firewall rule kept. Other VMs in network '$network' can still use it."
            fi
        fi
    fi
}

function Create_Sandbox {
    # Check if create script exists
    if [[ ! -f "$CREATE_SCRIPT" ]]; then
        Print_Error "Create script not found: $CREATE_SCRIPT"
        return 1
    fi

    # If no arguments or help requested, show create script help
    if [[ $# -eq 0 ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]] || [[ "$1" == "help" ]]; then
        "$CREATE_SCRIPT" --help
        return $?
    fi

    # Pass all arguments to the create script
    Print_Status "Delegating to create-gcp-vm.sh..."
    echo ""

    # Run the create script and capture exit code
    "$CREATE_SCRIPT" "$@"
    local exit_code=$?

    # If create script failed, show help
    if [[ $exit_code -ne 0 ]]; then
        echo ""
        Print_Warning "Command failed. See usage above or run: $0 create --help"
    fi

    return $exit_code
}

###########################################################################
# Main

# Check if command is provided
if [[ $# -lt 1 ]]; then
    Print_Error "No command provided"
    Show_Usage
fi

COMMAND="$1"
shift

case "$COMMAND" in
    create)
        Create_Sandbox "$@"
        ;;
    list)
        List_Sandboxes "$@"
        ;;
    show)
        Show_Connection "$@"
        ;;
    connect)
        Connect_To_VM "$@"
        ;;
    delete)
        Delete_Sandbox "$@"
        ;;
    help|-h|--help)
        Show_Usage
        ;;
    *)
        Print_Error "Unknown command: $COMMAND"
        Show_Usage
        ;;
esac
