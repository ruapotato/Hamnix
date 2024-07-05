# Hamnix

Hamnix is an advanced terminal emulator that uses a fine-tuned large language model to simulate a Linux terminal environment. It processes input character-by-character and generates responses that mimic real terminal behavior, including VT100 control sequences.

## Features

- Character-by-character input processing
- VT100 control sequence parsing and execution
- Command history navigation
- Basic tab completion
- Cursor movement within the current line
- Backspace and line editing support

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

Use the terminal emulator as you would a regular Linux terminal. Special key combinations are supported:

- Up/Down arrows: Navigate command history
- Left/Right arrows: Move cursor within the current line
- Tab: Basic command completion
- Ctrl+C: Exit the emulator

## Training Data

Hamnix expects the model to be trained on data in the following format:

```json
{"text": "\nc"}
{"text": "c\na"}
{"text": "ca\nt"}
{"text": "cat\n\n"}
{"text": "cat\n\ncat: file.txt: No such file or directory\r\n\u001b[?2004huser@host:~$ "}
```

Each line represents a state transition in the terminal, with the input character and resulting output.

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
