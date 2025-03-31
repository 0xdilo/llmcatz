# llmcatz 🐱
A cute and powerful tool to gather files into a format perfect for LLMs and AI assistants.

                  |\      _,,,---,,_
            ZZZzz /,`.-'`'    -.  ;-;;,_
                 |,4-  ) )-,_. ,\ (  `'-'
                '---''(_/--'  `-'\_) 

## What is llmcatz?
llmcatz is a lightning-fast utility that scans your codebase and creates a neat, structured output that's perfect for pasting into AI assistants like Claude, ChatGPT, or other LLMs. It automatically formats your file structure and contents in a way that helps AIs understand your project better.

## Features
- 🚀 Super fast: Written in Zig for maximum performance
- 🧵 Multi-threaded: Processes files in parallel
- 📋 Clipboard integration: Copies results directly to your clipboard
- 🔍 Flexible targeting: Process individual files, directories, or even remote repositories (coming soon!)
- 🙈 Exclusion patterns: Skip files you don't want to include
- 🔎 Interactive file selection: Use fzf to pick files interactively
- 🐱 Adorable cat ASCII art

## Dependencies
- [Zig](https://ziglang.org/) (for building)
- [fzf](https://github.com/junegunn/fzf) (for interactive file selection)
- xclip or wl-copy (for clipboard support on X11 or Wayland respectively)

## Installation
1. Ensure you have Zig, fzf, and either xclip or wl-copy installed on your system.

2. Build llmcatz:
   ```bash
   git clone https://github.com/0xdilo/llmcatz
   cd llmcatz
   zig build

3. Optional: Move the binary to a directory in your PATH:
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

