# GKE Sandbox VM Management

CLI tool to manage sandbox VMs for accessing private GKE clusters. Private clusters have no public IPs, so you can't just run kubectl from your laptop. This tool creates, lists, and deletes VMs inside the cluster's network with everything pre-configured.

## What's a Private GKE Cluster?

No public IPs on nodes or control plane (`enable_private_endpoint=true`)

Only accessible from:

- VMs in the cluster's subnet (what this tool creates)
- VMs on a peered/same VPC (with authorized networks configured)

Full details: <https://cloud.google.com/kubernetes-engine/docs/how-to/private-clusters>

## Quick Start

```bash
# Create a sandbox VM
./gke-sandbox.sh create --cluster <CLUSTER-NAME>

# Wait ~2 minutes, then SSH in
./gke-sandbox.sh connect

# Now you can use kubectl and helm on the VM 
user@sbx-vm % kubectl get nodes
user@sbx-vm % helm version

# If SSH keys were specified in config, simply clone your repos
user@sbx-vm % git clone <REPO_URL>

# List all your sandbox VMs
./gke-sandbox.sh list

# Delete when done (with confirmation prompt)
./gke-sandbox.sh delete <VM-NAME>
```

## CLI Commands

The `gke-sandbox.sh` tool provides three main commands:

### Usage

```text
Usage: ./gke-sandbox.sh <command> [options]

Commands:
    create --cluster <name> [OPTIONS]
                                    Create a new GKE sandbox instance
                                    All options are passed to create-gcp-vm.sh
                                    Use './gke-sandbox.sh create --help' for detailed options

    list [PROJECT] [USER]           List GKE sandbox instances
                                    USER defaults to current user

    delete <vm-name> [PROJECT] [ZONE]
                                    Delete a GKE sandbox instance

Examples:
    ./gke-sandbox.sh create --cluster <CLUSTER-NAME>
    ./gke-sandbox.sh create --cluster <CLUSTER-NAME> --vm-size e2-standard-4
    ./gke-sandbox.sh list
    ./gke-sandbox.sh list <PROJECT-ID> <USERNAME>
    ./gke-sandbox.sh delete <VM-NAME>
    ./gke-sandbox.sh delete <VM-NAME> <PROJECT-ID> <ZONE>

Configuration:
    Defaults are loaded from: env/create-gcp-vm.cfg
```

### Create Workflow

Creates a new sandbox VM with pre-configured access to your GKE cluster:

```bash
# Basic usage
./gke-sandbox.sh create --cluster <CLUSTER-NAME>

# Custom VM size
./gke-sandbox.sh create --cluster <CLUSTER-NAME> --vm-size e2-standard-4

# Custom name
./gke-sandbox.sh create --cluster <CLUSTER-NAME> --vm-name <CUSTOM-VM-NAME>

# Different project/zone
./gke-sandbox.sh create --cluster <CLUSTER-NAME> \
  --project <PROJECT-ID> \
  --zone <ZONE>
```

**What Gets Created:**

- VM in the cluster's subnet (no external IP)
- Service account specific to your user with GKE permissions
- IAP firewall rule (one-time, allows SSH through Identity-Aware Proxy)
- Pre-installed tools: kubectl, helm, gcloud, git, vim, tmux, jq
- Kubeconfig already set up with cluster access
- Your SSH key copied to VM for git access (optional)

### List Workflow

Lists all sandbox VMs for a user and project:

```bash
# List your sandboxes (uses defaults from config)
./gke-sandbox.sh list

# List sandboxes for specific project and user
./gke-sandbox.sh list <PROJECT-ID> <USERNAME>

# List sandboxes for different project
./gke-sandbox.sh list <PROJECT-ID>
```

### Show Workflow

Shows the connection command for a VM:

```bash
# Interactive selection:
# NOTE: If there is only one VM, it's chosen automatically
./gke-sandbox show

# By VM name
./gke-sandbox show <VM-NAME>
```

### Connect Workflow

Connects to a VM via IAP SSH tunnel.

```bash
# Interactive selection:
# NOTE: If there is only one VM, it's chosen automatically
./gke-sandbox connect 

# By VM name
./gke-sandbox connect <VM-NAME>
```

