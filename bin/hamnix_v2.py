import os
import sys
import shlex
import re
import torch
import readline
import asyncio
import io
from transformers import AutoTokenizer, AutoModelForCausalLM

# Initialize the model and tokenizer
tokenizer = AutoTokenizer.from_pretrained("deepseek-ai/deepseek-coder-6.7b-instruct", trust_remote_code=True)
model = AutoModelForCausalLM.from_pretrained("deepseek-ai/deepseek-coder-6.7b-instruct", trust_remote_code=True, torch_dtype=torch.bfloat16).cuda()

# Set pad_token_id to eos_token_id
model.config.pad_token_id = model.config.eos_token_id

# Command cache
command_cache = {}

# Environment variables
env_vars = os.environ.copy()

# Job control
jobs = []

def extract_python_code(text):
    match = re.search(r'```python\n(.*?)```', text, re.DOTALL)
    if match:
        return match.group(1).strip()
    match = re.search(r'def .*?:.*?(?=\n\n|\Z)', text, re.DOTALL)
    if match:
        return match.group(0)
    return text

def preprocess_generated_code(code, function_name):
    print(f"--- Original generated code ---\n{code}\n--- End of original code ---")
    
    # Remove any leading or trailing whitespace
    code = code.strip()
    
    # Split the code into lines
    lines = code.split('\n')
    
    # Remove import statements and empty lines
    lines = [line for line in lines if not line.strip().startswith('import') and line.strip()]
    
    # Ensure the function definition is correct
    if not lines[0].startswith(f"def {function_name}("):
        lines[0] = f"def {function_name}(*args, stdin=sys.stdin, stdout=sys.stdout, stderr=sys.stderr, env=os.environ):"
    
    # Remove any duplicate function definitions
    processed_lines = ["    "  + lines[0]]
    for line in lines[1:]:
        if not line.strip().startswith('def '):
            processed_lines.append("    " + line)
    
    processed_code = '\n'.join(processed_lines)
    
    print(f"--- Processed code ---\n{processed_code}\n--- End of processed code ---")
    return processed_code

