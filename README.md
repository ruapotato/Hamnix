# Hamnix

Hamnix is an advanced AI-powered Linux terminal simulator that uses a fine-tuned large language model to provide a realistic command-line experience. It processes input commands and generates responses that mimic real terminal behavior, allowing users to practice and learn Linux commands in a safe, simulated environment.

## Features

- Realistic simulation of Linux terminal environment
- Support for a wide range of common Linux commands
- Command history navigation
- Basic tab completion
- Simulated file system state maintenance
- Error handling and appropriate error messages
- Interactive learning environment for Linux command practice

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

3. Download or prepare your trained model and update the `model_path` in the `run_hamnix.py` script.

## Usage

Run the script:

```
python ./bin/run_hamnix.py
```

Use the terminal simulator as you would a regular Linux terminal. Enter commands and receive simulated responses.

## Training Data

Hamnix now uses an InstructGPT approach for fine-tuning. The training data is expected to be in the following format:

```json
{"current_dir": "/home/user", "input": "ls -l", "stdout": "total 0\ndrwxr-xr-x 2 user user 4096 Jul 8 10:00 Documents\ndrwxr-xr-x 2 user user 4096 Jul 8 10:00 Downloads"}
{"current_dir": "/", "input": "pwd", "stdout": "/"}
{"current_dir": "/etc", "input": "cat hosts", "stdout": "127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\nfe00::0 ip6-localnet\nff00::0 ip6-mcastprefix\nff02::1 ip6-allnodes\nff02::2 ip6-allrouters"}
```

Each entry represents the current directory, a command, and its corresponding output in the simulated terminal environment.

## Project Structure

The project is organized as follows:

```
hamnix/
├── bin/
│   ├── chroot_bin/
│   │   ├── auto_term.py
│   │   └── bash_cmds.txt
│   ├── model_tester.py
│   ├── old/
│   │   ├── done/
│   │   │   ├── bash_cmds.txt
│   │   │   ├── cd_ls.jsonl
│   │   │   └── terminal_log.jsonl
│   │   └── train_data/
│   │       ├── cd_ls.jsonl
│   │       └── terminal_log.jsonl
│   ├── run_hamnix.py
│   ├── setup_and_run_chroot.sh
│   └── train_data/
│       └── terminal_log.jsonl
├── qwen_finetune_config.yml
└── [other project files and directories]
```

## Training

To train the model using the InstructGPT approach:

1. Prepare your training data in the format described above.
2. Update the `qwen_finetune_config.yml` file with appropriate parameters.
3. Run the fine-tuning script (not included in this repository).

## Current Status and Ongoing Work

Hamnix is an ongoing project with active development. Current focus areas include:

- Improving consistency in maintaining file system state
- Enhancing performance on complex commands and long sequences
- Reducing hallucination of non-existent files or directories
- Implementing a web interface for easier access
- Developing specific learning modules for different Linux topics

## Contributing

Contributions to Hamnix are welcome! Please feel free to submit pull requests, create issues, or suggest new features. We're particularly interested in contributions that address our current focus areas.

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

This project was developed with assistance from Claude.ai, an AI language model created by Anthropic, PBC.
