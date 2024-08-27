import os

# Define the folder structure
folders = [
    "ML_WorkoutApp/config",
    "ML_WorkoutApp/data/raw",
    "ML_WorkoutApp/data/processed",
    "ML_WorkoutApp/data/models",
    "ML_WorkoutApp/src",
    "ML_WorkoutApp/notebooks",
    "ML_WorkoutApp/results/plots",
    "ML_WorkoutApp/scripts",
]

# Create the directories
for folder in folders:
    os.makedirs(folder, exist_ok=True)
    print(f"Created folder: {folder}")

# Create empty __init__.py in src to make it a package
with open("ML_WorkoutApp/src/__init__.py", "w") as f:
    pass
print("Created empty __init__.py in src folder.")

# Create a README.md file
with open("ML_WorkoutApp/README.md", "w") as f:
    f.write("# ML_WorkoutApp\n\n")
    f.write("This project is structured to develop and train a machine learning model to analyze motion data from workouts.\n")
print("Created README.md file.")

# Create placeholder scripts
script_files = {
    "ML_WorkoutApp/scripts/run_data_extraction.py": "# Script to extract and merge data from MongoDB",
    "ML_WorkoutApp/scripts/run_training.py": "# Script to train the LSTM model",
    "ML_WorkoutApp/scripts/run_evaluation.py": "# Script to evaluate the model on test data",
    "ML_WorkoutApp/scripts/run_inference.py": "# Script to run inference on new data",
}

for path, content in script_files.items():
    with open(path, "w") as f:
        f.write(f"{content}\n")
    print(f"Created script: {path}")

# Print a message when done
print("Project structure created successfully.")