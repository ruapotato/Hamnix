#!/usr/bin/env python3

import os
import sys
import shlex
import readline
import asyncio
import subprocess
import json
import logging

# Set up logging
logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s - %(message)s')

# Environment variables
env_vars = os.environ.copy()
logging.debug("Copied environment variables")

# Absolute path for abin directory
ABIN_PATH = os.path.abspath('./abin')
os.makedirs(ABIN_PATH, exist_ok=True)
logging.debug(f"Abin directory: {ABIN_PATH}")

async def communicate_with_kernel(message, timeout=30, retries=3):
    logging.debug(f"Communicating with kernel: {message}")
    for attempt in range(retries):
        try:
            reader, writer = await asyncio.open_unix_connection('/tmp/hamnix_kernel.sock')
            logging.debug("Connected to kernel socket")
            writer.write(json.dumps(message).encode() + b'\n')  # Add newline to signal end of message
            await writer.drain()
            logging.debug("Sent message to kernel")

            # Read the entire response with a timeout
            data = b''
            try:
                data = await asyncio.wait_for(reader.readuntil(b'\n'), timeout=timeout)
            except asyncio.TimeoutError:
                logging.warning(f"Timeout reached while reading response from kernel")
                if data:
                    logging.warning(f"Partial data received: {data}")
                raise

            logging.debug(f"Received data from kernel: {data}")
            writer.close()
            await writer.wait_closed()
            
            if not data:
                raise Exception("No data received from kernel")
            
            try:
                response = json.loads(data.decode().strip())
            except json.JSONDecodeError as e:
                logging.error(f"Failed to parse JSON response: {e}")
                raise Exception(f"Invalid JSON response from kernel: {data.decode()}")
            
            if "error" in response:
                raise Exception(response["error"])
            return response["result"]
        except (ConnectionResetError, ConnectionRefusedError) as e:
            if attempt < retries - 1:
                logging.warning(f"Connection error (attempt {attempt + 1}/{retries}): {str(e)}. Retrying...")
                await asyncio.sleep(1)  # Wait a bit before retrying
            else:
                logging.error(f"Failed to communicate with kernel after {retries} attempts")
                raise
        except Exception as e:
            logging.error(f"Error communicating with kernel: {str(e)}")
            raise

async def get_env():
    return await communicate_with_kernel({'type': 'get_env'})

async def execute_command(command, args, input_file=None, output_file=None, error_file=None, force_regenerate=False):
    logging.debug(f"Executing command: {command} with args: {args}")
    logging.debug(f"Input file: {input_file}, Output file: {output_file}, Error file: {error_file}")
    try:
        message = {
            'type': 'generate_command',
            'command': command,
            'args': args,
            'context_id': 'hamsh',
            'force_regenerate': force_regenerate
        }
        command_path = await communicate_with_kernel(message)
        logging.debug(f"Received command path from kernel: {command_path}")
        
        if not os.path.exists(command_path):
            logging.warning(f"Command file does not exist: {command_path}. Attempting to regenerate.")
            message['force_regenerate'] = True
            command_path = await communicate_with_kernel(message)
            logging.debug(f"Regenerated command path: {command_path}")
        
        if not os.path.exists(command_path):
            raise FileNotFoundError(f"Command file does not exist: {command_path}")
        
        cmd = [command_path] + args
        logging.debug(f"Full command: {cmd}")
        
        stdin = open(input_file, 'r') if input_file else None
        stdout = open(output_file, 'w') if output_file else subprocess.PIPE
        stderr = open(error_file, 'w') if error_file else subprocess.PIPE
        
        env = await get_env()
        
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=stdin,
            stdout=stdout,
            stderr=stderr,
            env=env
        )
        logging.debug(f"Started subprocess with PID: {process.pid}")
        
        stdout_data, stderr_data = await process.communicate()
        
        if stdout_data:
            if output_file:
                with open(output_file, 'wb') as f:
                    f.write(stdout_data)
            else:
                sys.stdout.buffer.write(stdout_data)
        
        if stderr_data:
            if error_file:
                with open(error_file, 'wb') as f:
                    f.write(stderr_data)
            else:
                sys.stderr.buffer.write(stderr_data)
        
        # Read and apply the updated environment
        try:
            with open('/tmp/hamnix_env_update.json', 'r') as f:
                updated_env = json.load(f)
            await communicate_with_kernel({'type': 'update_env', 'env_updates': updated_env})
            env = await get_env()
            os.environ.update(env)
            if env.get('PWD') != os.getcwd():
                os.chdir(env['PWD'])
                logging.debug(f"Changed directory to: {env['PWD']}")
        except FileNotFoundError:
            logging.debug("No environment update file found")
        except json.JSONDecodeError:
            logging.error("Error decoding environment update file")
        
        logging.debug(f"Command execution completed with return code: {process.returncode}")
        return process.returncode
    except Exception as e:
        logging.error(f"An error occurred during command execution: {str(e)}")
        print(f"An error occurred: {str(e)}", file=sys.stderr)
        return 1
    finally:
        if stdin and stdin != sys.stdin:
            stdin.close()
        if stdout and stdout != sys.stdout and stdout != subprocess.PIPE:
            stdout.close()
        if stderr and stderr != sys.stderr and stderr != subprocess.PIPE:
            stderr.close()

