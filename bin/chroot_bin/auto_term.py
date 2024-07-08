#!/usr/bin/python3
import sys
import json
import os
import subprocess
import random
import argparse

def write_to_config(config_file, data):
    formatted_data = f"Command: {data['input']}\nOutput:\n{data['stdout']}"
    if data['stderr']:
        formatted_data += f"\nError:\n{data['stderr']}"
    
    with open(config_file, 'a') as f:
        json.dump({"text": formatted_data}, f)
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
    for cmd in commands:
        input_content, stdout_content, stderr_content = run_command(cmd, '/')
        write_to_config(config_file, {
            "input": input_content,
            "stdout": stdout_content,
            "stderr": stderr_content
        })
    
    # Generate random navigation commands
    current_path = "/"
    for _ in range(num_random_commands):
        new_path = generate_random_path(current_path)
        
        # Record the cd command without actually running it
        write_to_config(config_file, {
            "input": f"cd {new_path}",
            "stdout": "",
            "stderr": ""
        })
        
        current_path = new_path  # Update the current path
        
        # Run 'pwd' command
        pwd_cmd = "pwd"
        _, stdout_content, stderr_content = run_command(pwd_cmd, current_path)
        write_to_config(config_file, {
            "input": pwd_cmd,
            "stdout": current_path,  # Use the current_path instead of actual output
            "stderr": stderr_content
        })
        
        # Run 'ls' with variations after each navigation
        ls_variation = random.choice(['ls -alh', 'ls -al', 'ls'])
        ls_cmd = f"{ls_variation}"
        _, stdout_content, stderr_content = run_command(ls_cmd, current_path)
        write_to_config(config_file, {
            "input": ls_cmd,
            "stdout": stdout_content,
            "stderr": stderr_content
        })

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate terminal commands for LLM training.")
    parser.add_argument("--num_commands", type=int, default=500000,
                        help="Number of random navigation commands to generate (default: 500000)")
    args = parser.parse_args()
    
    main(args.num_commands)
