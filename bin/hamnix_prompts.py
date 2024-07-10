def get_command_prompt(command, args):
    return f"""
Create a Python script that mimics the '{command}' Unix command.

Requirements:
- Name: {command}
- Arguments: {args}
- Use standard library modules only
- Handle errors gracefully, writing to stderr
- Exit with appropriate status codes (0 for success, non-zero for errors)
- Design for use in a bash environment (support piping, redirection)
- Include a --help option

Provide only the Python code, no explanations.
"""