### Delete Workflow

Deletes a sandbox VM with interactive confirmation:

```bash
# Delete a VM with interactive selection
./gke-sandbox.sh delete

# Delete a VM by name(will prompt for confirmation)
./gke-sandbox.sh delete <VM-NAME>

# Delete VM in different project/zone
./gke-sandbox.sh delete <VM-NAME> <PROJECT-ID> <ZONE>
```

The delete command will:

1. Verify the VM exists
2. Show VM details (name, zone, IP, creation time, labels)
3. Prompt for confirmation (requires typing "yes")
4. Delete the VM (~90 seconds)
5. Check for associated IAP firewall rule
6. Prompt whether to delete the IAP rule (if found)
7. Delete the IAP rule if confirmed

**Note:** The IAP firewall rule is shared across all VMs in the same network. Only delete it if you're sure no other VMs need IAP SSH access on that network.

## Configuration

All commands use defaults from `env/create-gcp-vm.cfg`. Copy the example file to get started:

```bash
cp env/EXAMPLE-create-gcp-vm.cfg env/create-gcp-vm.cfg
```

Then edit `env/create-gcp-vm.cfg` to customize:

```bash
# Configuration for GKE Sandbox VM Creation Script
# Source this file to load default values

# GCP Project Configuration
DEFAULT_PROJECT="<YOUR-GCP-PROJECT-ID>"
DEFAULT_ZONE="<YOUR-ZONE>"

# VM Configuration
DEFAULT_VM_SIZE="e2-medium"
DEFAULT_IMAGE_FAMILY="ubuntu-2204-lts"
DEFAULT_IMAGE_PROJECT="ubuntu-os-cloud"

# IAM Roles for Service Account
REQUIRED_ROLES=(
    'roles/container.developer'
    'roles/container.clusterViewer'
    'roles/artifactregistry.reader'
)

# SSH Key Configuration (for git clone access)
# Leave empty to skip git/SSH setup entirely
# Specify the path to your SSH private key: SSH_KEY_PATH="$HOME/.ssh/id_ed25519"
SSH_KEY_PATH=""

# Git Configuration (only used if SSH_KEY_PATH is set)
# Leave empty to skip git user configuration
GIT_USER_NAME="<YOUR-NAME>"
GIT_USER_EMAIL="<YOUR-EMAIL>"
```

**Note:** The config file is gitignored by default to protect sensitive values like `FALCON_CID` and SSH keys.

## How It Works

The `create` command workflow:

1. Looks up cluster's network and subnet
2. Creates/reuses a service account with these roles:
   - roles/container.developer (GKE access)
   - roles/container.clusterViewer (list clusters)
   - roles/artifactregistry.reader (pull images)
3. Creates VM in cluster subnet with no external IP
4. Runs startup script that installs tools
5. Generates kubeconfig inside VM with --internal-ip flag
6. You SSH in via IAP tunnel (no public IP needed)

## Standalone Usage

You can also run `create-gcp-vm.sh` directly as a standalone utility if you prefer:

```bash
./create-gcp-vm.sh --cluster <CLUSTER-NAME> --vm-size e2-standard-4
```

The standalone script provides the same functionality as `./gke-sandbox.sh create` but can be used independently in scripts or other automation workflows.

## Contributing

Bug reports, fixes, and feature addittions are greatly appreciated.

For bash scripts please refer to the [style guide](https://github.com/vossenjp/bashidioms-examples/blob/main/appa/bash_idioms_style_guide.md).

The use of a linting utility such as [shellcheck](https://www.shellcheck.net/) would also be appreciated.

To contribute to the codebase please submit a pull-request that is succinct in it's purpose (keep diffs small) and well documented. It's assumed that any code submitted to a PR is well tested prior to being opened for review.

## TODO

Some enhancements and updates are in varying states of progress.

- [ ] Externalize the full 'tool list' somehow for VM setup
- [ ] Allow for different 'profiles' of tooling, or to provide a custom script path
- [ ] Create an 'update' command that can install a custom script/profile to existing VMs
- [ ] Finish implementation of Peered VPC Access model (more complex networking)
- [ ] Create containerized option with ENV files or config file option
