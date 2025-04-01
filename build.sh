#!/bin/bash

# Exit on any error
set -e

# Define colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Check for required tools
command -v cargo >/dev/null 2>&1 || { echo -e "${RED}Error: Cargo is not installed. Please install Cargo.${NC}"; exit 1; }
command -v zig >/dev/null 2>&1 || { echo -e "${RED}Error: Zig is not installed. Please install Zig.${NC}"; exit 1; }

# Build the Rust tiktoken_ffi library
echo -e "${GREEN}Building Rust tiktoken_ffi library...${NC}"
cd tiktoken_ffi
cargo build --release
cd ..

# Build the Zig project
echo -e "${GREEN}Building Zig project...${NC}"
zig build -Doptimize=ReleaseSmall

# Install the binary (optional)
echo -e "${GREEN}Installing llmcatz binary...${NC}"
if [ -f "zig-out/bin/llmcatz" ]; then
    read -p "Do you want to install llmcatz globally (requires sudo)? [y/N] " install_globally
    if [[ "$install_globally" =~ ^[Yy]$ ]]; then
        sudo mv zig-out/bin/llmcatz /usr/local/bin/llmcatz
        echo -e "${GREEN}Success:${NC} Installation complete!"
        echo -e "${GREEN}Info:${NC} You can now run 'llmcatz' from anywhere."
    else
        echo -e "${GREEN}Info:${NC} To install manually, run:"
        echo -e "      cp zig-out/bin/llmcatz /path/to/your/bin/directory"
    fi
else
    echo -e "${RED}Error:${NC} Binary not found. Build may have failed."
    exit 1
fi

# Cleanup
echo -e "${GREEN}Cleaning up...${NC}"
rm -rf zig-cache zig-out

echo -e "${GREEN}Success:${NC} Build process completed!"
