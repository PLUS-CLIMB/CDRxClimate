# DVCube Setup Instructions

## Quick Setup with Conda

Since `esmpy` (required by `xesmf`) has complex C/Fortran dependencies, we install it from conda-forge.

### Step 1: Run the setup script

```bash
bash setup_conda_env.sh
```

This script will:
- Create a conda environment called `dvcube` with Python 3.12
- Install `esmpy` and `xesmf` from conda-forge
- Install remaining Python dependencies via pip

### Step 2: Activate the environment

```bash
conda activate dvcube
```

### Step 3: Verify installation

```bash
python -c "import xesmf; print(xesmf.__version__)"
```

## Manual Setup (if script doesn't work)

```bash
# Create environment
conda create -n dvcube python=3.12 -y

# Activate
conda activate dvcube

# Install problematic packages from conda-forge
conda install -c conda-forge esmpy xesmf -y

# Install remaining dependencies
pip install -e .
```

## Deactivate Environment

```bash
conda deactivate
```

## Troubleshooting

If you encounter issues, try:

```bash
conda clean --all
conda create -n dvcube python=3.12 -c conda-forge esmpy xesmf -y
conda activate dvcube
pip install -e .
```

## Working with Jupyter Notebooks

Make sure the environment is activated before running notebooks:

```bash
conda activate dvcube
jupyter notebook
```