async def generate_function(command, args, max_attempts=3, force_regenerate=False):
    options = [arg.lstrip('-') for arg in args if arg.startswith('-')]
    function_name = f"{command}_{'_'.join(options)}" if options else command
    function_name = function_name.replace('-', '_')

    if not force_regenerate and function_name in command_cache:
        return command_cache[function_name]

    prompt = f"""
Task: Implement a Python function that mimics the behavior of the '{command}' command in a Unix-like terminal.

Function name: {function_name}

Description: The function should perform the operation of the {command} command with the following arguments and options: {args}.

Requirements:
1. Use only Python standard library modules.
2. The function MUST accept the following parameters:
   - *args: for command arguments
   - stdin: a file-like object for standard input (default to sys.stdin)
   - stdout: a file-like object for standard output (default to sys.stdout)
   - stderr: a file-like object for standard error (default to sys.stderr)
   - env: a dictionary of environment variables
3. If a file path is needed, it should be the first argument in *args.
4. Handle the following arguments and options: {args}
5. Write output to stdout and errors to stderr.
6. Return 0 for success, non-zero for errors.
7. Handle potential errors and exceptions gracefully.
8. Support input/output redirection and piping.

Example usage:
result = {function_name}(*args, stdin=input_stream, stdout=output_stream, stderr=error_stream, env=environment)

Function template:
def {function_name}(*args, stdin=sys.stdin, stdout=sys.stdout, stderr=sys.stderr, env=os.environ):
    try:
        # Your implementation here
        # Use stdin.read() to get piped input
        # Write to stdout and stderr as needed
        # Access environment variables with env.get('VAR_NAME')
    except Exception as e:
        print(f"Error: {{str(e)}}", file=stderr)
        return 1
    return 0

Additional notes:
- Assume the current working directory is accessible via os.getcwd().
- If file system operations are needed, use the 'os' and 'os.path' modules.
- Use 'env.get()' to access environment variables.

Please provide only the Python function implementation without any additional explanation.
    """
    
    messages = [
        {'role': 'user', 'content': prompt}
    ]

    for attempt in range(max_attempts):
        try:
            inputs = tokenizer.apply_chat_template(messages, add_generation_prompt=True, return_tensors="pt").to(model.device)
            attention_mask = torch.ones_like(inputs)
            attention_mask[inputs == tokenizer.pad_token_id] = 0
            
            generated = inputs[0].tolist()
            with torch.no_grad():
                for i in range(0, 512, 20):
                    outputs = model.generate(
                        torch.tensor([generated]).to(model.device),
                        max_new_tokens=20,
                        do_sample=True,
                        top_k=50,
                        top_p=0.95,
                        num_return_sequences=1,
                        pad_token_id=tokenizer.pad_token_id,
                        eos_token_id=tokenizer.eos_token_id,
                    )
                    new_tokens = outputs[0][len(generated):]
                    generated.extend(new_tokens.tolist())
                    
                    if i % 20 == 0:
                        decoded = tokenizer.decode(generated[len(inputs[0]):], skip_special_tokens=True)
                        last_line = decoded.split('\n')[-1]
                        print(f"\r\033[K{last_line[:50]}{'...' if len(last_line) > 50 else ''}", end='', flush=True)
                    
                    if tokenizer.eos_token_id in new_tokens:
                        break

            print("\r\033[KGeneration complete.")
            
            generated_text = tokenizer.decode(generated[len(inputs[0]):], skip_special_tokens=True)
            function_code = extract_python_code(generated_text)
            
            if not function_code:
                raise ValueError("No valid Python code was generated.")
            
            # Preprocess the generated code
            function_code = preprocess_generated_code(function_code, function_name)
            
            # Indent the function code
            indented_function_code = '\n'.join('    ' + line for line in function_code.split('\n'))
            
            # Wrap the function with a timeout mechanism
            wrapped_function_code = f"""
import signal

def {function_name}_with_timeout(*args, stdin=sys.stdin, stdout=sys.stdout, stderr=sys.stderr, env=os.environ):
    def timeout_handler(signum, frame):
        raise TimeoutError("Function execution timed out")

    signal.signal(signal.SIGALRM, timeout_handler)
    signal.alarm(30)  # Set a 30-second timeout

    try:
{indented_function_code}
        return {function_name}(*args, stdin=stdin, stdout=stdout, stderr=stderr, env=env)
    except TimeoutError as e:
        print(f"Error: {{str(e)}}", file=stderr)
        return 1
    finally:
        signal.alarm(0)  # Cancel the alarm
"""
            print(f"--- Final wrapped code ---\n{wrapped_function_code}\n--- End of final wrapped code ---")
            
            # Compile and execute the wrapped function
            exec(wrapped_function_code, globals())
            
            command_cache[function_name] = wrapped_function_code
            
            return wrapped_function_code
        except Exception as e:
            print(f"\r\033[KAttempt {attempt + 1} failed: {str(e)}")
    
    print("Max attempts reached. Falling back to basic implementation.")
    basic_implementation = f"""
def {function_name}_with_timeout(*args, stdin=sys.stdin, stdout=sys.stdout, stderr=sys.stderr, env=os.environ):
    print('Command not implemented: {command}', file=stderr)
    return 1
"""
    exec(basic_implementation, globals())
    return basic_implementation

async def execute_command(command, args, stdin=sys.stdin, stdout=sys.stdout, stderr=sys.stderr, env=None, force_regenerate=False):
    try:
        function_code = await generate_function(command, args, force_regenerate=force_regenerate)
        
        exec(function_code, globals())
        
        options = [arg.lstrip('-') for arg in args if arg.startswith('-')]
        function_name = f"{command}_{'_'.join(options)}" if options else command
        function_name = function_name.replace('-', '_')
        
        result = eval(f"{function_name}_with_timeout(*{repr(args)}, stdin=stdin, stdout=stdout, stderr=stderr, env=env or os.environ)")
        return result
    except Exception as e:
        print(f"An error occurred: {str(e)}", file=stderr)
        return 1

