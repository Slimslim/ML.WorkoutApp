# Script to extract and merge data from MongoDB

from config.mongodb_connector import coreMotionData_collection, workout_collection
from bson import ObjectId
import pandas as pd
import os

# Function to create a list with the workout IDs for a given movement (ONLY FOR GOOD DATA)
def get_workout_ids_by_movement(movement_name):
    """Get all workout IDs for a specific movement."""
    query = {"info.movement": movement_name, "isDataGood": True}
    workout_list = list(workout_collection.find(query, {"_id": 1}))

    # Extract the list of workout IDs
    workout_id_list = [str(workout["_id"]) for workout in workout_list]
    return workout_id_list


def extract_and_merge_data(workout_id):
    """Extract and merge data for a given workout_id."""
    # Query to find the corresponding CoreMotionData for the given workout_id
    core_motion_query = {"workoutId": workout_id}
    data = list(coreMotionData_collection.find(core_motion_query).sort("batchNumber", 1))  # Sort by batch number

    if not data:
        print(f"No data found for workoutId: {workout_id}")
        return None

    # Initialize lists to collect all batches' data
    all_timestamps = []
    all_accel_x = []
    all_accel_y = []
    all_accel_z = []

    # Iterate through each document (batch), which is now sorted by batchNumber
    for document in data:
        # Extract accelerometerSnapshots from the current document
        accelerometer_data = document['accelerometerSnapshots']

        # Convert accelerometerSnapshots to a DataFrame
        df_accel = pd.DataFrame(accelerometer_data)

        # Convert the timestamp from TimeInterval to seconds (if needed)
        df_accel['timestamp'] = pd.to_datetime(df_accel['timestamp'], unit='s')

        # Append data to the lists
        all_timestamps.extend(df_accel['timestamp'])
        all_accel_x.extend(df_accel['accelerationX'])
        all_accel_y.extend(df_accel['accelerationY'])
        all_accel_z.extend(df_accel['accelerationZ'])

    # Create a final DataFrame for the merged data
    merged_df = pd.DataFrame({
        'timestamp': all_timestamps,
        'accelerationX': all_accel_x,
        'accelerationY': all_accel_y,
        'accelerationZ': all_accel_z,
    })

    return merged_df

def save_merged_data(df, workout_id, output_dir="data/raw/"):
    """Save the merged data to a CSV file."""
    filename = f"workout_{workout_id}.csv"
    filepath = os.path.join(output_dir, filename)
    df.to_csv(filepath, index=False)
    print(f"Saved merged data to {filepath}")

def main():
    # Example: Retrieve and merge data for a specific workout ID
    workout_id = ObjectId("66c574287213ceebbce79f73")  # Replace with actual workout ID
    merged_df = extract_and_merge_data(workout_id)
    
    if merged_df is not None:
        save_merged_data(merged_df, workout_id)

if __name__ == "__main__":
    main()