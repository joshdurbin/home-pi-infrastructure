#!/bin/sh

while true
do
  (echo -n '{"detector_name" : "default", "detect" : { "*": 50 }, "data" : "'; raspistill -o - | base64 -w 0; echo '"}') | curl -s -H "Content-Type: application/json" -d @- http://doods.service.consul:20874/detect >> detector_responses.json
done