# Hamnix

Hamnix is an advanced AI-powered terminal simulator that uses a large language model to provide a unique command-line experience. It processes input commands and generates responses that mimic terminal behavior, allowing users to interact with an AI-driven command-line interface.

## Features

- AI-powered simulation of a terminal environment
- Dynamic command generation based on user input
- Intelligent caching of generated commands
- Advanced tab completion for commands and filesystem paths
- Force regeneration of commands with '!' prefix
- Support for a wide range of commands
- Command history navigation
- Simulated file system state with persistent changes
- Error handling and appropriate error messages
- Interactive environment for exploring AI-generated command responses
- Kernel-shell architecture for improved stability and performance

## Installation

1. Clone the repository:
   ```
   git clone https://github.com/davidhamner/hamnix.git
   cd hamnix
   ```

2. Install the required dependencies:
   ```
   pip install torch transformers
   ```

3. Ensure you have the necessary model files for the DeepSeek Coder 6.7B Instruct model.

## Usage

1. Start the Hamnix kernel:
   ```
   python ./bin/hamnix_kernel.py
   ```

2. In a separate terminal, start the Hamnix shell:
   ```
   python ./bin/hamsh.py
   ```

Use the AI-powered terminal simulator by entering commands as you would in a regular terminal. Hamnix will generate responses based on its AI model.

Special features:
- Use tab for command and path completion.
- Start a command with '!' to force regeneration of that command.

## Project Structure

The project is organized as follows:

```
hamnix/
├── bin/
│   ├── abin/             # Directory for generated command scripts
├── hamnix_kernel.py  # Hamnix kernel script
├── hamsh.py          # Hamnix shell script

```

## Current Status and Ongoing Work

Hamnix is an ongoing project with active development. Current focus areas include:

- Improving stability and error handling in kernel-shell communication
- Enhancing the consistency of command execution and environment updates
- Expanding the range of recognized and properly handled commands
- Implementing more advanced features like piping and redirection
- Developing a web interface for easier access

## Contributing

Contributions to Hamnix are welcome! Please feel free to submit pull requests, create issues, or suggest new features. We're particularly interested in contributions that address our current focus areas or bring new ideas to the project.

## License

Hamnix is licensed under the GNU General Public License v3.0 (GPL-3.0).

Copyright (C) 2024 David Hamner

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.

## Acknowledgements

This project used Claude.ai for development assistance and documentation generation.
