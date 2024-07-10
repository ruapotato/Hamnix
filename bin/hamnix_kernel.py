#!/usr/bin/env python3

import os
import sys
import re
import torch
import asyncio
import json
import logging
import stat
from transformers import AutoTokenizer, AutoModelForCausalLM

# Set up logging
logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s - %(message)s')

class HamnixKernel:
    def __init__(self):
        logging.debug("Initializing HamnixKernel")
        self.tokenizer = AutoTokenizer.from_pretrained("deepseek-ai/deepseek-coder-6.7b-instruct", trust_remote_code=True)
        logging.debug("Tokenizer loaded")
        self.model = AutoModelForCausalLM.from_pretrained("deepseek-ai/deepseek-coder-6.7b-instruct", trust_remote_code=True, torch_dtype=torch.bfloat16).cuda()
        logging.debug("Model loaded and moved to CUDA")
        self.model.config.pad_token_id = self.model.config.eos_token_id
        self.contexts = {'hamsh': []}  # Initialize with 'hamsh' context
        self.queue = asyncio.Queue()
        self.lock = asyncio.Lock()
        self.abin_path = os.path.abspath('./abin')
        self.shared_env = os.environ.copy()
        os.makedirs(self.abin_path, exist_ok=True)
        logging.debug(f"Abin directory: {self.abin_path}")
        logging.debug("HamnixKernel initialization complete")

    async def process_queue(self):
        logging.debug("Starting to process queue")
        while True:
            logging.debug("Waiting for a task")
            task = await self.queue.get()
            logging.debug(f"Got task: {task}")
            result = await self.execute_task(task)
            self.queue.task_done()
            logging.debug(f"Task completed with result: {result}")
            return result

    async def execute_task(self, task):
        logging.debug(f"Executing task: {task}")
        async with self.lock:
            if task['type'] == 'generate_command':
                return await self.generate_command(task['command'], task['args'], task['context_id'], task.get('force_regenerate', False))
            elif task['type'] == 'switch_context':
                return self.switch_context(task['context_id'])
            elif task['type'] == 'get_prompt':
                return self.get_prompt(task['context_id'])
            elif task['type'] == 'update_env':
                return self.update_env(task['env_updates'])
            elif task['type'] == 'get_env':
                return self.get_env()
            else:
                logging.warning(f"Unknown task type: {task['type']}")
                return json.dumps({"error": f"Unknown task type: {task['type']}"})

    def switch_context(self, context_id):
        logging.debug(f"Switching to context: {context_id}")
        if context_id not in self.contexts:
            self.contexts[context_id] = []
        return json.dumps({"result": f"Switched to context {context_id}"})

    def get_prompt(self, context_id):
        logging.debug(f"Getting prompt for context: {context_id}")
        if context_id not in self.contexts:
            logging.warning(f"Context not found: {context_id}")
            return json.dumps({"error": "Context not found"})
        return json.dumps({"result": "\n".join(self.contexts[context_id])})

    def update_env(self, env_updates):
        logging.debug(f"Updating shared environment: {env_updates}")
        self.shared_env.update(env_updates)
        return json.dumps({"result": "Environment updated"})

    def get_env(self):
        logging.debug("Getting shared environment")
        return json.dumps({"result": self.shared_env})

    async def generate_command(self, command, args, context_id, force_regenerate=False):
        logging.debug(f"Generating command: {command} with args: {args} for context: {context_id}")
        command_path = os.path.join(self.abin_path, command)
        
        if not force_regenerate and os.path.exists(command_path):
            logging.debug(f"Command already exists and force_regenerate is False, returning existing command: {command_path}")
            return json.dumps({"result": command_path})

        if context_id not in self.contexts:
            self.contexts[context_id] = []
        prompt = self.get_command_prompt(command, args)
        self.contexts[context_id].append(prompt)

        messages = [{'role': 'user', 'content': prompt}]

        try:
            logging.debug("Generating response from model")
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
            logging.debug("Response generated from model")
            script_code = self.extract_python_code(generated_text)
            
            if not script_code:
                raise ValueError("No valid Python code was generated.")
            
            if not script_code.startswith("#!/usr/bin/python3"):
                script_code = "#!/usr/bin/python3\n" + script_code
            
            logging.debug("Command generation complete")
            
            # Write the script to file
            with open(command_path, 'w') as f:
                f.write(script_code)
            logging.debug(f"Wrote script to file: {command_path}")
            
            # Make the script executable
            os.chmod(command_path, os.stat(command_path).st_mode | stat.S_IEXEC)
            logging.debug(f"Made script executable: {command_path}")
            
            return json.dumps({"result": command_path})
        except Exception as e:
            logging.error(f"Error generating command: {str(e)}")
            return json.dumps({"error": f"Error generating command: {str(e)}"})

    def get_command_prompt(self, command, args):
        logging.debug(f"Getting command prompt for: {command} with args: {args}")
        return f"""
Task: Implement a Python script that mimics the behavior of the '{command}' command in a Unix-like terminal.

Script name: {command}

Description: The script should perform the operation of the {command} command with the following arguments and options: {args}.

Requirements:
1. Use only Python standard library modules.
2. Only read from stdin if it's necessary for the command's functionality.
3. Only write to stdout for the command's actual output.
4. If a file path is needed, it should be the first argument in sys.argv[1:].
5. Handle the following arguments and options: {args}
6. Support input/output redirection and piping only when necessary for the command.
7. Exit with 0 for success, non-zero for errors.
8. Handle potential errors and exceptions gracefully.
9. If the command changes the current working directory, update os.environ['PWD'] accordingly.
10. For directory changes, use os.chdir() and update os.environ['PWD'].
11. Always update the shared environment file before exiting.

Example usage:
$ {command} {' '.join(args)}

Script template:
#!/usr/bin/python3
import sys
import os
import json

def update_shared_env():
    with open('/tmp/hamnix_env_update.json', 'w') as f:
        json.dump(dict(os.environ), f)

def main():
    try:
        # Your implementation here
        # Only use sys.stdin.read() if absolutely necessary for the command
        # Only write to sys.stdout for the command's actual output
        # Access environment variables with os.environ.get('VAR_NAME')
        # If changing directory, use:
        #     os.chdir(new_dir)
        #     os.environ['PWD'] = os.getcwd()
        
        # Your command-specific code here
        
    except Exception as e:
        print(f"Error: {{str(e)}}", file=sys.stderr)
        update_shared_env()
        return 1
    
    update_shared_env()
    return 0

if __name__ == "__main__":
    sys.exit(main())

Additional notes:
- Assume the current working directory is accessible via os.getcwd().
- If file system operations are needed, use the 'os' and 'os.path' modules.
- Do not add unnecessary stdin/stdout handling.
- Always call update_shared_env() before returning from main().

Please provide only the Python script implementation without any additional explanation.
"""

    @staticmethod
    def extract_python_code(text):
        logging.debug("Extracting Python code from generated text")
        match = re.search(r'```python\n(.*?)```', text, re.DOTALL)
        if match:
            return match.group(1).strip()
        match = re.search(r'def .*?:.*?(?=\n\n|\Z)', text, re.DOTALL)
        if match:
            return match.group(0)
        return text

