import math
import os

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))  # the project root

width = 1024
height = 1024
maxval = 255

header = f"P3\n{width} {height}\n{maxval}\n"
data = []

center_x = width // 2
center_y = height // 2
radius = 400

# Gradient background
for y in range(height):
    row = []
    for x in range(width):
        dx = x - center_x
        dy = y - center_y
        dist = math.sqrt(dx*dx + dy*dy)
        
        # Background: Dark Grey Blue
        r, g, b = 20, 30, 40

        # Circle: Electric Blue
        if dist < radius:
            factor = (dist / radius)
            # rim lighting effect
            if factor > 0.9:
                r, g, b = 100, 200, 255
            else:
                # Gradient inside
                b = int(200 + 55 * (1.0 - factor))
                g = int(100 + 50 * (1.0 - factor))
                r = int(0 + 50 * (1.0 - factor))
                
        # "D" shape roughly
        if dist < radius * 0.6:
             if x > center_x - 100 and x < center_x + 50:
                 r, g, b = 255, 255, 255
             if x >= center_x + 50 and dist < radius * 0.6 and x < center_x + radius * 0.4:
                 r, g, b = 255, 255, 255

        row.append(f"{r} {g} {b}")
    data.append(" ".join(row))

with open("temp_icon.ppm", "w") as f:
    f.write(header + "\n".join(data))
