#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

echo "Building Warewulf overlay..."
wwctl overlay build

echo "Running cleanup..."
./clean-up.sh

echo "Rebooting control nodes 0-10..."
wwctl ssh control[0-10] reboot

echo "Done!"
