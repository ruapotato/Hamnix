import os
import shlex
import re
import torch
import readline
from transformers import AutoTokenizer, AutoModelForCausalLM

# Initialize the model and tokenizer
tokenizer = AutoTokenizer.from_pretrained("deepseek-ai/deepseek-coder-6.7b-instruct", trust_remote_code=True)
model = AutoModelForCausalLM.from_pretrained("deepseek-ai/deepseek-coder-6.7b-instruct", trust_remote_code=True, torch_dtype=torch.bfloat16).cuda()

# Set pad_token_id to eos_token_id
model.config.pad_token_id = model.config.eos_token_id

# Command cache
command_cache = {}

def extract_python_code(text):
    # Look for Python code block
    match = re.search(r'```python\n(.*?)```', text, re.DOTALL)
    if match:
        return match.group(1).strip()
    
    # If no Python block found, try to extract any code-like block
    match = re.search(r'def .*?:.*?(?=\n\n|\Z)', text, re.DOTALL)
    if match:
        return match.group(0)
    
    # If still no match, return the original text
    return text

def generate_function(command, args, max_attempts=3, force_regenerate=False):
    # Create a function name based on the command and options
    options = [arg.lstrip('-') for arg in args if arg.startswith('-')]
    function_name = f"{command}_{'_'.join(options)}" if options else command
    function_name = function_name.replace('-', '_')  # Replace hyphens with underscores for valid Python function names

    # Check if the function is already in cache and not forcing regeneration
    if not force_regenerate and function_name in command_cache:
        return command_cache[function_name]

    prompt = f"""
Task: Implement a Python function that mimics the behavior of the '{command}' command in a Unix-like terminal.

Function name: {function_name}

Description: The function should perform the operation of the {command} command with the following arguments and options: {args}.

Requirements:
1. Use only Python standard library modules.
2. The function MUST accept arbitrary arguments using *args for any additional arguments.
3. If a file path is needed, it should be the first argument in *args.
4. Handle the following arguments and options: {args}
5. Return the output as a string, similar to how it would appear in a terminal.
6. Handle potential errors and exceptions gracefully.

Example usage:
result = {function_name}()  # If no additional args
result = {function_name}('path/to/file', 'additional_arg')  # If file path and additional args are needed

Function template:
def {function_name}(*args):
    # Your implementation here
    # If a file path is needed, access it with args[0]
    # Make sure to handle *args even if not explicitly used
    pass

Additional notes:
- Assume the current working directory is accessible via os.getcwd().
- If file system operations are needed, use the 'os' and 'os.path' modules.

Please provide only the Python function implementation without any additional explanation.
    """
    
    messages = [
        {'role': 'user', 'content': prompt}
    ]

    for attempt in range(max_attempts):
        try:
            inputs = tokenizer.apply_chat_template(messages, add_generation_prompt=True, return_tensors="pt").to(model.device)
            
            # Create attention mask
            attention_mask = torch.ones_like(inputs)
            attention_mask[inputs == tokenizer.pad_token_id] = 0
            
            # Generate tokens in batches
            generated = inputs[0].tolist()
            with torch.no_grad():
                for i in range(0, 512, 20):  # Generate 20 tokens at a time
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
                    
                    # Update progress every 20 tokens
                    if i % 20 == 0:
                        decoded = tokenizer.decode(generated[len(inputs[0]):], skip_special_tokens=True)
                        last_line = decoded.split('\n')[-1]
                        print(f"\r\033[K{last_line[:50]}{'...' if len(last_line) > 50 else ''}", end='', flush=True)
                    
                    if tokenizer.eos_token_id in new_tokens:
                        break

            print("\r\033[KGeneration complete.")  # Clear the last line
            
            generated_text = tokenizer.decode(generated[len(inputs[0]):], skip_special_tokens=True)
            function_code = extract_python_code(generated_text)
            
            # Validate the generated code
            compile(function_code, '<string>', 'exec')  # This will raise a SyntaxError if the code is invalid
            
            # Cache the generated function
            command_cache[function_name] = function_code
            
            return function_code
        except Exception as e:
            print(f"\r\033[KAttempt {attempt + 1} failed: {str(e)}")
            if attempt == max_attempts - 1:
                print("Max attempts reached. Falling back to basic implementation.")
                return f"def {function_name}(*args):\n    return 'Command not implemented: {command}'"

def execute_command(command, args, force_regenerate=False):
    try:
        # Generate the function
        function_code = generate_function(command, args, force_regenerate=force_regenerate)
        
        # Execute the generated function
        exec(function_code, globals())
        
        # Determine which function to call
        options = [arg.lstrip('-') for arg in args if arg.startswith('-')]
        function_name = f"{command}_{'_'.join(options)}" if options else command
        function_name = function_name.replace('-', '_')  # Replace hyphens with underscores for valid Python function names
        
        # Call the function with all arguments
        result = eval(f"{function_name}(*{repr(args)})")
        print(result)
    except Exception as e:
        print(f"An error occurred: {str(e)}")

def path_completer(text, state):
    """Complete paths for filesystem navigation"""
    if '~' in text:
        text = os.path.expanduser(text)
    if not text.startswith(('/', '~')):
        text = os.path.join(os.getcwd(), text)
    dir_name = os.path.dirname(text)
    try:
        dir_list = os.listdir(dir_name)
    except OSError:
        return None
    matches = [os.path.join(dir_name, f) for f in dir_list if f.startswith(os.path.basename(text))]
    if state < len(matches):
        return matches[state]
    else:
        return None

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
        return path_completer(text, state)
    
    return None

def main():
    print("Welcome to the Advanced LLM-powered terminal!")
    print("Type 'exit' to quit. Press Tab for completion.")
    print("Start a command with '!' to force regeneration.")
    
    readline.set_completer(command_completer)
    readline.set_completer_delims(' \t\n')
    readline.parse_and_bind("tab: complete")
    
    while True:
        try:
            user_input = input("$ ").strip()
        except EOFError:
            print("\nGoodbye!")
            break
        
        if user_input.lower() == 'exit':
            print("Goodbye!")
            break
        elif user_input == "":
            if readline.get_current_history_length() == 0 or \
               readline.get_history_item(readline.get_current_history_length()) != "":
                readline.add_history("")
            continue
        elif user_input:
            readline.add_history(user_input)
            # Check if the command starts with '!' for forced regeneration
            force_regenerate = user_input.startswith('!')
            if force_regenerate:
                user_input = user_input[1:]  # Remove the '!' from the command
            
            # Parse the input into command and arguments
            parts = shlex.split(user_input)
            command = parts[0]
            args = parts[1:]
            
            execute_command(command, args, force_regenerate=force_regenerate)

if __name__ == "__main__":
    main()
