#!/bin/env bash
set -xeuo pipefail

## Turn off "pip install" customizations from the conda build environment.
#
# This package incorporates ComfyUI together with its PyPI dependencies, including
# the PyTorch CUDA wheels, the same way upstream installs them. To do this, pip install
# must work like normal, so this code turns off the conda build defaults for pip.
unset PIP_NO_DEPENDENCIES
unset PIP_IGNORE_INSTALLED
unset PIP_NO_INDEX
# Don't keep the multi-GB wheel cache on the build worker's disk alongside the
# prefix, the package and the test environment.
export PIP_NO_CACHE_DIR=1

pip_install() {
    # Run pip install with --log, to print out detailed info about the build process
    set +e
    rm -f "$SRC_DIR/pip_install_result.log"
    pip install "$@" --log "$SRC_DIR/pip_install_result.log"
    INSTALL_RESULT="$?"
    set -e
    if [ "$INSTALL_RESULT" != "0" ]; then
        cat "$SRC_DIR/pip_install_result.log"
        echo "openjd_status: Failed to pip install $@"
        exit 1
    fi
}

# Copy the ComfyUI source into the package.
mkdir -p "$PREFIX/opt"
cp -r "$SRC_DIR/comfyui" "$PREFIX/opt/"

# Apply the torch pins to both pip invocations. Without them, the second install from
# PyPI can replace the CUDA torch build when a dependency asks for a different torch.
printf 'torch==%s\ntorchvision==%s\n' "$TORCH_VERSION" "$TORCHVISION_VERSION" > "$SRC_DIR/constraints.txt"

echo "openjd_status: Installing PyTorch $TORCH_VERSION ($TORCH_CUDA_INDEX)"
pip_install -c "$SRC_DIR/constraints.txt" torch torchvision \
    --index-url "https://download.pytorch.org/whl/$TORCH_CUDA_INDEX"

# manager_requirements.txt is not installed. ComfyUI-Manager is off by default
# (--enable-manager), and it can't install nodes into a shared, cached conda env.
echo "openjd_status: Installing ComfyUI $PKG_VERSION requirements"
pip_install -c "$SRC_DIR/constraints.txt" -r "$PREFIX/opt/comfyui/requirements.txt"
pip check

# Record the resolved environment. Most upstream dependencies are unpinned, so this
# makes every build auditable.
pip freeze > "$PREFIX/opt/comfyui/pip-freeze.txt"

# Install the launcher as the comfyui command.
install -m 0755 "$RECIPE_DIR/comfyui-launcher.sh" "$PREFIX/bin/comfyui"

# Set environment variables using the JSON env_vars.d mechanism.
# See https://rattler-build.prefix.dev/latest/special_files/ for details.
# PYTHONUNBUFFERED streams ComfyUI's output to task logs as it happens.
mkdir -p "$PREFIX/etc/conda/env_vars.d"
cat > "$PREFIX/etc/conda/env_vars.d/$PKG_NAME-$PKG_VERSION.json" << EOF
{
  "COMFYUI_LOCATION": "$PREFIX/opt/comfyui",
  "COMFYUI_VERSION": "$PKG_VERSION",
  "PYTHONUNBUFFERED": "1"
}
EOF

echo "openjd_status: Finished comfyui package build"
