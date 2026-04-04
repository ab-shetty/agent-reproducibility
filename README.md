# agent-reproducibility

## Running the ML-GPU Docker Image

```bash
 docker run --gpus all -it -v $(pwd):/home/researcher/work ashetty21/ml-gpu:latest
```

### Installing Codex

```bash
sudo npm i -g @openai/codex
```

### Running Codex

```bash
codex --dangerously-bypass-approvals-and-sandbox
```
