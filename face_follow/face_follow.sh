#!/usr/bin/env bash
# Run tools/face_follow.py inside a running ROS container (has rclpy + datatypes).
# Usage: tools/face_follow.sh [face_follow.py options]   e.g. --no-tilt --return-home 5
#        tools/face_follow.sh --stop                     kill any running follower
#
# Stopping `docker exec` does not stop the process inside the container, so
# this wrapper kills the in-container follower itself on exit / Ctrl+C.
set -uo pipefail
CONTAINER="${PIB_FACE_FOLLOW_CONTAINER:-pib-backend-ros-voice-assistant-1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

running() { docker exec "$CONTAINER" pgrep -f /tmp/face_follow.py >/dev/null 2>&1; }

stop_follower() {
  running || return 0
  # SIGINT lets the script release YuNet on the camera; give it a few seconds.
  docker exec "$CONTAINER" pkill -INT -f /tmp/face_follow.py 2>/dev/null
  for _ in 1 2 3 4 5 6; do running || break; sleep 0.5; done
  if running; then
    docker exec "$CONTAINER" pkill -KILL -f /tmp/face_follow.py 2>/dev/null
    release_yunet  # killed hard, so the script could not release it itself
  fi
  return 0
}

# Drop the follower's claim on YuNet. Harmless if it holds none; other users
# of YuNet keep it running.
release_yunet() {
  docker exec "$CONTAINER" bash -c '
    . /opt/ros/jazzy/setup.bash; . /app/ros2_ws/install/setup.bash
    timeout 95 ros2 service call /stop_model datatypes/srv/StopModel \
      "{model_id: face_detection_yunet_160x120, owner: face_follower}"' \
    >/dev/null 2>&1
}

if [ "${1:-}" = "--stop" ]; then
  stop_follower
  release_yunet
  echo "face follower stopped"
  exit 0
fi

stop_follower  # never run two followers at once
docker cp "$HERE/face_follow.py" "$CONTAINER:/tmp/face_follow.py" >/dev/null || exit 1
trap 'trap - INT TERM HUP EXIT; stop_follower; echo; echo "face follower stopped"' INT TERM HUP EXIT

# Run in the background and `wait`: bash only runs a trap once its foreground
# child exits, but `wait` is interrupted immediately by Ctrl+C / SIGTERM.
docker exec "$CONTAINER" bash -c '
  . /opt/ros/jazzy/setup.bash
  . /app/ros2_ws/install/setup.bash
  exec python3 -u /tmp/face_follow.py "$@"' face_follow "$@" &
wait $!
