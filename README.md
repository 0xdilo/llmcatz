# llmcatz 🐱
A cute and powerful tool to gather files into a format perfect for LLMs and AI assistants.

                  |\      _,,,---,,_
            ZZZzz /,`.-'`'    -.  ;-;;,_
                 |,4-  ) )-,_. ,\ (  `'-'
                '---''(_/--'  `-'\_) 

## What is llmcatz?
`llmcatz` is a lightning-fast utility that scans your codebase and creates a structured output optimized for AI assistants like Claude, ChatGPT, or other LLMs. It formats your file structure and contents, optionally counts tokens, and supports clipboard integration for easy pasting.

## Features
- 🚀 **Super Fast**: Written in Zig for maximum performance.
- 🧵 **Multi-threaded**: Processes files in parallel (customizable thread count).
- 📋 **Clipboard Integration**: Copies results to your clipboard (X11/Wayland).
- 🔍 **Flexible Targeting**: Process files, directories, or GitHub repositories.
- 🙈 **Exclusion Patterns**: Skip files or directories you don’t want.
- 🔎 **Interactive Selection**: Use `fzf` to pick files interactively.
- 🧮 **Token Counting**: Count tokens using TikToken encodings (e.g., `cl100k_base`).
- 📊 **JSON Export**: Export results in JSON format for programmatic use.
- 🐱 **Adorable ASCII Art**: Because why not?

## Dependencies
- [Zig](https://ziglang.org/) (for building the main binary)
- [Rust](https://www.rust-lang.org/) (for building the `tiktoken_ffi` library)
- [fzf](https://github.com/junegunn/fzf) (optional, for interactive file selection)
- `xclip` or `wl-copy` (optional, for clipboard support on X11 or Wayland)

## Installation
1. **Install Dependencies**:
   - Zig: Follow [official instructions](https://ziglang.org/download/).
   - Rust: Install via [rustup](https://rustup.rs/).
   - `fzf`, `xclip`, or `wl-copy`: Use your package manager (e.g., `apt`, `brew`).

2. **Clone and Build**:
   ```bash
   git clone https://github.com/0xdilo/llmcatz
   cd llmcatz
   ./build.sh

3. **Optionally, install globally:**
   ```bash
    sudo mv zig-out/bin/llmcatz /usr/local/bin/

## Usage
```bash
llmcatz [OPTIONS] [TARGETS...]

# Interactive file selection with fzf
llmcatz -f
# Print to stdout
llmcatz -p src/
# Save to file
llmcatz -o output.txt src/
# Exclude patterns
llmcatz -e ".git,node_modules" src/
# Set thread count
llmcatz -t 8 src/
# Process specific files
llmcatz file1.txt file2.txt
# Clone and process a GitHub repository
llmcatz https://github.com/username/repo
# Use a specific token encoding
llmcatz --encoding o200k_base src/
# Count total files processed
llmcatz --count-files src/
# Count tokens only
llmcatz --count-tokens src/
# Export to JSON format
llmcatz --json -o output.json src/

