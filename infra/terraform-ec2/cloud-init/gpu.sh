#!/bin/bash
# GPU box bootstrap — Docker + AWS CLI + NVIDIA driver + container toolkit so
# Rhobots Extract can reach the A10G from inside a container. Deploy Rhobots Extract itself with
# deploy/ec2/docker-compose.gpu.yml (see the EC2 deployment guide §9).
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg unzip

# Docker Engine + Compose plugin.
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
usermod -aG docker ubuntu

# AWS CLI v2.
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

# NVIDIA GPU driver (A10G).
apt-get install -y ubuntu-drivers-common
ubuntu-drivers install --gpgpu

# NVIDIA Container Toolkit — lets Docker expose the GPU to containers.
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  > /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update
apt-get install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

install -d -o ubuntu -g ubuntu /opt/insur-iq
# NOTE: A10G driver load may require one reboot. `nvidia-smi` should report the
# GPU before deploying Rhobots Extract; if not, `sudo reboot` once.
