# Hamnix

Hamnix is an advanced AI-powered terminal simulator that uses a large language model to provide a unique command-line experience. It processes input commands and generates responses that mimic terminal behavior, allowing users to interact with an AI-driven command-line interface.

## Features

- AI-powered simulation of a terminal environment
- Dynamic command generation based on user input
- Intelligent caching of generated commands
- Advanced tab completion for commands and filesystem paths
- Redo functionality for command regeneration
- Support for a wide range of commands
- Command history navigation
- Simulated file system state (with occasional creative interpretations)
- Error handling and appropriate (sometimes humorous) error messages
- Interactive environment for exploring AI-generated command responses

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

Run the script:

```
python ./bin/hamnix_v2.py
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
│   ├── hamnix_v2.py
│   └── [other script files]
└── [other project files and directories]
```

## Current Status and Ongoing Work

Hamnix is an ongoing project with active development. Current focus areas include:

- Improving consistency in command interpretation and response generation
- Enhancing the realism of the simulated file system state
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

This project used Claude.ai.
