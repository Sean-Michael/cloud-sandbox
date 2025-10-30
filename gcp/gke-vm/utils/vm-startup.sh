#!/bin/bash
# Startup script for GKE sandbox VMs
# Installs kubectl, helm, gcloud, and other essential tools

set -euo pipefail
exec > >(tee /var/log/sandbox-init.log)
exec 2>&1

echo "$(date): Starting sandbox initialization"

# Add Google Cloud SDK repo
echo "$(date): Adding Google Cloud SDK repository..."
apt-get install -y apt-transport-https ca-certificates gnupg curl
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list

# Add Kubernetes repo
echo "$(date): Adding Kubernetes repository..."
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | gpg --dearmor -o /usr/share/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

# Update and install tools
echo "$(date): Running apt-get update..."
apt-get update || { echo "ERROR: apt-get update failed" >&2 ; exit 1 ; }

echo "$(date): Installing packages..."
if ! apt-get install -y \
    kubectl \
    google-cloud-sdk-gke-gcloud-auth-plugin \
    git \
    vim \
    tmux \
    jq \
    htop; then
    echo "ERROR: Package installation failed" >&2
    exit 1
fi

# Install helm
echo "$(date): Installing Helm..."
if ! curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; then
    echo "ERROR: Helm installation failed" >&2
    exit 1
fi

# Create .kube directory for all users
echo "$(date): Creating .kube directory..."
mkdir -p /etc/skel/.kube
chmod 755 /etc/skel/.kube

# Mark setup complete
touch /var/run/sandbox-ready
echo "$(date): Sandbox initialization complete"
