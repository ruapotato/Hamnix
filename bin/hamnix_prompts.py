def get_command_prompt(command, args):
    return f"""
Create a Python script that mimics the '{command}' Unix command.

Requirements:
- Name: {command}
- Arguments: {args}
- Use standard library modules only
- Handle errors gracefully, writing to stderr
- Design for use in a bash environment (support piping, redirection)
- Use argparse for all options
- Exit with appropriate status codes: 0 for success, non-zero for errors, excluding 2 as it is used by argparse for unknown options

Provide only the Python code, no explanations.
"""

def get_extend_command_prompt(command, args, existing_code):
    return f"""
Extend the existing Python script for the '{command}' command to handle new arguments: {args}

Existing code:
{existing_code}

Requirements:
- Maintain existing functionality
- Add support for new arguments: {args}
- Use argparse for all options (new and existing)
- Handle errors gracefully, writing to stderr
- Design for use in a bash environment (support piping, redirection)
- Exit with appropriate status codes: 0 for success, non-zero for errors, excluding 2 as it is used by argparse for unknown options

Provide only the complete, updated Python code, no explanations.
"""
