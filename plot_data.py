# Import the db and collection from mongodb_connector
from config.mongodb_connector import db, coreMotionData_collection, workout_collection

from bson import ObjectId  # Import ObjectId to handle MongoDB ObjectIds

# Other necessary imports
import pandas as pd
import matplotlib.pyplot as plt

# Define the filter for the specific workoutId
# workout_id = ObjectId("66c573f87213ceebbce79f6c")
workout_id = ObjectId("66c574287213ceebbce79f73")

# Retrieve all data (batches) that match the workoutId and sort by batchNumber
#data = list(coreMotionData_collection.find(query).sort("batchNumber", 1))  # 1 for ascending order

# Define the filter for the specific movement and DataIsGood condition
movement = "Air Squat"
query = {
    "info.movement": movement,  # Access the nested 'movement' field inside 'info'
    "isDataGood": True
}

# Retrieve list of workouts that match the movement name and DataIsGood is True
workout_list = list(workout_collection.find(query, {"_id": 1}))

# Convert the cursor to a list of ids
workout_id_list = [workout["_id"] for workout in workout_list]

# Print the first matching workout id
first_workout_id = workout_id_list[0]
print(f"First workout ID: {first_workout_id}")

# Query the CoreMotionData collection using the workout_id
core_motion_query = {"workoutId": first_workout_id}
data = list(coreMotionData_collection.find(core_motion_query).sort("batchNumber", 1))  # 1 for ascending order

# Check if any data was retrieved
if data:
    # Initialize lists to collect all batches' data
    all_timestamps = []
    all_accel_x = []
    all_accel_y = []
    all_accel_z = []

    # Iterate through each document (batch), which is now sorted by batchNumber
    for i, document in enumerate(data):
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

        # Optionally, print out the first few rows of this batch
        print(f"Batch {document['batchNumber']} data:")
        print(df_accel.head())

    # Plotting the combined accelerometer data from all batches
    plt.figure(figsize=(12, 6))
    plt.plot(all_timestamps, all_accel_x, label='Acceleration X')
    plt.plot(all_timestamps, all_accel_y, label='Acceleration Y')
    plt.plot(all_timestamps, all_accel_z, label='Acceleration Z')
    plt.xlabel('Time')
    plt.ylabel('Acceleration')
    plt.title('Combined Accelerometer Data for WorkoutId 66c573f87213ceebbce79f6c')
    plt.legend()
    plt.show()
else:
    print("No data found for the specified workoutId.")