#!/bin/bash
# GKE Sandbox VM Creation Script
# Version: 1.2.0
# Author: Sean-Michael Riesterer
#
# Resources Created:
# - VM in cluster subnet (private, no external IP)
# - IAP firewall rule for SSH access
# - Per-user service account with GKE permissions
# - Kubeconfig copied to VM
#
# Usage: ./create-gke-sandbox.sh --cluster <cluster-name> [OPTIONS]
#
# Prerequisites: gcloud CLI authenticated with 'gcloud auth login'

set -euo pipefail

readonly PROGRAM="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CONFIG_FILE="${SCRIPT_DIR}/env/create-gcp-vm.cfg"
readonly STARTUP_SCRIPT="${SCRIPT_DIR}/utils/vm-startup.sh"


# Load configuration
[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: Configuration file not found: $CONFIG_FILE" >&2 ; exit 1 ; }
# shellcheck source=create-gcp-vm.cfg disable=SC1091
source "$CONFIG_FILE"


# Validate startup script exists
[[ -f "$STARTUP_SCRIPT" ]] || { echo "ERROR: Startup script not found: $STARTUP_SCRIPT" >&2 ; exit 1; }


# Colors for output
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'


###########################################################################
# Functions

function Usage {
    cat << EOF
Usage: $PROGRAM --cluster <cluster-name> [OPTIONS]

Creates a sandbox VM with access to a private GKE cluster.

Required:
  --cluster <name>        Name of the GKE cluster

Optional:
  --project <id>          GCP project ID (default: $DEFAULT_PROJECT)
  --zone <zone>           Compute zone (default: $DEFAULT_ZONE)
  --vm-size <type>        VM machine type (default: $DEFAULT_VM_SIZE)
  --vm-name <name>        Custom VM name (default: auto-generated)
  --verbose               Enable verbose logging
  --help                  Show this help message

External VPC Options:
  --vpc <name>            VPC network name (external to cluster)
  --subnet <name>         Subnet name within the VPC

  When using --vpc and --subnet, the VM will be created on a separate VPC
  from the cluster. The script will automatically:
  - Create VPC peering between the external VPC and cluster VPC
  - Add the VM's IP to the cluster's master_authorized_networks
  - Configure IAP firewall rules for the external VPC

Examples:
  # Basic usage (VM on cluster subnet)
  $PROGRAM --cluster <CLUSTER-NAME>

  # VM on external VPC with peering
  $PROGRAM --cluster <CLUSTER-NAME> --vpc <VPC-NAME> --subnet <SUBNET-NAME>

  # Custom VM size and name
  $PROGRAM --cluster <CLUSTER-NAME> --vm-size e2-standard-4 --vm-name <CUSTOM-VM-NAME>

  # Different project and zone with external VPC
  $PROGRAM --cluster <CLUSTER-NAME> --project <PROJECT-ID> --zone <ZONE> --vpc <VPC-NAME> --subnet <SUBNET-NAME>

The VM will:
  - Have no external IP (private only)
  - Use IAP tunneling for SSH access
  - Have kubectl, helm, and gcloud tools pre-installed
  - Use a per-user service account with GKE permissions
  - Have kubeconfig pre-configured for the cluster

Connect to VM:
  gcloud compute ssh <VM-NAME> --zone <ZONE> --tunnel-through-iap --project <PROJECT-ID>

EOF
    exit 0
}


function Print_Status { echo -e "${GREEN}[INFO]${NC} $1" ; }


function Print_Warning { echo -e "${YELLOW}[WARNING]${NC} $1" ; }


function Print_Error { echo -e "${RED}[ERROR]${NC} $1" >&2 ; }


function Log { [[ "$verbose" == 'true' ]] && echo "[DEBUG] $*" ; return 0 ; }


function Print_Header {
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
}


function Setup_VPC_Peering {
    local cluster_vpc="$1"
    local external_vpc="$2"
    local project="$3"

    Print_Status "Checking VPC peering between '$external_vpc' and '$cluster_vpc'..."

    # Check external VPC -> cluster VPC: extract peerings array and check if any point to cluster VPC with ACTIVE state
    local external_to_cluster_exists
    external_to_cluster_exists=$(gcloud compute networks peerings list \
        --network="$external_vpc" \
        --project="$project" \
        --format="json" 2>/dev/null | \
        jq -r '.[0].peerings[]? | select(.state == "ACTIVE") | .network' 2>/dev/null | \
        grep -c "/${cluster_vpc}$" || echo 0)

    # Check cluster VPC -> external VPC: extract peerings array and check if any point to external VPC with ACTIVE state
    local cluster_to_external_exists
    cluster_to_external_exists=$(gcloud compute networks peerings list \
        --network="$cluster_vpc" \
        --project="$project" \
        --format="json" 2>/dev/null | \
        jq -r '.[0].peerings[]? | select(.state == "ACTIVE") | .network' 2>/dev/null | \
        grep -c "/${external_vpc}$" || echo 0)

    Log "Peering $external_vpc -> $cluster_vpc exists: $external_to_cluster_exists"
    Log "Peering $cluster_vpc -> $external_vpc exists: $cluster_to_external_exists"

    # Create peering names for new peerings
    local peering_name_external_to_cluster="peer-${external_vpc}-to-${cluster_vpc}"
    local peering_name_cluster_to_external="peer-${cluster_vpc}-to-${external_vpc}"

    # Create external VPC -> cluster VPC peering if it doesn't exist
    if [[ "$external_to_cluster_exists" -eq 0 ]]; then
        Print_Status "Creating VPC peering from '$external_vpc' to '$cluster_vpc'..."
        if ! gcloud compute networks peerings create "$peering_name_external_to_cluster" \
            --network="$external_vpc" \
            --peer-network="$cluster_vpc" \
            --project="$project" \
            --quiet 2>&1; then
            Print_Error "Failed to create VPC peering from '$external_vpc' to '$cluster_vpc'"
            return 1
        fi
        Print_Status "VPC peering from '$external_vpc' to '$cluster_vpc' created"
    else
        Print_Status "Peering $external_vpc -> $cluster_vpc already ACTIVE"
    fi

    # Create cluster VPC -> external VPC peering if it doesn't exist
    if [[ "$cluster_to_external_exists" -eq 0 ]]; then
        Print_Status "Creating VPC peering from '$cluster_vpc' to '$external_vpc'..."
        if ! gcloud compute networks peerings create "$peering_name_cluster_to_external" \
            --network="$cluster_vpc" \
            --peer-network="$external_vpc" \
            --project="$project" \
            --quiet 2>&1; then
            Print_Error "Failed to create VPC peering from '$cluster_vpc' to '$external_vpc'"
            return 1
        fi
        Print_Status "VPC peering from '$cluster_vpc' to '$external_vpc' created"
    else
        Print_Status "Peering $cluster_vpc -> $external_vpc already ACTIVE"
    fi

    Print_Status "VPC peering fully configured (bidirectional)"
    return 0
}


function Add_To_Master_Authorized_Networks {
    local cluster_name="$1"
    local region="$2"
    local project="$3"
    local vm_ip="$4"

    Print_Status "Adding VM IP to cluster's master_authorized_networks..."

    local vm_cidr="${vm_ip}/32"

    # Check if master authorized networks is enabled
    local is_enabled
    is_enabled=$(gcloud container clusters describe "$cluster_name" \
        --region="$region" \
        --project="$project" \
        --format="value(masterAuthorizedNetworksConfig.enabled)" 2>/dev/null || echo "")

    # Get existing CIDRs
    local existing_cidrs
    existing_cidrs=$(gcloud container clusters describe "$cluster_name" \
        --region="$region" \
        --project="$project" \
        --format="value(masterAuthorizedNetworksConfig.cidrBlocks[].cidrBlock)" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "")

    Log "Master authorized networks enabled: $is_enabled"
    Log "Existing CIDRs: $existing_cidrs"

    # Check if VM IP is already in the list
    if [[ -n "$existing_cidrs" ]] && echo "$existing_cidrs" | tr ',' '\n' | grep -q "^${vm_cidr}$"; then
        Log "VM IP ${vm_cidr} is already in master_authorized_networks"
        Print_Status "VM IP already authorized"
        return 0
    fi

    # Build new CIDR list
    local all_cidrs="${vm_cidr}"
    if [[ -n "$existing_cidrs" ]]; then
        all_cidrs="${existing_cidrs},${vm_cidr}"
    fi

    # Enable master authorized networks if not enabled, or update if it is
    if [[ "$is_enabled" != "True" ]]; then
        Print_Status "Enabling master_authorized_networks and adding ${vm_cidr}..."
        if ! gcloud container clusters update "$cluster_name" \
            --region="$region" \
            --project="$project" \
            --enable-master-authorized-networks \
            --master-authorized-networks="${vm_cidr}" \
            --quiet 2>&1; then
            Print_Error "Failed to enable master_authorized_networks"
            return 1
        fi
        Print_Status "Master authorized networks enabled and VM IP added"
    else
        Print_Status "Adding ${vm_cidr} to existing master_authorized_networks..."
        if ! gcloud container clusters update "$cluster_name" \
            --region="$region" \
            --project="$project" \
            --enable-master-authorized-networks \
            --master-authorized-networks="${all_cidrs}" \
            --quiet 2>&1; then
            Print_Error "Failed to add VM IP to master_authorized_networks"
            return 1
        fi
        Print_Status "VM IP added to master_authorized_networks"
    fi

    return 0
}


function Check_Prerequisites {
    if ! command -v gcloud &> /dev/null; then
        Print_Error "gcloud CLI is not installed"
        Print_Error "Install from: https://cloud.google.com/sdk/docs/install"
        exit 1
    fi

    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
        Print_Error "Not authenticated with gcloud"
        Print_Error "Run: gcloud auth login"
        exit 1
    fi

    if ! gcloud projects describe "$project" &>/dev/null; then
        Print_Error "Project '$project' not found or not accessible"
        Print_Error "Check your project ID or run: gcloud config set project <project-id>"
        exit 1
    fi

    Log "Prerequisites check passed"
}


###########################################################################
# Main

cluster_name=""
project="$DEFAULT_PROJECT"
zone="$DEFAULT_ZONE"
vm_size="$DEFAULT_VM_SIZE"
vm_name=""
verbose='false'
external_vpc=""
external_subnet=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster)
            cluster_name="$2"
            shift 2
            ;;
        --project)
            project="$2"
            shift 2
            ;;
        --zone)
            zone="$2"
            shift 2
            ;;
        --vm-size)
            vm_size="$2"
            shift 2
            ;;
        --vm-name)
            vm_name="$2"
            shift 2
            ;;
        --vpc)
            external_vpc="$2"
            shift 2
            ;;
        --subnet)
            external_subnet="$2"
            shift 2
            ;;
        --verbose)
            verbose='true'
            shift
            ;;
        --help)
            Usage
            ;;
        *)
            Print_Error "Unknown option: $1"
            Usage
            ;;
    esac
