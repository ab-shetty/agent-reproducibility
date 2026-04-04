# agent-reproducibility

## Running the ML-GPU Docker Image

```bash
docker run --rm --gpus all -it \
  --sysctl kernel.unprivileged_userns_clone=1 \
  -v $(pwd):/home/researcher/work \
  ashetty21/ml-gpu:latest
```