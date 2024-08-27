from pymongo.mongo_client import MongoClient
from pymongo.server_api import ServerApi

# Your MongoDB connection URI
uri = "mongodb+srv://selimgawad:wEj38EZkbZ1WcCV5@cluster0.8olhyyk.mongodb.net/?retryWrites=true&w=majority&appName=Cluster0"

# Create a new client and connect to the server
client = MongoClient(uri, server_api=ServerApi('1'))

# Send a ping to confirm a successful connection
try:
    client.admin.command('ping')
    print("Pinged your deployment. You successfully connected to MongoDB!")
except Exception as e:
    print(e)

# Access a specific database and collection
db = client['WorkoutAppDB']
coreMotionData_collection = db['CoreMotionData']
workout_collection = db['Workout']