done

[[ -z "$cluster_name" ]] && { Print_Error "--cluster is required" ; Usage ; }

# Validate VPC/subnet options
if [[ -n "$external_vpc" ]] && [[ -z "$external_subnet" ]]; then
    Print_Error "--subnet is required when --vpc is specified"
    Usage
fi

if [[ -z "$external_vpc" ]] && [[ -n "$external_subnet" ]]; then
    Print_Error "--vpc is required when --subnet is specified"
    Usage
fi

# Extract region from zone (e.g., us-west1-c -> us-west1)
region="${zone%-*}"

[[ -z "$vm_name" ]] && vm_name="sbx-${USER}-${cluster_name}-$(date +%H%M)"

service_account_name="gke-sandbox-${USER}"
service_account_email="${service_account_name}@${project}.iam.gserviceaccount.com"

Print_Header "GKE Sandbox VM Setup"

Check_Prerequisites

Print_Status "Cluster: $cluster_name"
Print_Status "VM Name: $vm_name"
Print_Status "Project: $project"
Print_Status "Zone: $zone"
Print_Status "Service Account: $service_account_email"
echo ""

Print_Status "Verifying cluster exists..."
Log "Checking cluster '$cluster_name' in region '$region'"

read -r cluster_network cluster_subnet < <(gcloud container clusters describe "$cluster_name" \
    --region="$region" \
    --project="$project" \
    --format="csv[no-heading](network.basename(),subnetwork.basename())" | tr ',' ' ')

