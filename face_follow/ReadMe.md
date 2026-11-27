# Face follow

Makes pib's head follow the nearest face. This is the "turn toward the speaker"
behaviour from the voice assistant, available as a standalone script that keeps
tracking for as long as it runs.

| File | Purpose |
|---|---|
| `face_follow.py` | ROS 2 node: reads face positions and head angles, commands the head motors |
| `face_follow.sh` | Wrapper: runs the node inside a pib ROS container and cleans up on exit |

## Quick start

```bash
cd ~/app/pib-backend
tools/face_follow.sh            # follow with pan + tilt; Ctrl+C to stop
tools/face_follow.sh --stop     # stop a follower running elsewhere (another terminal)
```

The robot's Docker stack must be running (camera, motors and at least one ROS
container). The script needs no extra installation.

## Options

| Option | Default | Effect |
|---|---|---|
| `--gain` | `0.6` | Fraction of the remaining offset corrected per move. Lower is smoother, higher is faster but can overshoot. |
| `--deadband` | `3.0` | Offsets (degrees) smaller than this are ignored, so the head stays still. |
| `--min-interval` | `0.3` | Minimum seconds between head commands, so the servo can finish moving. |
| `--no-tilt` | off | Pan (left/right) only. |
| `--no-yunet` | off | Don't start the YuNet model; use the Haar `face_center` detector only. |
| `--return-home SECONDS` | off | Re-centre the head after no face has been seen for this long. |
| `--pan-sign` / `--tilt-sign` | `-1` / `1` | Movement direction. Flip one if that axis moves away from the face. |
| `--pan-limit` | `80` | Pan range, ± degrees. |
| `--tilt-min` / `--tilt-max` | `-20` / `30` | Tilt range, degrees. |
| `--max-age` | `0.6` | Ignore face observations older than this (s). |
| `--settle` | `0.4` | After a command, use the commanded angle rather than `/joint_states` for this long (s). |
| `--rate` | `10` | Control loop frequency (Hz). |
| `-v`, `--verbose` | off | Log every face detection. |

Examples:

```bash
tools/face_follow.sh --no-tilt --return-home 5
tools/face_follow.sh --gain 0.4 --min-interval 0.5     # calmer, if the head swings
tools/face_follow.sh -v                                 # see what the camera detects
```

## How it works

```
camera (YuNet ~10 Hz, or Haar ~2 Hz) ──► face offset from image centre, in degrees
/joint_states ─────────────────────────► current head angles
                                          │
               new angle = current + gain × offset   (if |offset| > deadband)
                                          │
                                          ▼
                      apply_joint_trajectory ──► turn_head_motor / tilt_forward_motor
```

1. **Face detection.** On start, the node asks the camera to run the
   `face_detection_yunet_160x120` model through the `start_model` service, with
   owner `face_follower`. YuNet runs on the OAK-D's own processor and publishes
   boxes on `/detections/face_detection_yunet_160x120` at about 10 Hz. The
   largest box (the closest face) is followed. Until YuNet is up, or if it
   cannot start, the node falls back to the Haar detector on `/face_center`
   (about 2 Hz). The two are never mixed: Haar is ignored while YuNet is
   publishing.
2. **Pixels to degrees.** The offset from the image centre is converted to an
   angle using the colour camera's 69° horizontal field of view.
3. **Closed loop.** The camera is in the head, so the offset is always relative
   to where the head points now. Each move adds `gain × offset` to the current
   head angle, read from `/joint_states`. For `--settle` seconds after a command,
   the node uses the angle it just commanded instead, because the servos lag.
4. **Damping.** Each face observation is used once, at most one command is
   sent per `--min-interval`, offsets below `--deadband` are ignored, and
   targets are clamped to the configured limits.
5. **Motor command.** Targets are sent to the `apply_joint_trajectory`
   service, one request per motor, the same way the voice assistant does
   (`voice_assistant/attention.py`).

### Stopping and cleanup

- **Ctrl+C or SIGTERM:** the node releases YuNet with `stop_model` before it
  exits. The camera keeps per-owner records of who requested each model, so
  YuNet keeps running if anything else still uses it.
- **Stopping the wrapper:** stopping `docker exec` alone does not stop a process
  inside the container. `face_follow.sh` therefore kills the in-container node
  on Ctrl+C, SIGTERM and terminal close. If the node does not exit within about
  3 s, the wrapper kills it and releases YuNet itself.
- **Single instance:** starting the wrapper stops any follower already running.

Starting or stopping YuNet rebuilds the camera pipeline. The camera stream
pauses for about 5 seconds when that happens.

## ROS interfaces

| Direction | Name | Type |
|---|---|---|
| subscribe | `/detections/face_detection_yunet_160x120` | `datatypes/msg/DetectionArray` |
| subscribe | `/face_center` | `std_msgs/msg/Float32MultiArray` (`[x, y]` px from centre, `[0, 0]` = no face) |
| subscribe | `/joint_states` | `sensor_msgs/msg/JointState` (radians) |
| service client | `/apply_joint_trajectory` | `datatypes/srv/ApplyJointTrajectory` |
| service client | `/start_model`, `/stop_model` | `datatypes/srv/StartModel`, `StopModel` |

## Running on another robot

Copy both files into `~/app/pib-backend/tools/` on the other robot and make the
wrapper executable:

```bash
scp tools/face_follow.py tools/face_follow.sh pib@<other-pi>:~/app/pib-backend/tools/
ssh pib@<other-pi> chmod +x ~/app/pib-backend/tools/face_follow.sh
```

By default the wrapper runs the node in `pib-backend-ros-voice-assistant-1`. Any
pib ROS container will do, because they all include `rclpy` and the `datatypes`
package. To use a different one, set `PIB_FACE_FOLLOW_CONTAINER`:

```bash
PIB_FACE_FOLLOW_CONTAINER=pib-backend-ros-programs-1 tools/face_follow.sh
```

Tested with pib-backend v0.7.17. On another version, check that the topics
exist:

```bash
docker exec pib-backend-ros-voice-assistant-1 bash -c \
  '. /opt/ros/jazzy/setup.bash; ros2 topic list' | grep -E 'face_center|joint_states'
```

To run the node without the wrapper (inside any ROS environment with the pib
workspace sourced):

```bash
python3 face_follow.py [options]
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| Head turns or nods away from the face | Flip that axis: `--pan-sign 1` or `--tilt-sign -1` |
| Head swings back and forth | Lower `--gain` (e.g. `0.4`) and/or raise `--min-interval` (e.g. `0.5`) |
| Head jitters while you stand still | Raise `--deadband` (e.g. `5`) |
| Log says `YuNet not started` | The message gives the camera's reason. Possible causes: the model file is unavailable, or the pipeline rebuild failed with other models running (the camera has 16 compute cores; YuNet needs 4). The node keeps working with Haar. |
| Head moves while the voice assistant talks | The voice assistant also turns the head toward speakers. Run one or the other. |
| Slow following with `--no-yunet` | The Haar rate is set by `PIB_FACE_CENTER_HZ` in the camera container (default `2.0`). Add it to the `ros-camera` environment in `docker-compose.yaml` and restart that container. |
| Model still active after a crash | `tools/face_follow.sh --stop` releases it |
