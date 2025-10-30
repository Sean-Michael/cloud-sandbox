# cloud-sandbox

This repository will house various platform utilities for creating resources in public clouds.

Mostly it will include some basic CLI wrappers in Bash, eventually it may contain more .. who knows!

It's all in the name of fun and to document problems that I've had to solve in my work.

Everything is free to copy, modify, etc.

## GCP Sandbox VM provisioning for Private GKE Cluster access

The `/gcp/gke-vm/` directory includes the `gke-sandbox.sh` script which allows one to create, list, and delete VMs for GKE administration.

The VMs are preconfigured with networking and kubectl access  to the Control Plane API Sever along with necessary tools (helm, kubectl, jq, etc. ) for performing operations on the cluster. (All customizable in a startup script)

Access is handled securely via IAP Tunelling.

For more information, see the [README](./gcp/gke-vm/README.md)