if [[ -z "$cluster_network" ]] || [[ -z "$cluster_subnet" ]]; then
    Print_Error "Cluster '$cluster_name' not found in region '$region' or failed to get network details"
    exit 1
fi

Log "Cluster Network: $cluster_network"
Log "Cluster Subnet: $cluster_subnet"
Print_Status "Cluster verified"

# Determine which network and subnet to use for VM
if [[ -n "$external_vpc" ]]; then
    Print_Status "External VPC mode enabled"
    Print_Status "VM will be created on VPC: $external_vpc, Subnet: $external_subnet"

    # Verify external VPC and subnet exist
    if ! gcloud compute networks describe "$external_vpc" \
        --project="$project" &>/dev/null; then
        Print_Error "External VPC '$external_vpc' not found"
        exit 1
    fi

    if ! gcloud compute networks subnets describe "$external_subnet" \
        --region="$region" \
        --project="$project" &>/dev/null; then
        Print_Error "External subnet '$external_subnet' not found in region '$region'"
        exit 1
    fi

    network="$external_vpc"
    subnet="$external_subnet"
    use_external_vpc='true'
else
    Print_Status "Using cluster's VPC for VM"
    network="$cluster_network"
    subnet="$cluster_subnet"
    use_external_vpc='false'
fi

Log "VM Network: $network"
Log "VM Subnet: $subnet"

