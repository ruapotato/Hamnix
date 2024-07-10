#!/usr/bin/env python3

import os
import sys
import subprocess
import asyncio
from hamnix_logger import setup_logger
from hamnix_lib import communicate_with_kernel, ABIN_PATH

logger = setup_logger(__name__)

async def generate_command(command):
    logger.debug(f"Generating command: {command}")
    try:
        message = {
            'type': 'generate_command',
            'command': command,
            'args': [],
            'context_id': 'hamsh',
            'force_regenerate': False
        }
        command_path = await communicate_with_kernel(message)
        logger.debug(f"Generated command path: {command_path}")
        return command_path
    except Exception as e:
        logger.error(f"Error generating command: {str(e)}")
        return None

def setup_bash_session():
    # Prepare the bash session
    bash_rc = f"""
    export PATH="{ABIN_PATH}:$PATH"
    
    command_not_found_handle() {{
        python3 {__file__} generate "$1"
        if [ -x "{ABIN_PATH}/$1" ]; then
            "{ABIN_PATH}/$1" "$@"
        else
            echo "bash: $1: command not found"
            return 127
        fi
    }}
    """
    
    with open('/tmp/hamnix_bashrc', 'w') as f:
        f.write(bash_rc)
    
    logger.debug("Bash session setup complete")

def start_bash_session():
    logger.info("Starting Hamnix bash session")
    os.execle('/bin/bash', 'bash', '--rcfile', '/tmp/hamnix_bashrc', os.environ)

async def main():
    if len(sys.argv) > 1 and sys.argv[1] == 'generate':
        if len(sys.argv) > 2:
            await generate_command(sys.argv[2])
        else:
            logger.error("No command specified for generation")
        return

    setup_bash_session()
    start_bash_session()

if __name__ == "__main__":
    asyncio.run(main())
