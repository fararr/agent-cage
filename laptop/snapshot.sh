#!/usr/bin/env bash
# Run on YOUR LAPTOP. The create/destroy ritual, one level up.
set -euo pipefail
SERVER=${2:?usage: snapshot.sh <save|restore|destroy> <server-name> [snapshot-id]}
case "${1:?}" in
  save)
    hcloud server create-image --type snapshot \
      --description "agent-$(date +%F-%H%M)" "$SERVER"
    hcloud image list --type snapshot ;;
  restore)
    ID=${3:?snapshot id}
    hcloud server rebuild "$SERVER" --image "$ID"   # wipes the box back to the image
    ;;
  destroy)
    hcloud server delete "$SERVER" ;;
esac
