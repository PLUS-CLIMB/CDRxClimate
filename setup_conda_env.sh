#!/bin/bash

# Setup conda environment for dvcube with esmpy from conda-forge

ENV_NAME="dvcube"

echo "Creating conda environment: $ENV_NAME"

# Create environment with Python 3.12
conda create -n $ENV_NAME python=3.12 -y

# Activate the environment
eval "$(conda shell.bash hook)"
conda activate $ENV_NAME

echo "Installing esmpy and xesmf from conda-forge..."
conda install -c conda-forge esmpy xesmf -y

echo "Installing remaining dependencies..."
pip install -e .

echo ""
echo "✓ Setup complete!"
echo ""
echo "To activate the environment, run:"
echo "  conda activate $ENV_NAME"
echo ""
echo "To deactivate, run:"
echo "  conda deactivate"
