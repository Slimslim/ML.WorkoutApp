from scripts.run_data_extraction import main as data_extraction_main
from scripts.run_training import main as training_main
from scripts.run_evaluation import main as evaluation_main

def main():
    print("Starting data extraction...")
    workout_id = "66c574287213ceebbce79f73"  # Replace with actual workout ID
    data_extraction_main(workout_id)
    
    # print("Starting model training...")
    # training_main()
    
    # print("Starting model evaluation...")
    # evaluation_main()
    
    print("Workflow completed successfully!")

if __name__ == "__main__":
    main()