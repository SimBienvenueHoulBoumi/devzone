#!/usr/bin/env bash
# Docker of the workstation not shared (option docker-hote=off, #432). post-create.sh
# installs this script as the docker command when the docker-outside-of-docker
# feature is absent: instead of a « command not found », a clear message points
# to the Kubernetes workspace.
cat >&2 <<'MESSAGE'
✖ Docker of the workstation not shared (option docker-hote=off): docker is not available here.
  To run containers, use the Kubernetes workspace: devzone workspace
  (docker and Testcontainers talk to kubedock there, images are built by BuildKit).
  To share the host Docker socket: devzone enable docker-hote, then make rebuild on the workstation.
MESSAGE
exit 1
