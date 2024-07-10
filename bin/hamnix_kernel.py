#!/usr/bin/env python3

import os
import sys
import re
import torch
import asyncio
import json
import stat
from transformers import AutoTokenizer, AutoModelForCausalLM
from hamnix_logger import setup_logger
from hamnix_prompts import get_command_prompt

logger = setup_logger(__name__)

class HamnixKernel:
    def __init__(self):
        logger.debug("Initializing HamnixKernel")
        self.tokenizer = AutoTokenizer.from_pretrained("deepseek-ai/deepseek-coder-6.7b-instruct", trust_remote_code=True)
        logger.debug("Tokenizer loaded")
        self.model = AutoModelForCausalLM.from_pretrained("deepseek-ai/deepseek-coder-6.7b-instruct", trust_remote_code=True, torch_dtype=torch.bfloat16).cuda()
        logger.debug("Model loaded and moved to CUDA")
        self.model.config.pad_token_id = self.model.config.eos_token_id
        self.contexts = {'hamsh': []}  # Initialize with 'hamsh' context
        self.queue = asyncio.Queue()
        self.lock = asyncio.Lock()
        self.abin_path = os.path.abspath('./abin')
        os.makedirs(self.abin_path, exist_ok=True)
        logger.debug(f"Abin directory: {self.abin_path}")
        logger.debug("HamnixKernel initialization complete")

    async def process_queue(self):
        logger.debug("Starting to process queue")
        while True:
            logger.debug("Waiting for a task")
            task = await self.queue.get()
            logger.debug(f"Got task: {task}")
            result = await self.execute_task(task)
            self.queue.task_done()
            logger.debug(f"Task completed with result: {result}")
            return result

    async def execute_task(self, task):
        logger.debug(f"Executing task: {task}")
        async with self.lock:
            if task['type'] == 'generate_command':
                return await self.generate_command(task['command'], task['args'], task['context_id'], task.get('force_regenerate', False))
            elif task['type'] == 'switch_context':
                return self.switch_context(task['context_id'])
            elif task['type'] == 'get_prompt':
                return self.get_prompt(task['context_id'])
            else:
                logger.warning(f"Unknown task type: {task['type']}")
                return json.dumps({"error": f"Unknown task type: {task['type']}"})

    def switch_context(self, context_id):
        logger.debug(f"Switching to context: {context_id}")
        if context_id not in self.contexts:
            self.contexts[context_id] = []
        return json.dumps({"result": f"Switched to context {context_id}"})

    def get_prompt(self, context_id):
        logger.debug(f"Getting prompt for context: {context_id}")
        if context_id not in self.contexts:
            logger.warning(f"Context not found: {context_id}")
            return json.dumps({"error": "Context not found"})
        return json.dumps({"result": "\n".join(self.contexts[context_id])})

    async def generate_command(self, command, args, context_id, force_regenerate=False):
        logger.debug(f"Generating command: {command} with args: {args} for context: {context_id}")
        command_path = os.path.join(self.abin_path, command)
        
        if not force_regenerate and os.path.exists(command_path):
            logger.debug(f"Command already exists and force_regenerate is False, returning existing command: {command_path}")
            return json.dumps({"result": command_path})

        if context_id not in self.contexts:
            self.contexts[context_id] = []
        prompt = get_command_prompt(command, args)
        self.contexts[context_id].append(prompt)

        messages = [{'role': 'user', 'content': prompt}]

        try:
            logger.debug("Generating response from model")
            inputs = self.tokenizer.apply_chat_template(messages, add_generation_prompt=True, return_tensors="pt").to(self.model.device)
            attention_mask = torch.ones_like(inputs)
            attention_mask[inputs == self.tokenizer.pad_token_id] = 0
            
            generated = inputs[0].tolist()
            with torch.no_grad():
                for i in range(0, 512, 20):
                    outputs = self.model.generate(
                        torch.tensor([generated]).to(self.model.device),
                        max_new_tokens=20,
                        do_sample=True,
                        top_k=50,
                        top_p=0.95,
                        num_return_sequences=1,
                        pad_token_id=self.tokenizer.pad_token_id,
                        eos_token_id=self.tokenizer.eos_token_id,
                    )
                    new_tokens = outputs[0][len(generated):]
                    generated.extend(new_tokens.tolist())
                    
                    if self.tokenizer.eos_token_id in new_tokens:
                        break

            generated_text = self.tokenizer.decode(generated[len(inputs[0]):], skip_special_tokens=True)
            logger.debug("Response generated from model")
            script_code = self.extract_python_code(generated_text)
            
            if not script_code:
                raise ValueError("No valid Python code was generated.")
            
            if not script_code.startswith("#!/usr/bin/env python3"):
                script_code = "#!/usr/bin/env python3\n" + script_code
            
            logger.debug("Command generation complete")
            
            # Write the script to file
            with open(command_path, 'w') as f:
                f.write(script_code)
            logger.debug(f"Wrote script to file: {command_path}")
            
            # Make the script executable
            os.chmod(command_path, os.stat(command_path).st_mode | stat.S_IEXEC)
            logger.debug(f"Made script executable: {command_path}")
            
            return json.dumps({"result": command_path})
        except Exception as e:
            logger.error(f"Error generating command: {str(e)}")
            return json.dumps({"error": f"Error generating command: {str(e)}"})

    @staticmethod
    def extract_python_code(text):
        logger.debug("Extracting Python code from generated text")
        match = re.search(r'```python\n(.*?)```', text, re.DOTALL)
        if match:
            return match.group(1).strip()
        match = re.search(r'#!/usr/bin/env python3.*', text, re.DOTALL)
        if match:
            return match.group(0)
        return text

kernel = HamnixKernel()

async def handle_client(reader, writer):
    logger.info("New client connected")
    try:
        while True:
            try:
                data = await reader.readuntil(b'\n')  # Read until newline
                if not data:
                    logger.info("Client closed the connection")
                    break
                message = json.loads(data.decode().strip())
                logger.debug(f"Received message: {message}")
                await kernel.queue.put(message)
                result = await kernel.process_queue()
                
                # Ensure the result is a valid JSON string
                try:
                    json.loads(result)  # This will raise an exception if result is not valid JSON
                except json.JSONDecodeError:
                    result = json.dumps({"error": "Invalid JSON response from kernel"})
                
                # Send the response with a newline at the end
                writer.write(result.encode() + b'\n')
                await writer.drain()
                
                logger.debug(f"Sent response: {result}")
            except asyncio.IncompleteReadError:
                logger.warning("Incomplete read from client, connection might have been closed")
                break
            except json.JSONDecodeError as e:
                logger.error(f"Invalid JSON received: {e}")
                error_response = json.dumps({"error": "Invalid JSON in request"}) + '\n'
                writer.write(error_response.encode())
                await writer.drain()
            except Exception as e:
                logger.error(f"Error handling client request: {str(e)}")
                error_response = json.dumps({"error": str(e)}) + '\n'
                writer.write(error_response.encode())
                await writer.drain()
    except ConnectionResetError:
        logger.warning("Connection reset by client")
    except Exception as e:
        logger.error(f"Unexpected error in handle_client: {str(e)}")
    finally:
        logger.info("Client disconnected")
        writer.close()
        await writer.wait_closed()

async def start_server():
    logger.info("Starting server")
    server = await asyncio.start_unix_server(handle_client, '/tmp/hamnix_kernel.sock')
    logger.info("Server started, listening on /tmp/hamnix_kernel.sock")
    async with server:
        await server.serve_forever()

if __name__ == "__main__":
    logger.info("Starting Hamnix Kernel")
    asyncio.run(start_server())
