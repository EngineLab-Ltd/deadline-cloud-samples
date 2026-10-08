#!/bin/env bash
set -xeuo pipefail

## Turn off "pip install" customizations from the conda build environment.
#
# comfy-cli installs ComfyUI's dependencies from PyPI and the PyTorch index with pip,
# so pip install must work like normal.
unset PIP_NO_DEPENDENCIES
unset PIP_IGNORE_INSTALLED
unset PIP_NO_INDEX
# Don't keep the multi-GB wheel cache on the build worker's disk.
export PIP_NO_CACHE_DIR=1
# Don't let comfy-cli prompt for, or send, usage analytics.
export COMFY_NO_TELEMETRY=1
# comfy-cli installs ComfyUI's dependencies into the active conda environment. Point it at
# this package's prefix, so that it doesn't create a .venv of its own.
export CONDA_PREFIX="$PREFIX"
unset VIRTUAL_ENV

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

echo "openjd_status: Installing comfy-cli $COMFY_CLI_VERSION"
pip_install "comfy-cli==$COMFY_CLI_VERSION"

# comfy-cli clones the ComfyUI release, then installs torch, torchvision and torchaudio from
# the CUDA index and ComfyUI's requirements.txt. ComfyUI-Manager is skipped, because it
# can't install nodes into a shared, cached conda env.
echo "openjd_status: Installing ComfyUI $COMFYUI_VERSION with comfy-cli (CUDA $CUDA_VERSION)"
mkdir -p "$PREFIX/opt"
comfy --skip-prompt --workspace "$PREFIX/opt/comfyui" install \
    --version "$COMFYUI_VERSION" \
    --nvidia --cuda-version "$CUDA_VERSION" \
    --skip-manager

if [ -d "$PREFIX/opt/comfyui/.venv" ]; then
    echo "openjd_status: comfy-cli created its own .venv instead of using the conda environment"
    exit 1
fi
test -f "$PREFIX/opt/comfyui/main.py"
pip check

# Record the resolved environment, including the torch version that comfy-cli chose.
pip freeze > "$PREFIX/opt/comfyui/pip-freeze.txt"
grep -E "^(torch|torchvision|torchaudio|comfy-cli)==" "$PREFIX/opt/comfyui/pip-freeze.txt"

# Set environment variables using the JSON env_vars.d mechanism.
# See https://rattler-build.prefix.dev/latest/special_files/ for details.
mkdir -p "$PREFIX/etc/conda/env_vars.d"
cat > "$PREFIX/etc/conda/env_vars.d/$PKG_NAME-$PKG_VERSION.json" << EOF
{
  "COMFYUI_LOCATION": "$PREFIX/opt/comfyui",
  "COMFYUI_VERSION": "$PKG_VERSION",
  "COMFY_CLI_VERSION": "$COMFY_CLI_VERSION",
  "COMFY_NO_TELEMETRY": "1",
  "PYTHONUNBUFFERED": "1"
}
EOF

echo "openjd_status: Finished comfy package build"
