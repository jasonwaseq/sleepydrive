# UNOFFICIAL REPO FOR 123. DO NOT SUBMIT OR SHARE OUTSIDE OF GROUP 7.

This repo will compile all the work done for this class and then we'll split it up accordingly after to push to the legit github "https://github.com/PJ-004/CSE123A-Group7-Project.git". 

## Jetson code

`jetson_code/` is a Git submodule that points to:

`https://github.com/jasonwaseq/Jetson-Orin-Nano-MediaPipe-Driver-Monitoring-System`

After cloning this repo, initialize it with:

`git submodule update --init --recursive`

# How to run:

`flutter run`

## Backend tests (server/database)

From the repo root:

```bash
cd backend
python -m pip install -r requirements.txt -r requirements-test.txt
python -m pytest
```

For just server/database-focused coverage:

```bash
python -m pytest tests/test_app_api.py tests/test_mqtt_consumer.py tests/test_repository.py
```