Print_Status "Setting up service account..."
if ! gcloud iam service-accounts describe "$service_account_email" \
     --project="$project" &>/dev/null; then
    Print_Status "Creating service account: $service_account_email"

    if ! gcloud iam service-accounts create "$service_account_name" \
        --project="$project" \
        --display-name="GKE Sandbox SA for ${USER}" \
        --description="Service account for ${USER}'s sandbox VMs" \
        --quiet &>/dev/null; then
        Print_Error "Failed to create service account"
        exit 1
    fi

    Print_Status "Granting GKE permissions..."

    for role in "${REQUIRED_ROLES[@]}"; do
        Log "Granting $role..."
        if ! gcloud projects add-iam-policy-binding "$project" \
            --member="serviceAccount:$service_account_email" \
            --role="$role" \
            --condition=None \
            --quiet &>/dev/null; then
            Print_Warning "Failed to grant $role (may already exist or need higher permissions)"
        fi
    done

    Print_Status "Waiting 30s for IAM propagation..."
    sleep 30
else
    Log "Service account already exists"
fi

Print_Status "Configuring IAP firewall rule..."
readonly IAP_RULE_NAME="allow-ssh-ingress-from-iap-${network}"
if ! gcloud compute firewall-rules describe "$IAP_RULE_NAME" \
     --project="$project" &>/dev/null; then
    Print_Status "Creating IAP firewall rule for network '$network'..."
    if ! gcloud compute firewall-rules create "$IAP_RULE_NAME" \
        --project="$project" \
        --network="$network" \
        --allow=tcp:22 \
        --source-ranges=35.235.240.0/20 \
        --direction=INGRESS \
        --priority=1000 \
        --description="Allow SSH via IAP for sandbox VMs in $network" \
        --quiet &>/dev/null; then
        Print_Error "Failed to create IAP firewall rule"
        exit 1
    fi
else
    Log "IAP firewall rule '$IAP_RULE_NAME' already exists"
fi

Print_Status "Creating VM (this takes ~90 seconds)..."

vm_ready='false'
if gcloud compute instances describe "$vm_name" \
    --zone="$zone" \
    --project="$project" &>/dev/null; then
    Print_Warning "VM '$vm_name' already exists, skipping creation"
    vm_ready='true'
