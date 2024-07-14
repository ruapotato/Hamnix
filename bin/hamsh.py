#!/usr/bin/env python3

import os
import sys
import shlex
import readline
import asyncio
import json
from hamnix_logger import setup_logger
from hamnix_lib import communicate_with_kernel, ABIN_PATH, extend_script

logger = setup_logger(__name__)

async def stream_output(stream, file):
    while True:
        line = await stream.readline()
        if not line:
            break
        file.buffer.write(line)
        file.flush()

async def execute_command(command, args, input_file=None, output_file=None, error_file=None, force_regenerate=False):
    logger.debug(f"Executing command: {command} with args: {args}")
    logger.debug(f"Input file: {input_file}, Output file: {output_file}, Error file: {error_file}")
    try:
        message = {
            'type': 'generate_command',
            'command': command,
            'args': args,
            'context_id': 'hamsh',
            'force_regenerate': force_regenerate
        }
        command_path = await communicate_with_kernel(message)
        logger.debug(f"Received command path from kernel: {command_path}")
        
        if not os.path.exists(command_path):
            logger.warning(f"Command file does not exist: {command_path}. Attempting to regenerate.")
            message['force_regenerate'] = True
            command_path = await communicate_with_kernel(message)
            logger.debug(f"Regenerated command path: {command_path}")
        
        if not os.path.exists(command_path):
            raise FileNotFoundError(f"Command file does not exist: {command_path}")
        
        cmd = [command_path] + args
        logger.debug(f"Full command: {cmd}")
        
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=asyncio.subprocess.PIPE if input_file else None,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=os.environ
        )
        logger.debug(f"Started subprocess with PID: {process.pid}")
        
        # Set up tasks for handling I/O
        tasks = []
        if input_file:
            tasks.append(asyncio.create_task(stream_input(input_file, process.stdin)))
        tasks.append(asyncio.create_task(stream_output(process.stdout, sys.stdout if not output_file else open(output_file, 'wb'))))
        tasks.append(asyncio.create_task(stream_output(process.stderr, sys.stderr if not error_file else open(error_file, 'wb'))))
        
        # Wait for the process to complete and all I/O to finish
        await asyncio.gather(process.wait(), *tasks)
        
        if process.returncode == 2:
            logger.info(f"Command '{command}' exited with status 2. Attempting to extend the script.")
            await extend_script(command, args)
            # Retry the command after extension
            return await execute_command(command, args, input_file, output_file, error_file, False)
        
        logger.debug(f"Command execution completed with return code: {process.returncode}")
        return process.returncode
    except Exception as e:
        logger.error(f"An error occurred during command execution: {str(e)}")
        print(f"An error occurred: {str(e)}", file=sys.stderr)
        return 1

async def stream_input(input_file, stdin):
    with open(input_file, 'rb') as f:
        while True:
            chunk = f.read(4096)
            if not chunk:
                break
            await stdin.write(chunk)
    stdin.close()

async def run_pipeline(commands, force_regenerate=False):
    logger.debug(f"Running pipeline with commands: {commands}")
    for i, cmd in enumerate(commands):
        logger.debug(f"Executing command {i+1}/{len(commands)}: {cmd}")
        command, *args = cmd
        input_file = output_file = error_file = None
        
        if '<' in args:
            input_index = args.index('<')
            input_file = args[input_index + 1]
            args = args[:input_index] + args[input_index + 2:]
            logger.debug(f"Input redirection detected: {input_file}")
        
        if '>' in args:
            output_index = args.index('>')
            output_file = args[output_index + 1]
            args = args[:output_index] + args[output_index + 2:]
            logger.debug(f"Output redirection detected: {output_file}")
        
        if '2>' in args:
            error_index = args.index('2>')
            error_file = args[error_index + 1]
            args = args[:error_index] + args[error_index + 2:]
            logger.debug(f"Error redirection detected: {error_file}")
        
        exit_code = await execute_command(command, args, input_file, output_file, error_file, force_regenerate)
        logger.debug(f"Command '{command}' completed with exit code: {exit_code}")
        
        if exit_code != 0:
            logger.warning(f"Command '{command}' failed with exit code {exit_code}")
            print(f"Command '{command}' failed with exit code {exit_code}", file=sys.stderr)
            break

def parse_command(command_string):
    logger.debug(f"Parsing command string: {command_string}")
    commands = [shlex.split(cmd.strip()) for cmd in command_string.split('|')]
    logger.debug(f"Parsed commands: {commands}")
    return commands

def command_completer(text, state):
    logger.debug(f"Command completion requested for: {text}, state: {state}")
    buffer = readline.get_line_buffer()
    line = shlex.split(buffer)
    
    if not line or len(line) == 1 and not buffer.endswith(' '):
        # Complete commands
        options = [cmd for cmd in os.listdir(ABIN_PATH) if cmd.startswith(text)]
        if state < len(options):
            logger.debug(f"Returning command completion: {options[state]}")
            return options[state]
    elif len(line) > 1 or (len(line) == 1 and buffer.endswith(' ')):
        # Complete filesystem paths
        completion = readline.get_completer()(text, state)
        logger.debug(f"Returning filesystem completion: {completion}")
        return completion
    
    logger.debug("No completion found")
    return None

async def main():
    logger.info("Starting Hamsh - The Hamnix Shell")
    print("Welcome to Hamsh - The Hamnix Shell!")
    print("Type 'exit' to quit. Press Tab for completion.")
    print("Start a command with '!' to force regeneration.")
    
    readline.set_completer(command_completer)
    readline.set_completer_delims(' \t\n')
    readline.parse_and_bind("tab: complete")
    
    while True:
        try:
            prompt = f"{os.getcwd()}$ "
            user_input = input(prompt).strip()
            logger.debug(f"User input: {user_input}")
        except EOFError:
            logger.info("EOFError caught, exiting")
            print("\nGoodbye!")
            break
        
        if user_input.lower() == 'exit':
            logger.info("Exit command received, exiting")
            print("Goodbye!")
            break
        elif user_input == "":
            logger.debug("Empty input, continuing")
            continue
        elif user_input:
            readline.add_history(user_input)
            force_regenerate = False
            if user_input.startswith('!'):
                force_regenerate = True
                user_input = user_input[1:]
                logger.debug("Force regenerate flag set")
            
            try:
                commands = parse_command(user_input)
                logger.debug(f"Parsed commands: {commands}")
                await run_pipeline(commands, force_regenerate)
            except Exception as e:
                logger.error(f"An error occurred: {str(e)}")
                print(f"An error occurred: {str(e)}", file=sys.stderr)

if __name__ == "__main__":
    asyncio.run(main())
