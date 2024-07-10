#!/usr/bin/python3
import json
import argparse
import os

def preprocess_data(input_file, output_file):
    with open(input_file, 'r') as infile, open(output_file, 'w') as outfile:
        current_state = ""
        
        for line in infile:
            data = json.loads(line)
            if data['type'] == 'input':
                input_char = data['content']
                output = ""
                new_state = current_state + input_char
            elif data['type'] == 'output':
                input_char = "\n"  # Assuming output comes after a newline
                output = data.get('vt100', '')
                new_state = ""  # Reset state after output
            
            json.dump({"text": f"{current_state}\n{input_char}{output}"}, outfile)
            outfile.write('\n')
            
            current_state = new_state.strip()  # Update state, removing any trailing newlines

def main():
    parser = argparse.ArgumentParser(description="Preprocess terminal data for LLM training.")
    parser.add_argument("input_file", help="Path to the input JSONL file")
    parser.add_argument("output_file", help="Path to save the preprocessed JSONL file")
    args = parser.parse_args()

    # Ensure the output directory exists
    os.makedirs(os.path.dirname(args.output_file), exist_ok=True)

    preprocess_data(args.input_file, args.output_file)
    print(f"Preprocessed data saved to {args.output_file}")

if __name__ == "__main__":
    main()
