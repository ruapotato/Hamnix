#!/usr/bin/python3
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer
import re
import sys
import termios
import tty
import os
import readline

class VT100Parser:
    def __init__(self):
        self.buffer = ""
        self.vt100_regex = re.compile(r'\x1b\[[0-9;]*[a-zA-Z]')

    def process_output(self, model_output):
        self.buffer += model_output
        processed_output = []
        
        while True:
            match = self.vt100_regex.search(self.buffer)
            if not match:
                break
            
            before_seq = self.buffer[:match.start()]
            vt_seq = match.group()
            self.buffer = self.buffer[match.end():]
            
            if before_seq:
                processed_output.append(("text", before_seq))
            processed_output.append(("vt100", vt_seq))
        
        if self.buffer:
            processed_output.append(("text", self.buffer))
            self.buffer = ""
        
        return processed_output

class TerminalEmulator:
    def __init__(self, model_path):
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.model = AutoModelForCausalLM.from_pretrained(model_path, torch_dtype="auto").to(self.device)
        self.tokenizer = AutoTokenizer.from_pretrained(model_path)
        self.current_state = ""
        self.parser = VT100Parser()
        self.command_history = []
        self.history_index = 0
        self.current_line = ""
        self.cursor_pos = 0

    def generate_response(self, input_char):
        prompt = f"{self.current_state}\n{input_char}"
        inputs = self.tokenizer(prompt, return_tensors="pt").to(self.device)

        with torch.no_grad():
            output = self.model.generate(
                **inputs,
                max_new_tokens=100,
                do_sample=True,
                temperature=0.7,
                pad_token_id=self.tokenizer.eos_token_id
            )

        response = self.tokenizer.decode(output[0], skip_special_tokens=True)
        # Find the last occurrence of the prompt in the response
        last_prompt_index = response.rfind(prompt)
        if last_prompt_index != -1:
            response = response[last_prompt_index + len(prompt):]
        return response

    def display_output(self, processed_output):
        for output_type, content in processed_output:
            if output_type == "text":
                sys.stdout.write(content)
            elif output_type == "vt100":
                sys.stdout.write(content)  # For now, we're just writing VT100 sequences directly
            sys.stdout.flush()

    def handle_special_keys(self, char):
        if char == '\x1b':  # ESC sequence
            next_char = sys.stdin.read(1)
            if next_char == '[':
                key = sys.stdin.read(1)
                if key == 'A':  # Up arrow
                    self.handle_up_arrow()
                elif key == 'B':  # Down arrow
                    self.handle_down_arrow()
                elif key == 'C':  # Right arrow
                    self.handle_right_arrow()
                elif key == 'D':  # Left arrow
                    self.handle_left_arrow()
        elif char == '\t':  # Tab
            self.handle_tab_completion()
        elif char in ('\x7f', '\x08'):  # Backspace
            self.handle_backspace()
        else:
            return False
        return True

    def handle_up_arrow(self):
        if self.history_index > 0:
            self.history_index -= 1
            self.set_current_line(self.command_history[self.history_index])

    def handle_down_arrow(self):
        if self.history_index < len(self.command_history) - 1:
            self.history_index += 1
            self.set_current_line(self.command_history[self.history_index])
        elif self.history_index == len(self.command_history) - 1:
            self.history_index += 1
            self.set_current_line("")

    def handle_right_arrow(self):
        if self.cursor_pos < len(self.current_line):
            self.cursor_pos += 1
            sys.stdout.write("\x1b[C")
            sys.stdout.flush()

    def handle_left_arrow(self):
        if self.cursor_pos > 0:
            self.cursor_pos -= 1
            sys.stdout.write("\x1b[D")
            sys.stdout.flush()

    def handle_tab_completion(self):
        # This is a basic implementation. You might want to enhance it based on your needs.
        completion = readline.get_completer()(self.current_line, 0)
        if completion:
            self.set_current_line(completion)

    def handle_backspace(self):
        if self.cursor_pos > 0:
            self.current_line = self.current_line[:self.cursor_pos-1] + self.current_line[self.cursor_pos:]
            self.cursor_pos -= 1
            sys.stdout.write('\b \b')
            sys.stdout.write(self.current_line[self.cursor_pos:] + ' ')
            sys.stdout.write('\b' * (len(self.current_line) - self.cursor_pos + 1))
            sys.stdout.flush()

    def set_current_line(self, new_line):
        sys.stdout.write('\r\x1b[K')  # Clear the current line
        sys.stdout.write(new_line)
        self.current_line = new_line
        self.cursor_pos = len(new_line)
        sys.stdout.flush()

    def run(self):
        print("Terminal Emulator (Press Ctrl+C to exit)")
        print("----------------------------------------")
        
        old_settings = termios.tcgetattr(sys.stdin)
        try:
            tty.setcbreak(sys.stdin.fileno())
            
            while True:
                char = sys.stdin.read(1)
                if char == '\n':
                    print()  # Move to next line
                    self.command_history.append(self.current_line)
                    self.history_index = len(self.command_history)
                    response = self.generate_response(self.current_line + '\n')
                    processed_output = self.parser.process_output(response)
                    self.display_output(processed_output)
                    self.current_state = ""
                    self.current_line = ""
                    self.cursor_pos = 0
                elif not self.handle_special_keys(char):
                    self.current_line = self.current_line[:self.cursor_pos] + char + self.current_line[self.cursor_pos:]
                    self.cursor_pos += 1
                    sys.stdout.write(char)
                    sys.stdout.write(self.current_line[self.cursor_pos:])
                    sys.stdout.write('\b' * (len(self.current_line) - self.cursor_pos))
                    sys.stdout.flush()
                self.current_state += char
        except KeyboardInterrupt:
            print("\nExiting...")
        finally:
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)

if __name__ == "__main__":
    model_path = "path/to/your/trained/model"  # Update this with your model path
    emulator = TerminalEmulator(model_path)
    emulator.run()
