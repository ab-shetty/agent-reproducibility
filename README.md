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

## Uploading Codex Runs to Docent

Use `docent/upload_codex_to_docent.py` to upload a Codex rollout JSONL to a Docent collection.

**Prerequisites:** Set `DOCENT_API_KEY` in your environment.

**Running the upload script directly:**

```bash
python docent/upload_codex_to_docent.py \
  --path <path to rollout .jsonl> \
  --collection-name "berkeley-pilot" \
  --tag "<TOPIC>"
```

**Asking Codex to find and upload a run by topic:**

```
Using the script at <path to upload_codex_to_docent.py>,
find the rollout JSONL file for the conversation about <TOPIC> (look in <directory>),
then run:

  python <path to upload_codex_to_docent.py> \
    --path <found file> \
    --collection-name "berkeley-pilot" \
    --tag "<TOPIC>"
```

The script will reuse an existing collection with the given name, or create one if it doesn't exist. Use `--dry-run` to validate without uploading.
