#!/bin/bash

PRESET_HASH_FILE="$HOME/x-tools/preset_hash"

# Calculate the hash of the preset file
CURRENT_PRESET_HASH=$(sha256sum $GITHUB_WORKSPACE/musl-toolchain/preset.sh | awk '{print $1}')

echo "Current preset hash: $CURRENT_PRESET_HASH"

# Traverse to working directory
cd $GITHUB_WORKSPACE/musl-toolchain

# Set the preset
source preset.sh

# If the toolchain is not installed or the preset has changed or the preset hash file does not exist
if [ ! -d "$HOME/x-tools" ] || [ ! -f "$PRESET_HASH_FILE" ] || [ "$(cat $PRESET_HASH_FILE)" != "$CURRENT_PRESET_HASH" ]; then
  # Install dependencies
  sudo apt-get update
  sudo apt-get install -y autoconf automake libtool  libtool-bin unzip help2man python3-dev gperf bison flex texinfo gawk libncurses5-dev
  
  # Clone crosstool-ng
  git clone https://github.com/crosstool-ng/crosstool-ng
  
  # Configure and build crosstool-ng
  cd crosstool-ng
  # Use version 1.26
  git checkout crosstool-ng-1.26.0
  ./bootstrap
  ./configure --prefix=$HOME/ctng
  make
  make install
  # Add crosstool-ng to PATH
  export PATH=$HOME/ctng/bin:$PATH

 

  # Load toolchainc configuration
  ct-ng $CTNG_PRESET
  
  # Build the toolchain
  ct-ng build > build.log 2>&1
  
  # Set status to the exit code of the build
  status=$?
  
  # We store the log in a file because it bloats the screen too much
  # on GitHub Actions. We print it only if the build fails.
  echo "Build result:"
  if [ $status -eq 0 ]; then
    echo "Build succeeded"
    ls -la $HOME/x-tools
    # Store the current hash of preset.sh after successful build
    echo "$CURRENT_PRESET_HASH" > "$PRESET_HASH_FILE"    
  else
    echo "Build failed, here's the log:"
    cat .config
    cat build.log
  fi
fi

# Update toolchain variables: C compiler, C++ compiler, linker, and archiver
export CC=$HOME/x-tools/$CTNG_PRESET/bin/$CTNG_PRESET-gcc
export CXX=$HOME/x-tools/$CTNG_PRESET/bin/$CTNG_PRESET-g++
export LD=$HOME/x-tools/$CTNG_PRESET/bin/$CTNG_PRESET-ld
export AR=$HOME/x-tools/$CTNG_PRESET/bin/$CTNG_PRESET-ar

if [ "$CTNG_PRESET" = "x86_64-multilib-linux-musl" ]; then
  RUST_TARGET="x86_64-unknown-linux-musl"
elif [ "$CTNG_PRESET" = "aarch64-linux-musl" ]; then
  RUST_TARGET="aarch64-unknown-linux-musl"
else
  echo "Unsupported CTNG_PRESET: $CTNG_PRESET"
  exit 1
fi

TARGET_UNDERSCORE=${RUST_TARGET//-/_}
TARGET_UPPER=${TARGET_UNDERSCORE^^}

# Exports for cc crate
# https://docs.rs/cc/latest/cc/#external-configuration-via-environment-variables
export RANLIB_${TARGET_UNDERSCORE}=$HOME/x-tools/$CTNG_PRESET/bin/$CTNG_PRESET-ranlib
export CC_${TARGET_UNDERSCORE}=$CC
export CXX_${TARGET_UNDERSCORE}=$CXX
export AR_${TARGET_UNDERSCORE}=$AR
export LD_${TARGET_UNDERSCORE}=$LD

# Set environment variables for static linking
export OPENSSL_STATIC=true
export RUSTFLAGS="-C link-arg=-static"

# We specify the compiler that will invoke linker
export CARGO_TARGET_${TARGET_UPPER}_LINKER=$CC

# Add target
rustup target add $RUST_TARGET

# Install missing dependencies
cargo fetch --target $RUST_TARGET

# Patch missing include in librocksdb-sys-0.16.0+8.10.0. Credit: @supertypo
FILE_PATH=$(find $HOME/.cargo/registry/src/ -path "*/librocksdb-sys-0.16.0+8.10.0/*/offpeak_time_info.h")

if [ -n "$FILE_PATH" ]; then
  sed -i '1i #include <cstdint>' "$FILE_PATH"
else
  echo "No such file for sed modification."
fi
