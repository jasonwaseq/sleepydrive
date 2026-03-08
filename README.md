# UNOFFICIAL REPO FOR 123. DO NOT SUBMIT OR SHARE OUTSIDE OF GROUP 7.

This repo will compile all the work done for this class and then we'll split it up accordingly after to push to the legit github "https://github.com/PJ-004/CSE123A-Group7-Project.git". 

# How to run:   
<<<<<<< HEAD

on one machine to run sever (not needed since hosted on domain):    
cd backend\realtime   
python -m venv .venv   
.\.venv\Scripts\Activate.ps1   
pip install -r requirements.txt   

$env:DATABASE_URL='postgresql://neondb_owner:npg_m0OGaWE8zXfY@ep-falling-sea-akrw78zs-pooler.c-3.us-west-2.aws.neon.tech/neondb?sslmode=require'   

$env:DATABASE_URL='postgresql://<user>:<pass>@<host>/<db>?sslmode=require'

$env:MQTT_HOST='73797b78ceac47e998c30ac034930c26.s1.eu.hivemq.cloud'
$env:MQTT_PORT='8883'
$env:MQTT_TLS='true'
$env:MQTT_USERNAME='group7'
$env:MQTT_PASSWORD='group7BananaSlug'
$env:MQTT_TOPICS='sleepydrive/alerts/+'
$env:MQTT_STATUS_TOPICS='sleepydrive/status/+'
$env:MQTT_CLIENT_ID='sleepydrive-realtime-gateway-local'
$env:MQTT_QOS='1'
$env:WS_DEFAULT_REPLAY='0'
$env:CORS_ALLOW_ORIGINS='*'
   

python run_server.py   

or docker if youre weird:   
docker compose up --build   
=======
 
>>>>>>> 70a2cee6f80eea2ef14cba99a4173b5d2aa10967

any machine:    This is the command to run !!!          

 cd frontend\drowsiness_guide   

flutter run --dart-define=JETSON_WS_URL=wss://sleepydrive.onrender.com/ws/alerts?replay=0   


  