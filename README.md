# Hamnix

Hamnix is an advanced terminal emulator that uses a fine-tuned large language model to simulate a Linux terminal environment. It processes input commands and generates responses that mimic real terminal behavior.

## Features

- Command-based input processing
- Realistic terminal output generation
- Command history navigation
- Basic tab completion
- Simulated Linux environment

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

3. Download or prepare your trained model and update the `model_path` in the script.

## Usage

Run the script:

```
python ./bin/run_hamnix.py
```

Use the terminal emulator as you would a regular Linux terminal. Enter commands and receive simulated responses.

## Training Data

Hamnix expects the model to be trained on data in the following format:

```json
{"text": "Command: pwd\nOutput:\n/"}
{"text": "Command: ls\nOutput:\nbin\nboot\ndev\netc\nhome\nlib\nlib64\nmedia\nmnt\nopt\nproc\nroot\nrun\nsbin\nsrv\nsys\ntmp\nusr\nvar"}
{"text": "Command: echo $HOME\nOutput:\n/root"}
```

Each entry represents a command and its corresponding output in the simulated terminal environment.

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

## Contributing

Contributions to Hamnix are welcome! Please feel free to submit pull requests, create issues, or suggest new features.

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