kernel = HamnixKernel()

async def handle_client(reader, writer):
    logging.info("New client connected")
    try:
        while True:
            try:
                data = await reader.readuntil(b'\n')  # Read until newline
                if not data:
                    logging.info("Client closed the connection")
                    break
                message = json.loads(data.decode().strip())
                logging.debug(f"Received message: {message}")
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
                
                logging.debug(f"Sent response: {result}")
            except asyncio.IncompleteReadError:
                logging.warning("Incomplete read from client, connection might have been closed")
                break
            except json.JSONDecodeError as e:
                logging.error(f"Invalid JSON received: {e}")
                error_response = json.dumps({"error": "Invalid JSON in request"}) + '\n'
                writer.write(error_response.encode())
                await writer.drain()
            except Exception as e:
                logging.error(f"Error handling client request: {str(e)}")
                error_response = json.dumps({"error": str(e)}) + '\n'
                writer.write(error_response.encode())
                await writer.drain()
    except ConnectionResetError:
        logging.warning("Connection reset by client")
    except Exception as e:
        logging.error(f"Unexpected error in handle_client: {str(e)}")
    finally:
        logging.info("Client disconnected")
        writer.close()
        await writer.wait_closed()

async def start_server():
    logging.info("Starting server")
    server = await asyncio.start_unix_server(handle_client, '/tmp/hamnix_kernel.sock')
    logging.info("Server started, listening on /tmp/hamnix_kernel.sock")
    async with server:
        await server.serve_forever()

if __name__ == "__main__":
    logging.info("Starting Hamnix Kernel")
    asyncio.run(start_server())