async def run_pipeline(commands, force_regenerate=False):
    logging.debug(f"Running pipeline with commands: {commands}")
    for i, cmd in enumerate(commands):
        logging.debug(f"Executing command {i+1}/{len(commands)}: {cmd}")
        command, *args = cmd
        input_file = output_file = error_file = None
        
        if '<' in args:
            input_index = args.index('<')
            input_file = args[input_index + 1]
            args = args[:input_index] + args[input_index + 2:]
            logging.debug(f"Input redirection detected: {input_file}")
        
        if '>' in args:
            output_index = args.index('>')
            output_file = args[output_index + 1]
            args = args[:output_index] + args[output_index + 2:]
            logging.debug(f"Output redirection detected: {output_file}")
        
        if '2>' in args:
            error_index = args.index('2>')
            error_file = args[error_index + 1]
            args = args[:error_index] + args[error_index + 2:]
            logging.debug(f"Error redirection detected: {error_file}")
        
        exit_code = await execute_command(command, args, input_file, output_file, error_file, force_regenerate)
        logging.debug(f"Command '{command}' completed with exit code: {exit_code}")
        
        if exit_code != 0:
            logging.warning(f"Command '{command}' failed with exit code {exit_code}")
            print(f"Command '{command}' failed with exit code {exit_code}", file=sys.stderr)
            break

def parse_command(command_string):
    logging.debug(f"Parsing command string: {command_string}")
    commands = [shlex.split(cmd.strip()) for cmd in command_string.split('|')]
    logging.debug(f"Parsed commands: {commands}")
    return commands

def command_completer(text, state):
    logging.debug(f"Command completion requested for: {text}, state: {state}")
    buffer = readline.get_line_buffer()
    line = shlex.split(buffer)
    
    if not line or len(line) == 1 and not buffer.endswith(' '):
        # Complete commands
        options = [cmd for cmd in os.listdir(ABIN_PATH) if cmd.startswith(text)]
        if state < len(options):
            logging.debug(f"Returning command completion: {options[state]}")
            return options[state]
    elif len(line) > 1 or (len(line) == 1 and buffer.endswith(' ')):
        # Complete filesystem paths
        completion = readline.get_completer()(text, state)
        logging.debug(f"Returning filesystem completion: {completion}")
        return completion
    
    logging.debug("No completion found")
    return None

async def main():
    logging.info("Starting Hamsh - The Hamnix Shell")
    print("Welcome to Hamsh - The Hamnix Shell!")
    print("Type 'exit' to quit. Press Tab for completion.")
    print("Start a command with '!' to force regeneration.")
    
    readline.set_completer(command_completer)
    readline.set_completer_delims(' \t\n')
    readline.parse_and_bind("tab: complete")
    
    while True:
        try:
            env = await get_env()
            prompt = f"{env.get('PWD', os.getcwd())}$ "
            user_input = input(prompt).strip()
            logging.debug(f"User input: {user_input}")
        except EOFError:
            logging.info("EOFError caught, exiting")
            print("\nGoodbye!")
            break
        
        if user_input.lower() == 'exit':
            logging.info("Exit command received, exiting")
            print("Goodbye!")
            break
        elif user_input == "":
            logging.debug("Empty input, continuing")
            continue
        elif user_input:
            readline.add_history(user_input)
            force_regenerate = False
            if user_input.startswith('!'):
                force_regenerate = True
                user_input = user_input[1:]
                logging.debug("Force regenerate flag set")
            
            try:
                commands = parse_command(user_input)
                logging.debug(f"Parsed commands: {commands}")
                await run_pipeline(commands, force_regenerate)
            except Exception as e:
                logging.error(f"An error occurred: {str(e)}")
                print(f"An error occurred: {str(e)}", file=sys.stderr)

if __name__ == "__main__":
    asyncio.run(main())
