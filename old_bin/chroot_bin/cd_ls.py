#!/usr/bin/python3
import sys
import json
import pyte
import os
import select
import fcntl
import termios
import struct
import pty
import signal
import pwd
import tty
import time
import random

def get_terminal_size():
    h, w, hp, wp = struct.unpack('HHHH',
        fcntl.ioctl(0, termios.TIOCGWINSZ,
        struct.pack('HHHH', 0, 0, 0, 0)))
    return w, h

def write_to_config(config_file, data):
    with open(config_file, 'a') as f:
        json.dump(data, f)
        f.write('\n')

def handle_sigchld(signum, frame):
    os.wait()

def process_input(fd, data, config_file):
    for char in data:
        char_bytes = bytes([char])
        os.write(fd, char_bytes)
        if char == 9:  # Tab character
            write_to_config(config_file, {"type": "input", "content": "\\t"})
        else:
            write_to_config(config_file, {"type": "input", "content": char_bytes.decode('utf-8', errors='replace')})
        time.sleep(0.005)  # Simulate typing speed

def get_shell():
    return '/bin/bash' 

def setup_child_process():
    shell = get_shell()
    os.environ['TERM'] = 'xterm-256color'
    os.environ['SHELL'] = shell
    os.execl(shell, shell)

def set_raw_mode(fd):
    old_settings = termios.tcgetattr(fd)
    tty.setraw(fd)
    return old_settings

def restore_terminal(fd, old_settings):
    termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)

def create_folder_structure():
    commands = [
        "mkdir -p /root/1/2/3/4/5/6/7/8/9/10/11/12/13/14/15/16/17/18/19/20/21/22/23/24/25/26/27/28/29/30/31/32/33/34/35",
        "cd /root",
        "pwd",
        "ls"
    ]
    return commands

def generate_navigation_commands(num_commands=50):
    commands = []
    current_depth = 0
    max_depth = 35

    for _ in range(num_commands):
        action = random.choice(['down', 'up', 'show'])

        if action == 'down' and current_depth < max_depth:
            current_depth += 1
            path = "/".join(str(i) for i in range(1, current_depth + 1))
            commands.extend([
                f"cd /root/{path}",
                "pwd",
                "ls"
            ])
        elif action == 'up' and current_depth > 0:
            current_depth -= 1
            commands.extend([
                "cd ..",
                "pwd",
                "ls"
            ])
        else:  # show current directory
            commands.extend([
                "pwd",
                "ls"
            ])

    return commands

def main():
    config_file = "terminal_log.jsonl"
    columns, lines = get_terminal_size()
    
    screen = pyte.Screen(columns, lines)
    stream = pyte.Stream(screen)
    
    signal.signal(signal.SIGCHLD, handle_sigchld)

    pid, fd = pty.fork()

    if pid == 0:  # Child process
        setup_child_process()
    else:  # Parent process
        old_settings = set_raw_mode(sys.stdin.fileno())
        try:
            commands = create_folder_structure() + generate_navigation_commands()
            for cmd in commands:
                process_input(fd, (cmd + '\n').encode(), config_file)
                while True:
                    rlist, _, _ = select.select([fd], [], [], 0.1)
                    if fd in rlist:
                        try:
                            data = os.read(fd, 1024)
                            if not data:
                                break
                            stream.feed(data.decode('utf-8', errors='replace'))
                            sys.stdout.buffer.write(data)
                            sys.stdout.flush()
                            write_to_config(config_file, {"type": "output", "vt100": data.decode('utf-8', errors='replace')})
                        except OSError:
                            break
                    else:
                        break
            os.close(fd)
        finally:
            restore_terminal(sys.stdin.fileno(), old_settings)

if __name__ == "__main__":
    main()