elif ! vm_create_output=$(gcloud compute instances create "$vm_name" \
    --project="$project" \
    --zone="$zone" \
    --subnet="$subnet" \
    --no-address \
    --machine-type="$vm_size" \
    --image-family="$DEFAULT_IMAGE_FAMILY" \
    --image-project="$DEFAULT_IMAGE_PROJECT" \
    --service-account="$service_account_email" \
    --scopes=cloud-platform \
    --labels=owner="${USER}",cluster="${cluster_name}",type=sandbox,created="$(date +%Y%m%d)" \
    --metadata=FALCON_CID="${FALCON_CID}" \
    --metadata-from-file=startup-script="$STARTUP_SCRIPT" \
    --quiet 2>&1); then
    Print_Error "Failed to create VM"
    [[ -n "$vm_create_output" ]] && Print_Error "$vm_create_output"
    Print_Error "Check quota/permission issues"
    exit 1
else
    Print_Status "VM created. Waiting for VM to be in RUNNING state..."

    max_wait=180
    elapsed=0
    until gcloud compute instances describe "$vm_name" \
        --zone="$zone" \
        --project="$project" \
        --format="value(status)" 2>/dev/null | grep -q "RUNNING"; do

        if [[ $elapsed -ge $max_wait ]]; then
            echo ""  # Newline after progress line
            Print_Warning "VM did not reach RUNNING state after ${max_wait}s"
            break
        fi

        echo -ne "\r  Waiting for VM to start... ${elapsed}s / ${max_wait}s"
        Log "Waiting for VM to start... (${elapsed}s elapsed)"
        sleep 10
        elapsed=$((elapsed + 10))
    done

    echo ""  # Newline after progress line
    Print_Status "VM is running. Waiting for startup script to complete..."
fi

# Get VM IP address
Print_Status "Getting VM internal IP address..."
vm_internal_ip=$(gcloud compute instances describe "$vm_name" \
    --zone="$zone" \
    --project="$project" \
    --format="value(networkInterfaces[0].networkIP)" 2>&1)

if [[ -z "$vm_internal_ip" ]]; then
    Print_Error "Failed to get VM internal IP"
    exit 1
fi

Print_Status "VM internal IP: $vm_internal_ip"

# Setup VPC peering and master authorized networks if using external VPC
if [[ "$use_external_vpc" == 'true' ]]; then
    echo ""
    Print_Status "Configuring external VPC connectivity..."

    # Setup VPC peering
    if ! Setup_VPC_Peering "$cluster_network" "$external_vpc" "$project"; then
        Print_Error "Failed to setup VPC peering"
        exit 1
    fi

    # Add VM IP to master authorized networks
    if ! Add_To_Master_Authorized_Networks "$cluster_name" "$region" "$project" "$vm_internal_ip"; then
        Print_Error "Failed to add VM IP to master authorized networks"
        exit 1
    fi

    echo ""
fi

Print_Status "Checking if startup script has completed..."
max_attempts=12
attempt=0

until gcloud compute ssh "$vm_name" \
    --zone="$zone" \
    --project="$project" \
    --tunnel-through-iap \
    --command="test -f /var/run/sandbox-ready" \
    --quiet &>/dev/null; do

    attempt=$((attempt + 1))
    if [[ $attempt -ge $max_attempts ]]; then
        echo ""  # Newline after progress line
        Print_Warning "VM may not be fully initialized. Tools might still be installing."
        Print_Warning "You can check startup script logs with:"
        Print_Warning "  gcloud compute ssh $vm_name --zone=$zone --project=$project --tunnel-through-iap --command='sudo cat /var/log/sandbox-init.log'"
        break
    fi

    echo -ne "\r  Waiting for startup script... check ${attempt}/${max_attempts}"
    Log "Startup script still running... (attempt $attempt/$max_attempts)"
    sleep 15
done

echo ""  # Newline after progress line
[[ $attempt -lt $max_attempts ]] && { Log "VM is ready" ; vm_ready='true' ; }

