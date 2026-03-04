# UNOFFICIAL REPO FOR 123. DO NOT SUBMIT OR SHARE OUTSIDE OF GROUP 7.

This repo will compile all the work done for this class and then we'll split it up accordingly after to push to the legit github "https://github.com/PJ-004/CSE123A-Group7-Project.git". 

# How to run:   

on one terminal:    
cd backend\realtime   

$env:MP_QTT_HOST='73797b78ceac47e998c30ac034930c26.s1.eu.hivemq.cloud'   
$env:MP_QTT_PORT='8883'   
$env:MP_QTT_TLS='true'   
$env:MP_QTT_TOPIC='sleepydrive/alerts/+'   
$env:MP_SOURCE_ID='jetson-01'   
$env:MP_QTT_USERNAME='group7'   
$env:MP_QTT_PASSWORD='group7BananaSlug'   

docker compose up --build   

on another terminal:       

 cd frontend\drowsiness_guide   

flutter run --dart-define=JETSON_WS_URL=ws://localhost:8080/ws/alerts?replay=0    