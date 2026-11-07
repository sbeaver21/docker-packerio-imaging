#!/bin/bash

set -e
set -x

# Prevents popup questions
export DEBIAN_FRONTEND="noninteractive"

# Reset network to default from netplan
echo "Reseting network back to default"
sudo rm -f /etc/netplan/00-installer-config.yaml


# Network has been reset
echo "####################################################"
echo "Network has been reset"
echo "####################################################"