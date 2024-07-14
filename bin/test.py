import tkinter as tk
from tkinter import messagebox

class Game(tk.Tk):
    def __init__(self, width=600, height=400):
        super().__init__()
        self.title("Snake Game")
        self.geometry("300x200")
        self.canvas = tk.Canvas(self, width=width, height=height)
        self.canvas.pack()
        
        # Initialize snake and food positions
        self.snake = None
        self.food = None

    def create_food(self):
        x = random.randint(0, (self.width - self.block_size) // self.block_size) * self.block_size
        y = random.randint(0, (self.height - self.block_size) // self.block_size) * self.block_size
        return x, y

    def update(self):
        if not self.running:
            return
        self.snake.move()
        head_x, head_y = self.snake.coords[0]
        food_x, food_y = self.food.coords
        if head_x == food_x and head_y == food_y:
            self.score += 1
            self.food.move()

    def is_collision(self, snake, food):
        x1, y1 = snake[0]
        x2, y2 = food
        return (x1 - x2) ** 2 + (y1 - y2) ** 2 < self.block_size ** 2

# Main game loop
game = Game()
while True:
    if not game.running():
        break
    # Update the game state and redraw the canvas
    game.update()