async def run_pipeline(commands, input_file=None, output_file=None, background=False, force_regenerate=False):
    stdin = open(input_file, 'r') if input_file else sys.stdin
    stdout = open(output_file, 'w') if output_file else sys.stdout
    
    try:
        for i, cmd in enumerate(commands):
            if i > 0:
                stdin = stdout
                stdout = sys.stdout if i == len(commands) - 1 and not output_file else io.StringIO()
            
            command, *args = cmd
            exit_code = await execute_command(command, args, stdin=stdin, stdout=stdout, stderr=sys.stderr, env=env_vars, force_regenerate=force_regenerate)
            
            if exit_code != 0:
                print(f"Command '{command}' failed with exit code {exit_code}", file=sys.stderr)
                break
            
            if isinstance(stdin, io.StringIO):
                stdin.close()
            
            if isinstance(stdout, io.StringIO):
                stdout.seek(0)
    finally:
        # Ensure all file handles are properly closed
        if input_file and stdin != sys.stdin:
            stdin.close()
        if output_file and stdout != sys.stdout:
            stdout.close()

    return exit_code

def parse_command(command_string):
    parts = shlex.split(command_string)
    commands = []
    current_command = []
    input_file = output_file = None
    background = False

    for part in parts:
        if part == '|':
            if current_command:
                commands.append(current_command)
                current_command = []
        elif part == '<':
            input_file = parts[parts.index(part) + 1]
        elif part == '>':
            output_file = parts[parts.index(part) + 1]
        elif part == '&':
            background = True
        else:
            current_command.append(part)

    if current_command:
        commands.append(current_command)

    return commands, input_file, output_file, background

def command_completer(text, state):
    """Complete commands and filesystem paths"""
    buffer = readline.get_line_buffer()
    line = shlex.split(buffer)
    
    if not line or len(line) == 1 and not buffer.endswith(' '):
        # Complete commands
        options = [cmd for cmd in command_cache.keys() if cmd.startswith(text)]
        if state < len(options):
            return options[state]
    elif len(line) > 1 or (len(line) == 1 and buffer.endswith(' ')):
        # Complete filesystem paths
        return readline.get_completer()(text, state)
    
    return None

async def run_in_background(command_string):
    commands, input_file, output_file, _ = parse_command(command_string)
    job_id = len(jobs) + 1
    job = asyncio.create_task(run_pipeline(commands, input_file, output_file))
    jobs.append((job_id, job, command_string))
    print(f"[{job_id}] {command_string} &")
    return job_id

async def main():
    print("Welcome to the Enhanced LLM-powered terminal!")
    print("Type 'exit' to quit. Press Tab for completion.")
    print("Start a command with '!' to force regeneration.")
    
    readline.set_completer(command_completer)
    readline.set_completer_delims(' \t\n')
    readline.parse_and_bind("tab: complete")
    
    while True:
        try:
            user_input = input(f"{os.getcwd()}$ ").strip()
        except EOFError:
            print("\nGoodbye!")
            break
        
        if user_input.lower() == 'exit':
            print("Goodbye!")
            break
        elif user_input == "":
            continue
        elif user_input == "jobs":
            for job_id, job, command in jobs:
                status = "Running" if not job.done() else "Done"
                print(f"[{job_id}] {status}\t{command}")
        elif user_input.startswith("fg "):
            try:
                job_id = int(user_input.split()[1])
                job = next((j for j in jobs if j[0] == job_id), None)
                if job:
                    await job[1]
                    print(f"Job {job_id} completed")
                else:
                    print(f"No such job: {job_id}")
            except ValueError:
                print("Invalid job ID")
        elif user_input:
            readline.add_history(user_input)
            force_regenerate = user_input.startswith('!')
            if force_regenerate:
                user_input = user_input[1:]
            
            try:
                commands, input_file, output_file, background = parse_command(user_input)
                
                if background:
                    await run_in_background(user_input)
                else:
                    await run_pipeline(commands, input_file, output_file, force_regenerate=force_regenerate)
            except Exception as e:
                print(f"An error occurred: {str(e)}", file=sys.stderr)
if __name__ == "__main__":
    asyncio.run(main())
