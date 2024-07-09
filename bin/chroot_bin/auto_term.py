#!/usr/bin/python3
import sys
import json
import os
import subprocess
import random
import argparse

def write_to_config(config_file, data):
    formatted_data = {
        "current_dir": data['current_dir'],
        "input": data['input'],
        "stdout": data['stdout']
    }
    if data['stderr']:
        formatted_data['stdout'] += f"\nError: {data['stderr']}"
    
    with open(config_file, 'a') as f:
        json.dump(formatted_data, f)
        f.write('\n')

def read_commands_from_file(filename):
    with open(filename, 'r') as f:
        return [line.strip() for line in f if line.strip()]

def get_valid_subdirectories(path):
    try:
        return [d for d in os.listdir(path) if os.path.isdir(os.path.join(path, d)) and not d.startswith('.')]
    except (PermissionError, FileNotFoundError):
        return []

def generate_random_path(current_path):
    if random.choice([True, False]):  # Decide between absolute and relative path
        # Absolute path
        root_dirs = ['/bin', '/etc', '/home', '/usr', '/var']
        new_path = random.choice(root_dirs)
    else:
        # Relative path
        new_path = current_path

    for _ in range(random.randint(0, 3)):
        subdirs = get_valid_subdirectories(new_path)
        if not subdirs:
            break
        new_path = os.path.join(new_path, random.choice(subdirs))
    
    return new_path

def run_command(cmd, cwd):
    try:
        result = subprocess.run(cmd, shell=True, check=True, capture_output=True, text=True, cwd=cwd)
        return cmd, result.stdout.strip(), result.stderr.strip()
    except subprocess.CalledProcessError as e:
        return cmd, e.stdout.strip(), e.stderr.strip()

def main(num_random_commands):
    config_file = "terminal_log.jsonl"
    
    commands = read_commands_from_file('./bash_cmds.txt')
    current_path = "/"
    for cmd in commands:
        input_content, stdout_content, stderr_content = run_command(cmd, current_path)
        write_to_config(config_file, {
            "current_dir": current_path,
            "input": input_content,
            "stdout": stdout_content,
            "stderr": stderr_content
        })
    
    # Generate random navigation commands
    for _ in range(num_random_commands):
        new_path = generate_random_path(current_path)
        
        # Record the cd command
        write_to_config(config_file, {
            "current_dir": current_path,
            "input": f"cd {new_path}",
            "stdout": f"Changed directory to {new_path}",
            "stderr": ""
        })
        
        current_path = new_path  # Update the current path
        
        # Run 'pwd' command
        write_to_config(config_file, {
            "current_dir": current_path,
            "input": "pwd",
            "stdout": current_path,
            "stderr": ""
        })
        
        # Run 'ls' with variations after each navigation
        ls_variation = random.choice(['ls -alh', 'ls -al', 'ls'])
        ls_cmd = f"{ls_variation}"
        _, stdout_content, stderr_content = run_command(ls_cmd, current_path)
        write_to_config(config_file, {
            "current_dir": current_path,
            "input": ls_cmd,
            "stdout": stdout_content,
            "stderr": stderr_content
        })

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate terminal commands for LLM training.")
    parser.add_argument("--num_commands", type=int, default=50000,
                        help="Number of random navigation commands to generate (default: 50000)")
    args = parser.parse_args()
    
    main(args.num_commands)
