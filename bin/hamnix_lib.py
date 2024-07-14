import os
import asyncio
import json
from hamnix_logger import setup_logger

logger = setup_logger(__name__)

# Environment variables
ABIN_PATH = os.path.abspath('./abin')
os.makedirs(ABIN_PATH, exist_ok=True)
logger.debug(f"Abin directory: {ABIN_PATH}")

async def communicate_with_kernel(message, timeout=30, retries=3):
    logger.debug(f"Communicating with kernel: {message}")
    for attempt in range(retries):
        try:
            reader, writer = await asyncio.open_unix_connection('/tmp/hamnix_kernel.sock')
            logger.debug("Connected to kernel socket")
            writer.write(json.dumps(message).encode() + b'\n')  # Add newline to signal end of message
            await writer.drain()
            logger.debug("Sent message to kernel")

            # Read the entire response with a timeout
            data = b''
            try:
                data = await asyncio.wait_for(reader.readuntil(b'\n'), timeout=timeout)
            except asyncio.TimeoutError:
                logger.warning(f"Timeout reached while reading response from kernel")
                if data:
                    logger.warning(f"Partial data received: {data}")
                raise

            logger.debug(f"Received data from kernel: {data}")
            writer.close()
            await writer.wait_closed()
            
            if not data:
                raise Exception("No data received from kernel")
            
            try:
                response = json.loads(data.decode().strip())
            except json.JSONDecodeError as e:
                logger.error(f"Failed to parse JSON response: {e}")
                raise Exception(f"Invalid JSON response from kernel: {data.decode()}")
            
            if "error" in response:
                raise Exception(response["error"])
            return response["result"]
        except (ConnectionResetError, ConnectionRefusedError) as e:
            if attempt < retries - 1:
                logger.warning(f"Connection error (attempt {attempt + 1}/{retries}): {str(e)}. Retrying...")
                await asyncio.sleep(1)  # Wait a bit before retrying
            else:
                logger.error(f"Failed to communicate with kernel after {retries} attempts")
                raise
        except Exception as e:
            logger.error(f"Error communicating with kernel: {str(e)}")
            raise

async def extend_script(command, args):
    logger.debug(f"Extending script for command: {command} with args: {args}")
    message = {
        'type': 'extend_command',
        'command': command,
        'args': args,
        'context_id': 'hamsh'
    }
    return await communicate_with_kernel(message)
