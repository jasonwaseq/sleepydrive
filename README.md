# UNOFFICIAL REPO FOR 123. DO NOT SUBMIT OR SHARE OUTSIDE OF GROUP 7.

This repo will compile all the work done for this class and then we'll split it up accordingly after to push to the legit github "https://github.com/PJ-004/CSE123A-Group7-Project.git". 

## Jetson code

`jetson_code/` is a Git submodule that points to:

`https://github.com/jasonwaseq/Jetson-Orin-Nano-MediaPipe-Driver-Monitoring-System`

After cloning this repo, initialize it with:

`git submodule update --init --recursive`

# How to run:
any machine:    This is the command to run !!!

1) Terminal 1:

`cd backend/`

`DATABASE_URL=postgresql://sleepydrive:sleepydrive@localhost:5432/sleepydrive python3 run_server.py`

1) Terminal 2:

`cd frontend\drowsiness_guide`   

`flutter run -d chrome --dart-define=BACKEND_BASE_URL=http://localhost:8080`


## How to run the emulator
The emulator isn't finished yet but

First you need to look up your IP

Then run the python file using:
`python3 jetson_emulator.py`

Enter the IP in the python file

Now the you run the jetson with: `flutter run --dart-define=JETSON_WS_URL=ws://<YOUR_IP>/ws/alerts?replay=0`