if [[ "$vm_ready" == 'true' ]]; then
    Print_Status "Generating kubeconfig inside VM..."
    if ! gcloud compute ssh "$vm_name" \
        --zone="$zone" \
        --project="$project" \
        --tunnel-through-iap \
        --command="gcloud container clusters get-credentials $cluster_name --region=$region --project=$project --internal-ip" \
        --quiet &>/dev/null; then
        Print_Warning "Failed to generate kubeconfig inside VM. You can do it manually after connecting:"
        Print_Warning "  gcloud container clusters get-credentials $cluster_name --region=$region --project=$project --internal-ip"
    else
        Print_Status "Kubeconfig configured in VM at ~/.kube/config"
    fi
else
    Print_Warning "Skipping kubeconfig generation since VM is not fully ready"
    Print_Warning "After VM is ready, run this inside the VM:"
    Print_Warning "  gcloud container clusters get-credentials $cluster_name --region=$region --project=$project --internal-ip"
fi

# Configure git SSH key if specified and VM is ready
if [[ "$vm_ready" == 'true' ]] && [[ -n "$SSH_KEY_PATH" ]] && [[ -f "$SSH_KEY_PATH" ]]; then
    Print_Status "Configuring SSH key for git access..."

    key_filename=$(basename "$SSH_KEY_PATH")
    Log "Copying SSH key: $key_filename"

    # Copy SSH key to VM
    if gcloud compute scp "$SSH_KEY_PATH" \
        "$vm_name:.ssh/$key_filename" \
        --zone="$zone" \
        --project="$project" \
        --tunnel-through-iap \
        --quiet &>/dev/null; then

        # Set proper permissions and generate public key
        gcloud compute ssh "$vm_name" \
            --zone="$zone" \
            --project="$project" \
            --tunnel-through-iap \
            --command="chmod 600 ~/.ssh/$key_filename && ssh-keygen -y -f ~/.ssh/$key_filename > ~/.ssh/${key_filename}.pub 2>/dev/null || true" \
            --quiet &>/dev/null

        # Configure git if user info provided
        if [[ -n "$GIT_USER_NAME" ]] && [[ -n "$GIT_USER_EMAIL" ]]; then
            Log "Configuring git user: $GIT_USER_NAME <$GIT_USER_EMAIL>"
            gcloud compute ssh "$vm_name" \
                --zone="$zone" \
                --project="$project" \
                --tunnel-through-iap \
                --command="git config --global user.name '$GIT_USER_NAME' && git config --global user.email '$GIT_USER_EMAIL'" \
                --quiet &>/dev/null
        fi

        Print_Status "SSH key configured for git access"
    else
        Print_Warning "Failed to copy SSH key to VM"
    fi
fi


Print_Header "Sandbox Ready!"
cat << EOF

VM Details:
  Name:            $vm_name
  Internal IP:     $vm_internal_ip
  Zone:            $zone
  Machine Type:    $vm_size
  Service Account: $service_account_email
  Network:         $network
  Subnet:          $subnet


Cluster Access:
  Cluster:         $cluster_name
  Cluster Network: $cluster_network
  Kubeconfig:      ~/.kube/config (on VM)
EOF

if [[ "$use_external_vpc" == 'true' ]]; then
    cat << EOF
  VPC Peering:     Configured between $external_vpc <-> $cluster_network
  Authorized:      VM IP added to master_authorized_networks
EOF
fi

cat << EOF

Connect to VM:
  gcloud compute ssh $vm_name \\
    --zone=$zone \\
    --tunnel-through-iap \\
    --project=$project

On the VM, run:
  kubectl get nodes
  helm version

Delete when done:
  gcloud compute instances delete $vm_name \\
    --zone=$zone \\
    --project=$project \\
    --quiet

List your sandboxes:
  gcloud compute instances list \\
    --project=$project \\
    --filter="labels.owner=$USER AND labels.type=sandbox" \\
    --format="table(name,zone,machineType,creationTimestamp)"

EOF

Print_Status "Setup complete!"